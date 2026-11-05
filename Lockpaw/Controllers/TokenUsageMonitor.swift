import AppKit
import CoreServices
import Foundation
import os

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "TokenUsage")

/// App side of the token counter: publishes today's and this year's tokens for the lock
/// screen. It runs only while the counter is switched on (`TokenCounterPreference`, off by
/// default): `followPreference()` watches that one UserDefaults key, starting a worker when it
/// turns on and stopping it when it turns off. With no worker there is no scan, no FSEvents
/// stream, no cache file and no SQLite connection. All reading happens on one serial utility
/// queue (`TokenUsageWorker`); this object only receives snapshots, at most twice a second.
@MainActor
final class TokenUsageMonitor: ObservableObject {
    static let shared = TokenUsageMonitor()

    @Published private(set) var todayTokens: Int64 = 0
    @Published private(set) var yearTokens: Int64 = 0
    @Published private(set) var yearCost: Double = 0
    @Published private(set) var year: Int = Calendar.current.component(.year, from: Date())
    /// True until the first numbers are known (the one-time scan, or the cache on relaunch).
    @Published private(set) var isCounting = true
    /// Recent spend for the rate and sparkline.
    @Published private(set) var recent = TokenRateWindow()
    /// Bumped per published batch that brought live tokens — the view's one-shot glow and
    /// "+N" chip key off it.
    @Published private(set) var arrival = TokenArrival()

    /// The running worker, or nil while the counter is off.
    private(set) var worker: TokenUsageWorker?
    var isRunning: Bool { worker != nil }

    private let defaults: UserDefaults
    private let makePaths: () -> TokenUsagePaths
    private var preferenceObserver: DefaultsKeyObserver?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var visibleCounters = 0
    /// Bumped on every start and stop, so a snapshot still in flight from a stopped worker
    /// is dropped instead of repainting the reset numbers.
    private var generation = 0

    init(defaults: UserDefaults = .standard, paths: @escaping () -> TokenUsagePaths = { .standard() }) {
        self.defaults = defaults
        self.makePaths = paths
    }

