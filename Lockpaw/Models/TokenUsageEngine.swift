import Foundation

// Token counter — the engine. Owns every number behind the lock-screen counter: which bytes
// of which transcript were read, the dedupe ledgers, per-day totals per source, and the
// cache file that lets a relaunch resume instead of rescanning. No AppKit or SwiftUI; not
// thread-safe — the monitor confines it to one serial utility queue.

/// Where the counter reads from and writes to.
struct TokenUsagePaths: Sendable, Equatable {
    /// `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    var claudeConfig: URL
    /// opencode's database (`$XDG_DATA_HOME/opencode`, else `~/.local/share/opencode`).
    var opencodeDatabase: URL
    /// Our own progress cache — the only file the counter ever writes.
    var cacheFile: URL

    var projects: URL { claudeConfig.appendingPathComponent("projects", isDirectory: true) }
    var statsCache: URL { claudeConfig.appendingPathComponent("stats-cache.json") }

    /// The cache file's name in Lockpaw's Application Support folder (next to CustomMascot.png).
    static let cacheFileName = "token-usage.json"

    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        -> TokenUsagePaths {
        func directory(_ value: String?) -> URL? {
            guard let value, !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        let claude = directory(environment["CLAUDE_CONFIG_DIR"]) ?? home.appendingPathComponent(".claude", isDirectory: true)
        let data = directory(environment["XDG_DATA_HOME"]) ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let support = applicationSupport.appendingPathComponent(Constants.appName, isDirectory: true)
        return TokenUsagePaths(claudeConfig: claude.standardizedFileURL,
                               opencodeDatabase: data.appendingPathComponent("opencode/opencode.db").standardizedFileURL,
                               cacheFile: support.appendingPathComponent(cacheFileName))
    }
}

/// What the lock screen shows, published by the monitor.
struct TokenUsageSnapshot: Equatable, Sendable {
    var year: Int
    var todayTokens: Int64
    var yearTokens: Int64
    var isCounting: Bool
    var recent: TokenRateWindow
    /// Tokens that arrived live since the previous snapshot (0 while scanning or catching up).
    var arrivedTokens: Int64
}

/// The persisted progress: `token-usage.json` in Lockpaw's Application Support folder.
struct TokenUsageCache: Codable, Equatable {
    static let currentVersion = 2

    struct Claude: Codable, Equatable {
        var statsLastComputedDate: String?
        var statsModified: Double?
        var cutoffKey: Int?
        /// Paths relative to `projects/`.
        var files: [String: TrackedFile]
        /// Tokens per local day, keyed yyyymmdd.
        var days: [String: Int64]
        var coverageStart: Double?
        var ledger: [LedgerRecord]
    }

    struct Opencode: Codable, Equatable {
        var watermarkMs: Int64?
        var days: [String: Int64]
        var coverageStart: Double?
        var ledger: [LedgerRecord]
    }

    var version: Int
    var year: Int
    var savedAt: Double
    var claudeConfig: String
    var opencodeDatabase: String
    var claude: Claude
    var opencode: Opencode

    static func load(from url: URL) -> TokenUsageCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(TokenUsageCache.self, from: data),
              cache.version == currentVersion else { return nil }
        return cache
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

enum OpencodeReadError: Error, Equatable, Sendable {
    /// No database file — the source contributes 0.
    case missing
    /// Locked right now; try again on the next change.
    case busy
    /// Table or columns not as expected — the source contributes 0.
    case schema(String)
    case failed(String)
}

/// Rows of opencode's `session_message` — the SQLite source, or a stub in tests.
protocol OpencodeRowSource: AnyObject {
    /// Assistant rows with `time_updated > updatedAfterMs` and `createdFromMs <= time_created < createdToMs`.
    func rows(updatedAfterMs: Int64, createdFromMs: Int64, createdToMs: Int64) -> Result<[OpencodeRow], OpencodeReadError>
}

final class TokenUsageEngine {
    struct ClaudeState: Equatable {
        var statsLastComputedDate: String?
        var statsModified: Double?
        var baseline = ClaudeBaseline()
        var files: [String: TrackedFile] = [:]
        var ledger = UsageLedger()
        var days: [Int: Int64] = [:]
        /// Lines older than this whose message isn't in the ledger were counted before the
        /// ledger forgot them (pruned, or not persisted). nil = the ledger is complete.
        var coverageStart: Double?

        static func == (a: ClaudeState, b: ClaudeState) -> Bool {
            a.statsLastComputedDate == b.statsLastComputedDate && a.baseline == b.baseline && a.files == b.files
                && a.days == b.days && a.coverageStart == b.coverageStart && a.ledger.entries == b.ledger.entries
        }
    }

    struct OpencodeState {
        var ledger = UsageLedger()
        var days: [Int: Int64] = [:]
        /// Largest `time_updated` seen; nil until the year has been read once.
        var watermarkMs: Int64?
        var coverageStart: Double?
    }

    enum CalendarChange: Equatable { case none, day, year }
    enum StatsChange: Equatable { case unchanged, baseline, rebuildNeeded }
    enum PollResult: Equatable { case ok(rows: Int), busy, unavailable(OpencodeReadError) }

    /// For the real-data harness report only — the UI shows one combined total.
    struct Breakdown {
        var claudeBaselineTokens: Int64
        var claudeTranscriptYearTokens: Int64, claudeTodayTokens: Int64
        var opencodeYearTokens: Int64, opencodeTodayTokens: Int64
        var cutoffKey: Int?
        var ledgerEntries: Int, trackedFiles: Int
    }

    static let ledgerHorizon: Double = 24 * 3600
    /// The tail of the ledger kept in the cache file: enough for messages still streaming.
    static let persistedLedgerHorizon: Double = 3600
    /// opencode replies that keep updating longer than this after they start are missed by
    /// the cheap indexed poll (the longest seen in testing ran 3.2 h).
    static let opencodeActiveWindowMs: Int64 = 6 * 3_600_000
    static let opencodeOverlapMs: Int64 = 5_000
    static let opencodeScanChunkMs: Int64 = 7 * 86_400_000

    let paths: TokenUsagePaths
    let chunkSize: Int
    var now: () -> Date
    /// Checked between files and between chunks of a long read, so turning the counter off
    /// ends a first scan within one chunk instead of finishing it. What a stopped scan leaves
    /// behind is partial and must be thrown away (the worker discards the whole engine).
    var shouldStop: () -> Bool = { false }

    private(set) var calendar: Calendar
    private var keyer: LocalDayKeyer
    private(set) var year = 0
    private(set) var todayKey = 0
    private var yearStart = 0.0
    private var yearEnd = 0.0

    private(set) var claude = ClaudeState()
    private(set) var opencode = OpencodeState()
    private var stats: ClaudeStatsCache?
    private var firstSessionYear: Int?

    private(set) var rate = TokenRateWindow()
    /// When on, increases also count as live arrivals (the "+N" chip).
    var reportsArrivals = false
    private var arrived: Int64 = 0

    /// Bumped by every change worth saving.
    private(set) var revision = 0
    private(set) var bytesRead: UInt64 = 0
    private(set) var filesRead = 0
    private var lastPrune = 0.0

    init(paths: TokenUsagePaths, calendar: Calendar = .current, chunkSize: Int = 1 << 20, now: @escaping () -> Date = Date.init) {
        self.paths = paths
        self.calendar = calendar
        self.keyer = LocalDayKeyer(calendar: calendar)
        self.chunkSize = max(1, chunkSize)
        self.now = now
        _ = refreshCalendar(calendar)
    }

    private var nowSeconds: Double { now().timeIntervalSince1970 }

    // MARK: Calendar

    /// Re-reads today/the year (midnight, time zone or clock change, wake). A new year means
    /// the caller must rebuild; a new day may move the stats-cache cutoff.
    @discardableResult
    func refreshCalendar(_ newCalendar: Calendar? = nil) -> CalendarChange {
        if let newCalendar {
            calendar = newCalendar
            keyer = LocalDayKeyer(calendar: newCalendar)
        }
        let previousYear = year, previousDay = todayKey
        todayKey = keyer.key(for: nowSeconds)
        year = todayKey / 10_000
        yearStart = keyer.start(of: year * 10_000 + 101) ?? 0
        yearEnd = keyer.start(of: (year + 1) * 10_000 + 101) ?? .infinity
        if previousYear != 0 && previousYear != year { return .year }
        return previousDay != todayKey && previousDay != 0 ? .day : .none
    }