    /// Called once at launch. Starts the monitor if the counter is on, then follows the
    /// setting for as long as the app runs.
    func followPreference() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = DefaultsKeyObserver(defaults: defaults, key: TokenCounterPreference.showKey) { [weak self] in
            // KVO can call back on whichever thread wrote the value.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyPreference() }
            }
        }
        applyPreference()
    }

    private var preferenceIsOn: Bool {
        defaults.object(forKey: TokenCounterPreference.showKey) == nil
            ? TokenCounterPreference.defaultShow
            : defaults.bool(forKey: TokenCounterPreference.showKey)
    }

    private func applyPreference() {
        if preferenceIsOn { start() } else { stop() }
    }

    private func start() {
        guard worker == nil else { return }
        generation &+= 1
        let generation = self.generation
        let worker = TokenUsageWorker(paths: makePaths()) { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot, generation: generation) }
            }
        }
        self.worker = worker
        worker.start()
        if visibleCounters > 0 { worker.setVisible(true) }

        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        observe(workspace, NSWorkspace.didWakeNotification) { $0.worker?.recheck(reason: "wake") }
        observe(center, .NSCalendarDayChanged) { $0.worker?.calendarChanged(resetTimeZone: false) }
        observe(center, .NSSystemTimeZoneDidChange) { $0.worker?.calendarChanged(resetTimeZone: true) }
        observe(center, .NSSystemClockDidChange) { $0.worker?.calendarChanged(resetTimeZone: false) }
        observe(center, NSApplication.willTerminateNotification) { $0.worker?.saveBeforeQuit() }
    }

    /// Stops the worker and releases everything it held: the FSEvents stream, the database
    /// connection, the engine. The cache file stays, so turning the counter back on resumes.
    private func stop() {
        guard let worker else { return }
        self.worker = nil
        generation &+= 1
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        worker.stop()
        todayTokens = 0
        yearTokens = 0
        yearCost = 0
        isCounting = true
        recent = TokenRateWindow()
        arrival = TokenArrival()
    }

    /// The lock screen's counter came on / went off screen. Only matters when FSEvents could
    /// not start: then a cheap stat check runs while a counter is visible, and only then.
    func counterAppeared() {
        visibleCounters += 1
        if visibleCounters == 1 { worker?.setVisible(true) }
    }

    func counterDisappeared() {
        visibleCounters = max(0, visibleCounters - 1)
        if visibleCounters == 0 { worker?.setVisible(false) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (TokenUsageMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func apply(_ snapshot: TokenUsageSnapshot, generation: Int) {
        guard generation == self.generation else { return }
        if todayTokens != snapshot.todayTokens { todayTokens = snapshot.todayTokens }
        if yearTokens != snapshot.yearTokens { yearTokens = snapshot.yearTokens }
        if yearCost != snapshot.yearCost { yearCost = snapshot.yearCost }
        if year != snapshot.year { year = snapshot.year }
        if isCounting != snapshot.isCounting { isCounting = snapshot.isCounting }
        if recent != snapshot.recent { recent = snapshot.recent }
        if snapshot.arrivedTokens > 0 {
            arrival = TokenArrival(serial: arrival.serial &+ 1, tokens: snapshot.arrivedTokens)
        }
    }
}

/// One live batch of tokens, as the view sees it.
struct TokenArrival: Equatable, Sendable {
    var serial = 0
    var tokens: Int64 = 0
}

/// KVO on one UserDefaults key — fires for Settings' own writes and for a `defaults write`.
private final class DefaultsKeyObserver: NSObject {
    private let defaults: UserDefaults
    private let key: String
    private let onChange: () -> Void

    init(defaults: UserDefaults, key: String, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.key = key
        self.onChange = onChange
        super.init()
        defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        onChange()
    }
}

/// Everything off the main thread: the engine, the FSEvents stream, the SQLite source, the
/// cache file. Confined to `queue`; public entry points hop onto it. `stop()` is final: a
/// stopped worker does nothing more and is released once its queue work drains.
final class TokenUsageWorker: @unchecked Sendable {
    /// Two passes a second at most, however many subagents write at once.
    static let passInterval = 0.5
    static let saveInterval = 30.0
    static let fsEventsLatency: CFTimeInterval = 1.0
    static let fallbackInterval = 5.0

    /// One serial utility queue for every worker, so a worker stopped and another started
    /// straight after (the setting flipped off and on) never touch the cache file at once.
    private static let sharedQueue = DispatchQueue(label: "com.eriknielsen.lockpaw.token-usage", qos: .utility)

    private var queue: DispatchQueue { Self.sharedQueue }
    private let paths: TokenUsagePaths
    private let engine: TokenUsageEngine
    private let opencode: OpencodeUsageSource
    private let publish: @Sendable (TokenUsageSnapshot) -> Void
    /// Set from the main thread by `stop()`; read on the queue, including between the chunks
    /// of a first scan, so turning the counter off doesn't wait for the scan to finish.
    private let stopFlag = OSAllocatedUnfairLock(initialState: false)
    private var stopped: Bool { stopFlag.withLock { $0 } }

    // Resolved (symlink-free) paths, as FSEvents reports them. Set on the queue at start —
    // resolving touches the file system, which never happens on the main thread.
    private var realProjectsPrefix = ""
    private var realStatsPath = ""
    private var realDatabasePath = ""
    private var realWALPath = ""
    private var lastStatsStamp: Double?

    private var stream: FSEventStreamRef?
    private var fallbackTimer: DispatchSourceTimer?
    private var fallbackTicks = 0
    private var usesFallback = false
    private var visible = false
    private var lastOpencodeStamp: (Double, UInt64)?

    private var ready = false
    private var counting = true
    private var dirtyFiles = Set<String>()
    private var fullCheck = false
    private var opencodeDirty = false
    private var statsDirty = false
    private var calendarDirty = false
    /// A new calendar after a time-zone change, applied by the next pass.
    private var pendingCalendar: Calendar?
    private var passScheduled = false
    private var opencodeRetryScheduled = false
    private var passThrottle = PublishThrottle(interval: passInterval)
    private var publishThrottle = PublishThrottle(interval: passInterval)
    private var pendingSnapshot: TokenUsageSnapshot?
    private var publishScheduled = false
    private var savedRevision = -1
    private var lastSave = -Double.infinity
    private var saveScheduled = false
    private var loggedOpencode: OpencodeReadError?

    init(paths: TokenUsagePaths, publish: @escaping @Sendable (TokenUsageSnapshot) -> Void) {
        self.paths = paths
        self.engine = TokenUsageEngine(paths: paths, calendar: .current)
        self.opencode = OpencodeUsageSource(url: paths.opencodeDatabase)
        self.publish = publish
        engine.shouldStop = { [stopFlag] in stopFlag.withLock { $0 } }
    }

    private func resolvePaths() {
        let projects = Self.resolved(paths.projects.path)
        realProjectsPrefix = projects.hasSuffix("/") ? projects : projects + "/"
        realStatsPath = Self.resolved(paths.statsCache.path)
        realDatabasePath = Self.resolved(paths.opencodeDatabase.path)
        realWALPath = realDatabasePath + "-wal"
    }

    private static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else {
            // Not there yet: resolve the parent so a later file still matches.
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path, let realParent = realpath(parent, nil) else { return path }
            defer { free(realParent) }
            return (String(cString: realParent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        }
        defer { free(real) }
        return String(cString: real)
    }

    private var uptime: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Start and stop

    func start() {
        queue.async { self.initialLoad() }
    }

    /// Final. Raises the flag at once (a running scan sees it within a chunk), then on the
    /// queue closes the stream, the timer and the database, and saves what a finished scan
    /// knows so the next start resumes.
    func stop() {
        stopFlag.withLock { $0 = true }
        queue.async { self.shutDown() }
    }

    private func shutDown() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        fallbackTimer?.cancel()
        fallbackTimer = nil
        if ready && engine.revision != savedRevision { writeCache() }
        ready = false
        pendingSnapshot = nil
        dirtyFiles.removeAll()
        opencode.close()
        logger.info("stopped")
    }

    private func initialLoad() {
        guard !stopped else { return }
        // The stream starts first: anything written during the scan queues up behind it on
        // this serial queue and is read from the stored offsets afterwards.
        resolvePaths()
        startStream()
        let clock = Date()
        let cache = TokenUsageCache.load(from: paths.cacheFile)
        let resumed = engine.begin(with: cache)
        logger.info("start: claude \(resumed.claude ? "resumed" : "full scan", privacy: .public), opencode \(resumed.opencode ? "resumed" : "full scan", privacy: .public)")

        if resumed.claude {
            // Known numbers immediately, then catch up on what changed while we were away.
            counting = false
            emit(force: true)
            engine.syncClaude(paths: nil)
        } else {
            engine.syncClaude(paths: nil) { self.emitProgress() }
            engine.reconcileClaudeAfterScan()
        }
        guard !stopped else { return }
        if resumed.opencode {
            report(engine.pollOpencode(opencode))
        } else {
            report(engine.scanOpencodeYear(opencode) { self.emitProgress() })
        }
        // A scan cut short is partial: it is never published as done, and never saved.
        guard !stopped else { return }
        if !resumed.claude || !resumed.opencode { engine.finishFullScan() }
        counting = false
        engine.reportsArrivals = true
        ready = true
        logger.info("start: ready in \(Date().timeIntervalSince(clock), format: .fixed(precision: 2), privacy: .public)s, read \(self.engine.bytesRead, privacy: .public) bytes from \(self.engine.filesRead, privacy: .public) files")
        emit(force: true)
        save(force: true)
        schedulePass()
    }

    private func emitProgress() {
        guard counting, publishThrottle.delay(now: uptime) == 0 else { return }
        emit(force: false)
    }

    // MARK: Events

    private func startStream() {
        var roots: [String] = []
        let fm = FileManager.default
        let claudeRoot = Self.resolved(paths.claudeConfig.path)
        if fm.fileExists(atPath: claudeRoot) { roots.append(claudeRoot) }
        let opencodeRoot = (realDatabasePath as NSString).deletingLastPathComponent
        if fm.fileExists(atPath: opencodeRoot) { roots.append(opencodeRoot) }
        guard !roots.isEmpty else {
            logger.info("no Claude Code or opencode data folders — counting zero until they appear")
            enableFallback(reason: "no data folders")
            return
        }
        // The stream retains the worker until `shutDown` releases the stream, so a callback
        // can never reach a freed worker.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<TokenUsageWorker>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<TokenUsageWorker>.fromOpaque(info).release()
            },
            copyDescription: nil)
        // No kFSEventStreamCreateFlagNoDefer: events coalesce over the latency window.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(nil, tokenUsageEventCallback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               Self.fsEventsLatency, flags) else {
            enableFallback(reason: "FSEventStreamCreate failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            enableFallback(reason: "FSEventStreamStart failed")
            return
        }
        self.stream = stream
    }

    /// FSEvents callback, on `queue`. Only transcripts, the stats cache and the opencode
    /// database/WAL matter; everything else in those folders is ignored.
    fileprivate func handle(paths eventPaths: [String], flags: [FSEventStreamEventFlags]) {
        guard !stopped else { return }
        var relevant = false
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                                  | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for (path, flag) in zip(eventPaths, flags) {
            if flag & rescanFlags != 0 {
                fullCheck = true
                opencodeDirty = true
                statsDirty = true
                relevant = true
            } else if path.hasPrefix(realProjectsPrefix) {
                if TokenUsageEngine.isTranscript((path as NSString).lastPathComponent) {
                    dirtyFiles.insert(paths.projects.path + "/" + path.dropFirst(realProjectsPrefix.count))
                    relevant = true
                }
            } else if path == realStatsPath {
                statsDirty = true
                relevant = true
            } else if path == realDatabasePath || path == realWALPath {
                opencodeDirty = true
                relevant = true
            }
        }
        if relevant { schedulePass() }
    }

    func recheck(reason: String) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            logger.info("recheck: \(reason, privacy: .public)")
            self.fullCheck = true
            self.opencodeDirty = true
            self.statsDirty = true
            self.calendarDirty = true
            self.schedulePass()
        }
    }

    func calendarChanged(resetTimeZone: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if resetTimeZone {
                NSTimeZone.resetSystemTimeZone()
                self.pendingCalendar = Calendar.current
            }
            self.calendarDirty = true
            self.schedulePass()
        }
    }

    // MARK: Passes

    /// One pass per throttle window, however many events arrive.
    private func schedulePass() {
        guard ready, !stopped, !passScheduled else { return }
        passScheduled = true
        queue.asyncAfter(deadline: .now() + passThrottle.delay(now: uptime)) { [weak self] in
            guard let self else { return }
            self.passScheduled = false
            guard !self.stopped else { return }
            self.runPass()
        }
    }

    private func runPass() {
        passThrottle.fire(now: uptime)

        // Every pass re-reads the date, so a midnight slept through still rolls over.
        let calendar = pendingCalendar
        pendingCalendar = nil
        switch engine.refreshCalendar(calendar) {
        case .year:
            rebuildAll()
            return
        case .day:
            calendarDirty = true
        case .none:
            break
        }
        if calendarDirty || statsDirty {
            let reload = statsDirty
            calendarDirty = false
            statsDirty = false
            if engine.reconcileStats(reload: reload) == .rebuildNeeded {
                logger.info("stats cache moved its cutoff — rescanning transcripts")
                engine.rebuildClaude()
            }
        }
        if fullCheck {
            fullCheck = false
            dirtyFiles.removeAll()
            engine.syncClaude(paths: nil)
        } else if !dirtyFiles.isEmpty {
            let batch = dirtyFiles
            dirtyFiles.removeAll()
            engine.syncClaude(paths: batch)
        }
        if opencodeDirty {
            opencodeDirty = false
            report(engine.pollOpencode(opencode))
        }
        guard !stopped else { return }
        engine.pruneLedgers()
        emit(force: false)
        save(force: false)
    }

    private func rebuildAll() {
        logger.info("new year — counting from zero")
        // Everything is read again; pending work is moot.
        dirtyFiles.removeAll()
        fullCheck = false
        opencodeDirty = false
        statsDirty = false
        calendarDirty = false
        counting = true
        engine.reportsArrivals = false
        engine.begin(with: nil)
        engine.syncClaude(paths: nil) { self.emitProgress() }
        engine.reconcileClaudeAfterScan()
        report(engine.scanOpencodeYear(opencode) { self.emitProgress() })
        guard !stopped else { return }
        engine.finishFullScan()
        counting = false
        engine.reportsArrivals = true
        emit(force: true)
        save(force: true)
    }

    private func report(_ result: TokenUsageEngine.PollResult) {
        switch result {
        case .ok:
            loggedOpencode = nil
        case .busy:
            // Locked right now: one retry shortly — never block or spin.
            guard !opencodeRetryScheduled, !stopped else { return }
            opencodeRetryScheduled = true
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.opencodeRetryScheduled = false
                guard !self.stopped else { return }
                self.opencodeDirty = true
                self.schedulePass()
            }
        case .unavailable(let error):
            if loggedOpencode != error {
                loggedOpencode = error
                logger.info("opencode contributes 0: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Publishing

    /// Hands a snapshot to the main thread, at most twice a second; a snapshot that comes too
    /// soon is held and the newest one goes out when the window opens.
    private func emit(force: Bool) {
        guard !stopped else { return }
        let snapshot = engine.snapshot(isCounting: counting)
        if var pending = pendingSnapshot {
            pending.arrivedTokens += snapshot.arrivedTokens
            pendingSnapshot = TokenUsageSnapshot(year: snapshot.year, todayTokens: snapshot.todayTokens,
                                                 yearTokens: snapshot.yearTokens, yearCost: snapshot.yearCost,
                                                 isCounting: snapshot.isCounting, recent: snapshot.recent,
                                                 arrivedTokens: pending.arrivedTokens)
        } else {
            pendingSnapshot = snapshot
        }
        let delay = force ? 0 : publishThrottle.delay(now: uptime)
        if delay == 0 {
            flushSnapshot()
        } else if !publishScheduled {
            publishScheduled = true
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.publishScheduled = false
                self.flushSnapshot()
            }
        }
    }

    private func flushSnapshot() {
        guard !stopped, let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        publishThrottle.fire(now: uptime)
        publish(snapshot)
    }

    // MARK: Persistence

    /// Writes the cache at most every 30 s (and before quitting), only when something changed.
    private func save(force: Bool) {
        guard ready, !stopped, engine.revision != savedRevision else { return }
        let wait = lastSave + Self.saveInterval - uptime
        if !force && wait > 0 {
            guard !saveScheduled else { return }
            saveScheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.saveScheduled = false
                self.save(force: true)
            }
            return
        }
        writeCache()
    }

    private func writeCache() {
        lastSave = uptime
        savedRevision = engine.revision
        do {
            try engine.makeCache().write(to: paths.cacheFile)
        } catch {
            logger.error("could not save token cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called on the main thread at quit. Waits briefly for the queue; if a scan is still
    /// running the last 30 s simply get re-read next launch.
    func saveBeforeQuit() {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.save(force: true)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
    }

    // MARK: Fallback (no FSEvents)

    private func enableFallback(reason: String) {
        usesFallback = true
        logger.error("FSEvents unavailable (\(reason, privacy: .public)) — checking recent files every \(Self.fallbackInterval, privacy: .public)s while the counter is on screen")
        updateFallbackTimer()
    }

    func setVisible(_ visible: Bool) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.visible = visible
            self.updateFallbackTimer()
        }
    }

    private func updateFallbackTimer() {
        guard usesFallback && visible && !stopped else {
            fallbackTimer?.cancel()
            fallbackTimer = nil
            return
        }
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.fallbackInterval, repeating: Self.fallbackInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.fallbackTick() }
        fallbackTimer = timer
        timer.resume()
    }

    /// Stats only the transcripts written in the last ten minutes (every 30 s: all of them,
    /// to find new files), the stats cache and the opencode files.
    private func fallbackTick() {
        guard !stopped else { return }
        fallbackTicks += 1
        if fallbackTicks % 6 == 0 {
            fullCheck = true
        } else {
            dirtyFiles.formUnion(engine.recentlyActiveTranscripts(within: 600))
        }
        var info = stat()
        if stat(realWALPath, &info) == 0 || stat(realDatabasePath, &info) == 0 {
            let stamp = (Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9, UInt64(max(0, info.st_size)))
            if lastOpencodeStamp.map({ $0 != stamp }) ?? true { opencodeDirty = true }
            lastOpencodeStamp = stamp
        }
        if stat(realStatsPath, &info) == 0 {
            let stamp = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if lastStatsStamp.map({ $0 != stamp }) ?? false { statsDirty = true }
            lastStatsStamp = stamp
        }
        schedulePass()
    }
}

/// C trampoline for FSEvents; `info` is the worker, retained by the stream until it stops.
private func tokenUsageEventCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                                     _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                                     _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let worker = Unmanaged<TokenUsageWorker>.fromOpaque(info).takeUnretainedValue()
    let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
    worker.handle(paths: list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
}