    private var yesterdayKey: Int { keyer.previous(before: todayKey) ?? todayKey }

    /// Transcript lines count from here: the day after the cutoff, and never before this year.
    private var countFrom: Double {
        guard let cutoff = claude.baseline.cutoffKey, let next = keyer.next(after: cutoff), let start = keyer.start(of: next) else {
            return yearStart
        }
        return max(start, yearStart)
    }

    // MARK: Start

    /// Loads the stats cache and resumes from `cache` where it still applies. Returns which
    /// sources resumed; the rest start empty and need a full scan.
    @discardableResult
    func begin(with cache: TokenUsageCache?) -> (claude: Bool, opencode: Bool) {
        refreshCalendar()
        let (stats, modified) = loadStats()
        self.stats = stats
        firstSessionYear = stats?.firstSessionDate.flatMap(ISOTimestamp.parse).map { keyer.key(for: $0) / 10_000 }
        claude = ClaudeState()
        opencode = OpencodeState()
        var resumed = (claude: false, opencode: false)

        if let cache, cache.version == TokenUsageCache.currentVersion, cache.year == year {
            if cache.opencodeDatabase == paths.opencodeDatabase.path {
                opencode.watermarkMs = cache.opencode.watermarkMs
                opencode.days = Self.days(cache.opencode.days)
                opencode.ledger = UsageLedger(records: cache.opencode.ledger)
                opencode.coverageStart = Self.coverage(cache.opencode.coverageStart, savedAt: cache.savedAt)
                resumed.opencode = cache.opencode.watermarkMs != nil
            }
            if cache.claudeConfig == paths.claudeConfig.path,
               cache.claude.statsLastComputedDate == stats?.lastComputedDate {
                claude.files = cache.claude.files
                claude.days = Self.days(cache.claude.days)
                claude.ledger = UsageLedger(records: cache.claude.ledger)
                claude.coverageStart = Self.coverage(cache.claude.coverageStart, savedAt: cache.savedAt)
                claude.baseline.cutoffKey = cache.claude.cutoffKey
                resumed.claude = true
            }
        }
        claude.statsLastComputedDate = stats?.lastComputedDate
        claude.statsModified = modified
        if resumed.claude {
            if reconcileStats(reload: false) == .rebuildNeeded { resetClaude(); resumed.claude = false }
        } else {
            claude.baseline = computeBaseline()
        }
        if !resumed.opencode { opencode = OpencodeState() }
        revision += 1
        return resumed
    }

    private func resetClaude() {
        let date = claude.statsLastComputedDate, modified = claude.statsModified
        claude = ClaudeState()
        claude.statsLastComputedDate = date
        claude.statsModified = modified
        claude.baseline = computeBaseline()
    }

    private static func coverage(_ stored: Double?, savedAt: Double) -> Double {
        max(stored ?? -.infinity, savedAt - persistedLedgerHorizon)
    }

    private static func days(_ stored: [String: Int64]) -> [Int: Int64] {
        var out: [Int: Int64] = [:]
        for (key, day) in stored { if let k = Int(key) { out[k] = day } }
        return out
    }

    // MARK: Stats cache

    private enum StatsFile {
        case missing
        /// There but not decodable — caught mid-write, most likely.
        case unreadable
        case loaded(ClaudeStatsCache, modified: Double?)
    }

    private func readStats() -> StatsFile {
        let url = paths.statsCache
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let stats = try? JSONDecoder().decode(ClaudeStatsCache.self, from: data) else { return .unreadable }
        return .loaded(stats, modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970)
    }

    private func loadStats() -> (ClaudeStatsCache?, Double?) {
        if case .loaded(let stats, let modified) = readStats() { return (stats, modified) }
        return (nil, nil)
    }

    private func computeBaseline() -> ClaudeBaseline {
        ClaudeStatsBaseline.compute(stats, year: year, todayKey: todayKey, yesterdayKey: yesterdayKey,
                                    firstSessionYear: firstSessionYear)
    }

    /// Re-derives the baseline (after the stats cache changed, or a new day began).
    /// A changed `lastComputedDate` — or a cutoff that moved backwards — needs a rebuild of the
    /// transcript side. A cutoff that only moved forward because a new day began drops the
    /// days the cache now covers.
    func reconcileStats(reload: Bool) -> StatsChange {
        if reload {
            let stats: ClaudeStatsCache?, modified: Double?
            switch readStats() {
            case .unreadable: return .unchanged   // keep the last good copy; the finished write fires again
            case .missing: (stats, modified) = (nil, nil)
            case .loaded(let s, let m): (stats, modified) = (s, m)
            }
            let changed = stats?.lastComputedDate != claude.statsLastComputedDate
            self.stats = stats
            firstSessionYear = stats?.firstSessionDate.flatMap(ISOTimestamp.parse).map { keyer.key(for: $0) / 10_000 }
            claude.statsModified = modified
            if changed {
                claude.statsLastComputedDate = stats?.lastComputedDate
                return .rebuildNeeded
            }
        }
        let base = computeBaseline()
        if base.cutoffKey != claude.baseline.cutoffKey {
            guard let new = base.cutoffKey, let old = claude.baseline.cutoffKey, new > old else { return .rebuildNeeded }
            claude.days = claude.days.filter { $0.key > new }
        }
        if base != claude.baseline { claude.baseline = base; revision += 1 }
        return .baseline
    }

    /// Forget the transcript side and scan it again (new `lastComputedDate`, new year).
    func rebuildClaude(progress: () -> Void = {}) {
        // A rescan re-reads tokens already shown: they are neither live arrivals nor new
        // rate, so the window and the arrival tally are put back afterwards.
        let keptRate = rate, keptArrived = arrived, reporting = reportsArrivals
        reportsArrivals = false
        resetClaude()
        syncClaude(paths: nil, progress: progress)
        pruneLedgers(force: true)
        rate = keptRate
        arrived = keptArrived
        reportsArrivals = reporting
        revision += 1
    }

    // MARK: Transcripts

    /// Reads what changed under `projects/`: the given absolute paths, or — with nil — every
    /// transcript (first scan, wake, dropped events). Missing directory = nothing to count.
    func syncClaude(paths changed: Set<String>?, progress: () -> Void = {}) {
        let root = paths.projects.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if let changed {
            for path in changed.sorted() where path.hasPrefix(prefix) {
                sync(relative: String(path.dropFirst(prefix.count)), root: prefix)
            }
            return
        }
        var seen = Set<String>()
        for relative in Self.transcripts(under: root) {
            if shouldStop() { return }
            seen.insert(relative)
            sync(relative: relative, root: prefix)
            progress()
        }
        if shouldStop() { return }
        for gone in claude.files.keys where !seen.contains(gone) {
            claude.files[gone] = nil
            revision += 1
        }
    }

    static func isTranscript(_ name: String) -> Bool {
        name.hasSuffix(".jsonl") && !name.contains(".superseded-")
    }

    /// Transcript paths relative to `root`: `<project>/<session>.jsonl` and
    /// `<project>/<session>/subagents/agent-*.jsonl`, plus anything deeper that is a transcript.
    /// A plain `readdir` walk: directory entries carry their type, so nothing is stat'ed here
    /// (`FileManager`'s enumerator took ~0.4 s over ~7,000 entries in testing). Symlinked
    /// directories are not followed.
    static func transcripts(under root: String) -> [String] {
        var out: [String] = []
        func walk(_ directory: String, _ relative: String) {
            guard let handle = opendir(directory) else { return }
            defer { closedir(handle) }
            while let entry = readdir(handle) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                guard name != "." && name != ".." else { continue }
                let child = relative.isEmpty ? name : relative + "/" + name
                var type = Int32(entry.pointee.d_type)
                if type == DT_UNKNOWN {
                    var info = stat()
                    guard lstat(directory + "/" + name, &info) == 0 else { continue }
                    type = (info.st_mode & S_IFMT) == S_IFDIR ? DT_DIR : DT_REG
                }
                if type == DT_DIR {
                    walk(directory + "/" + name, child)
                } else if (type == DT_REG || type == DT_LNK) && isTranscript(name) {
                    out.append(child)
                }
            }
        }
        walk(root.hasSuffix("/") ? String(root.dropLast()) : root, "")
        return out.sorted()
    }

    private func sync(relative: String, root: String) {
        guard Self.isTranscript((relative as NSString).lastPathComponent) else { return }
        let path = root + relative
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            if claude.files.removeValue(forKey: relative) != nil { revision += 1 }
            return
        }
        let size = UInt64(max(0, info.st_size))
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        let plan = TranscriptReadPlan.make(known: claude.files[relative], inode: UInt64(info.st_ino), size: size,
                                           mtime: mtime, countFrom: countFrom)
        switch plan {
        case .unchanged:
            break
        case .markOnly:
            claude.files[relative] = TrackedFile(inode: UInt64(info.st_ino), size: size, offset: size, mtime: mtime)
        case .read(let offset):
            // Bytes past a known offset were never counted; a file new to us may hold copied
            // history (a resumed or forked session), so it goes through the coverage guard.
            read(relative: relative, path: path, from: offset, guarded: offset == 0, inode: UInt64(info.st_ino))
        case .rescan:
            read(relative: relative, path: path, from: 0, guarded: true, inode: UInt64(info.st_ino))
        }
    }

    /// Reads complete lines from `offset` in fixed chunks; only lines that pass the byte
    /// prefilter are parsed. A file deleted mid-read stays readable through its open handle;
    /// one that can't be opened is forgotten and picked up again if it reappears.
    private func read(relative: String, path: String, from start: UInt64, guarded startGuarded: Bool, inode: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            if claude.files.removeValue(forKey: relative) != nil { revision += 1 }
            return
        }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return }
        // Replaced between the stat and the open: this is another file — read all of it, guarded.
        let replaced = UInt64(info.st_ino) != inode
        let offset = replaced ? 0 : start
        let guarded = replaced || startGuarded
        var splitter = LineSplitter()
        var read: UInt64 = 0
        do {
            try handle.seek(toOffset: offset)
            var more = true
            while more && !shouldStop() {
                // FileHandle hands back autoreleased buffers: drain per chunk, or a scan of
                // gigabytes keeps every chunk alive until it ends.
                try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { more = false; return }
                    read += UInt64(chunk.count)
                    chunk.withUnsafeBytes { bytes in
                        splitter.feed(bytes) { line in
                            if ClaudeTranscriptLine.mayCarryUsage(line), let usage = ClaudeTranscriptLine.parse(line) {
                                ingest(usage, guarded: guarded)
                            }
                        }
                    }
                }
            }
        } catch {
            // Keep what was read; the rest is retried from the new offset on the next change.
        }
        bytesRead += read
        filesRead += 1
        var after = stat()
        let current = fstat(handle.fileDescriptor, &after) == 0 ? after : info
        let mtime = Double(current.st_mtimespec.tv_sec) + Double(current.st_mtimespec.tv_nsec) / 1e9
        claude.files[relative] = TrackedFile(inode: UInt64(current.st_ino), size: UInt64(max(0, current.st_size)),
                                             offset: offset + splitter.consumed, mtime: mtime)
        revision += 1
    }

    /// Counts one transcript line's usage: day filter, coverage guard, increase-only ledger.
    /// `guarded`: the line may have been counted before (a rescan, or a file new to us), so an
    /// old message the ledger no longer remembers is taken as already counted.
    func ingest(_ usage: ClaudeUsageLine, guarded: Bool = true) {
        let day = keyer.key(for: usage.timestamp)
        guard day / 10_000 == year else { return }
        if let cutoff = claude.baseline.cutoffKey, day <= cutoff { return }
        let key = UsageLedger.key(usage.id)
        if guarded, let coverage = claude.coverageStart, usage.timestamp < coverage, !claude.ledger.contains(key) { return }
        let increase = claude.ledger.record(key, counts: usage.counts, seen: usage.timestamp)
        guard !increase.isZero else { return }
        claude.days[day, default: 0] += increase.total
        noteArrival(increase.total, at: usage.timestamp)
        revision += 1
    }

    private func noteArrival(_ tokens: Int64, at time: Double) {
        guard tokens > 0 else { return }
        let now = nowSeconds
        if time > now - TokenRateWindow.span { rate.add(tokens, at: min(time, now)) }
        if reportsArrivals { arrived += tokens }
    }

    // MARK: opencode

    var opencodeNeedsYearScan: Bool { opencode.watermarkMs == nil }

    /// Reads this year's rows once, a week at a time (each its own short read transaction).
    /// All-or-nothing: on failure the source stays unscanned and is retried on the next change.
    func scanOpencodeYear(_ source: OpencodeRowSource, progress: () -> Void = {}) -> PollResult {
        // A year of rows is history, not a live arrival — even when this is a retry after
        // the database was missing or busy at launch.
        let saved = opencode, savedRate = rate, reporting = reportsArrivals
        reportsArrivals = false
        defer { reportsArrivals = reporting }
        opencode = OpencodeState()
        let startMs = Int64(yearStart * 1000)
        let endMs = yearEnd.isFinite ? Int64(yearEnd * 1000) : Int64.max
        var chunkStart = startMs
        var rows = 0
        var watermark: Int64 = 0
        while chunkStart < endMs {
            if shouldStop() {
                // Same all-or-nothing as a failure: the year stays unscanned.
                opencode = saved
                rate = savedRate
                return .busy
            }
            let chunkEnd = min(endMs, chunkStart + Self.opencodeScanChunkMs)
            let lastChunk = Double(chunkEnd) / 1000 > nowSeconds + 86_400
            switch source.rows(updatedAfterMs: -1, createdFromMs: chunkStart, createdToMs: lastChunk ? endMs : chunkEnd) {
            case .success(let batch):
                for row in batch { apply(row); watermark = max(watermark, row.updatedMs) }
                rows += batch.count
            case .failure(let error):
                opencode = saved
                rate = savedRate
                return error == .busy ? .busy : .unavailable(error)
            }
            progress()
            if lastChunk { break }
            chunkStart = chunkEnd
        }
        opencode.watermarkMs = watermark
        revision += 1
        return .ok(rows: rows)
    }

    /// Rows updated since the last look, through the `time_created` index (an unindexed
    /// `time_updated` scan reads the whole database: seconds on a large one, not milliseconds).
    func pollOpencode(_ source: OpencodeRowSource) -> PollResult {
        guard let watermark = opencode.watermarkMs else { return scanOpencodeYear(source) }
        let startMs = Int64(yearStart * 1000)
        let endMs = yearEnd.isFinite ? Int64(yearEnd * 1000) : Int64.max
        let createdFrom = max(startMs, watermark - Self.opencodeActiveWindowMs)
        switch source.rows(updatedAfterMs: watermark - Self.opencodeOverlapMs, createdFromMs: createdFrom, createdToMs: endMs) {
        case .success(let batch):
            for row in batch {
                apply(row)
                opencode.watermarkMs = max(opencode.watermarkMs ?? row.updatedMs, row.updatedMs)
            }
            return .ok(rows: batch.count)
        case .failure(let error):
            return error == .busy ? .busy : .unavailable(error)
        }
    }

    func apply(_ row: OpencodeRow) {
        let created = Double(row.createdMs) / 1000
        let day = keyer.key(for: created)
        guard day / 10_000 == year else { return }
        let key = UsageLedger.key(row.id)
        if let coverage = opencode.coverageStart, created < coverage, !opencode.ledger.contains(key) { return }
        let updated = Double(row.updatedMs) / 1000
        let increase = opencode.ledger.record(key, counts: row.counts, seen: updated)
        guard !increase.isZero else { return }
        opencode.days[day, default: 0] += increase.total
        noteArrival(increase.total, at: updated)
        revision += 1
    }

    // MARK: Upkeep

    /// Forgets ledger entries not seen for a day (at most every 10 minutes unless forced).
    /// What they covered is then guarded by `coverageStart`.
    func pruneLedgers(force: Bool = false) {
        let now = nowSeconds
        guard force || now - lastPrune >= 600 else { return }
        lastPrune = now
        let horizon = now - Self.ledgerHorizon
        claude.ledger.prune(olderThan: horizon)
        opencode.ledger.prune(olderThan: horizon)
        claude.coverageStart = max(claude.coverageStart ?? -.infinity, horizon)
        opencode.coverageStart = max(opencode.coverageStart ?? -.infinity, horizon)
    }

    /// After the first full scan the ledger is complete; from here it only needs a day.
    func finishFullScan() {
        pruneLedgers(force: true)
    }

    // MARK: Output

    func snapshot(isCounting: Bool) -> TokenUsageSnapshot {
        let now = nowSeconds
        rate.prune(now: now)
        let cutoff = claude.baseline.cutoffKey ?? Int.min
        var tokens = claude.baseline.tokens
        for (key, day) in claude.days where key / 10_000 == year && key > cutoff { tokens += day }
        for (key, day) in opencode.days where key / 10_000 == year { tokens += day }
        let today = (claude.days[todayKey] ?? 0) + (opencode.days[todayKey] ?? 0)
        let arrival = arrived
        arrived = 0
        return TokenUsageSnapshot(year: year, todayTokens: today, yearTokens: tokens,
                                  isCounting: isCounting, recent: rate, arrivedTokens: arrival)
    }

    func breakdown() -> Breakdown {
        let cutoff = claude.baseline.cutoffKey ?? Int.min
        let claudeYear = claude.days.filter { $0.key / 10_000 == year && $0.key > cutoff }.values
        let openYear = opencode.days.filter { $0.key / 10_000 == year }.values
        return Breakdown(
            claudeBaselineTokens: claude.baseline.tokens,
            claudeTranscriptYearTokens: claudeYear.reduce(0, +),
            claudeTodayTokens: claude.days[todayKey] ?? 0,
            opencodeYearTokens: openYear.reduce(0, +),
            opencodeTodayTokens: opencode.days[todayKey] ?? 0,
            cutoffKey: claude.baseline.cutoffKey,
            ledgerEntries: claude.ledger.count + opencode.ledger.count, trackedFiles: claude.files.count)
    }

    /// Recently written transcripts, for the no-FSEvents fallback check.
    func recentlyActiveTranscripts(within seconds: Double) -> [String] {
        let floor = nowSeconds - seconds
        let root = paths.projects.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return claude.files.compactMap { $0.value.mtime >= floor ? prefix + $0.key : nil }
    }

    /// The cache file contents. Only transcripts that can still matter are listed (older
    /// ones are re-derived from their mtime on the next launch), and only the last hour of
    /// the ledgers.
    func makeCache() -> TokenUsageCache {
        let now = nowSeconds
        let since = now - Self.persistedLedgerHorizon
        let from = countFrom
        return TokenUsageCache(
            version: TokenUsageCache.currentVersion, year: year, savedAt: now,
            claudeConfig: paths.claudeConfig.path, opencodeDatabase: paths.opencodeDatabase.path,
            claude: .init(statsLastComputedDate: claude.statsLastComputedDate, statsModified: claude.statsModified,
                          cutoffKey: claude.baseline.cutoffKey,
                          files: claude.files.filter { $0.value.mtime >= from },
                          days: Dictionary(uniqueKeysWithValues: claude.days.map { (String($0.key), $0.value) }),
                          coverageStart: claude.coverageStart,
                          ledger: claude.ledger.records(since: since)),
            opencode: .init(watermarkMs: opencode.watermarkMs,
                            days: Dictionary(uniqueKeysWithValues: opencode.days.map { (String($0.key), $0.value) }),
                            coverageStart: opencode.coverageStart,
                            ledger: opencode.ledger.records(since: since)))
    }
}
