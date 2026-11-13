import Foundation

// Token counter — the pure core. Foundation only (no AppKit, no SwiftUI) and no I/O, so every
// rule here is unit-tested directly (LockpawTests/TokenUsageTests.swift). The engine that
// reads files and the SQLite source live in TokenUsageEngine.swift / OpencodeUsageSource.swift;
// the monitor in Controllers/TokenUsageMonitor.swift. See CLAUDE.md, "Token counter".

/// UserDefaults switch for the lock-screen counter (Settings → Lock Screen). Off by default:
/// anyone walking past can read a lock screen. Off means the monitor does not run at all —
/// no scan, no file events, no cache file, no database connection (`TokenUsageMonitor`).
enum TokenCounterPreference {
    static let showKey = "showTokenCounter"
    static let defaultShow = false
}

// MARK: - Counts

/// Tokens of one message, or a sum of them.
struct TokenCounts: Equatable, Codable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0

    var total: Int64 { input + output + reasoning + cacheRead + cacheWrite }
    var isZero: Bool { self == TokenCounts() }

    /// Field-wise maximum: a message logged several times while streaming carries its
    /// running totals, so the latest knowledge of each field is its largest value.
    func merged(with other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(input, other.input), output: max(output, other.output),
                    reasoning: max(reasoning, other.reasoning), cacheRead: max(cacheRead, other.cacheRead),
                    cacheWrite: max(cacheWrite, other.cacheWrite))
    }

    /// Field-wise increase over `old`, never negative.
    func increase(from old: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, input - old.input), output: max(0, output - old.output),
                    reasoning: max(0, reasoning - old.reasoning), cacheRead: max(0, cacheRead - old.cacheRead),
                    cacheWrite: max(0, cacheWrite - old.cacheWrite))
    }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, reasoning: a.reasoning + b.reasoning,
                    cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
}

// MARK: - Raw JSON bytes

/// Just enough of a JSON reader to pull a few members out of a transcript line without
/// decoding the rest. A Claude Code line can be megabytes of message content; walking it
/// structurally (strings skipped with `memchr`) and decoding only the small `usage` object
/// costs a fraction of a full parse and allocates nothing for the content.
enum JSONBytes {
    static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C
    static let openBrace: UInt8 = 0x7B, closeBrace: UInt8 = 0x7D
    static let openBracket: UInt8 = 0x5B, closeBracket: UInt8 = 0x5D
    static let comma: UInt8 = 0x2C, colon: UInt8 = 0x3A

    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }

    static func skipSpace(_ p: UnsafeRawBufferPointer, _ i: inout Int, _ end: Int) {
        while i < end && isSpace(p[i]) { i += 1 }
    }

    /// `i` on an opening quote → just past the closing one.
    static func skipString(_ p: UnsafeRawBufferPointer, _ i: inout Int, _ end: Int) -> Bool {
        guard i < end, p[i] == quote, let base = p.baseAddress else { return false }
        var j = i + 1
        while j < end {
            guard let hit = memchr(base + j, Int32(quote), end - j) else { return false }
            let q = base.distance(to: UnsafeRawPointer(hit))
            var slashes = 0
            var k = q - 1
            while k > i && p[k] == backslash { slashes += 1; k -= 1 }
            if slashes % 2 == 0 { i = q + 1; return true }
            j = q + 1
        }
        return false
    }

    /// `i` on the first byte of a value → just past it.
    static func skipValue(_ p: UnsafeRawBufferPointer, _ i: inout Int, _ end: Int) -> Bool {
        guard i < end else { return false }
        switch p[i] {
        case quote:
            return skipString(p, &i, end)
        case openBrace, openBracket:
            var depth = 0
            while i < end {
                let c = p[i]
                if c == quote {
                    guard skipString(p, &i, end) else { return false }
                    continue
                }
                if c == openBrace || c == openBracket {
                    depth += 1
                } else if c == closeBrace || c == closeBracket {
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                }
                i += 1
            }
            return false
        default:
            let start = i
            while i < end {
                let c = p[i]
                if c == comma || c == closeBrace || c == closeBracket || isSpace(c) { break }
                i += 1
            }
            return i > start
        }
    }

    /// Calls `body(key, value)` for each member of the object whose `{` is at or after `start`
    /// (whitespace allowed). Key ranges exclude the quotes; value ranges are the raw value.
    /// Returns false for malformed input — callers then drop the line.
    @discardableResult
    static func forEachMember(_ p: UnsafeRawBufferPointer, in range: Range<Int>,
                              _ body: (Range<Int>, Range<Int>) -> Void) -> Bool {
        var i = range.lowerBound
        let end = min(range.upperBound, p.count)
        skipSpace(p, &i, end)
        guard i < end, p[i] == openBrace else { return false }
        i += 1
        while true {
            skipSpace(p, &i, end)
            guard i < end else { return false }
            if p[i] == closeBrace { return true }
            let keyStart = i + 1
            guard skipString(p, &i, end) else { return false }
            let key = keyStart..<(i - 1)
            skipSpace(p, &i, end)
            guard i < end, p[i] == colon else { return false }
            i += 1
            skipSpace(p, &i, end)
            let valueStart = i
            guard skipValue(p, &i, end) else { return false }
            body(key, valueStart..<i)
            skipSpace(p, &i, end)
            guard i < end else { return false }
            if p[i] == comma { i += 1; continue }
            return p[i] == closeBrace
        }
    }

    static func equals(_ p: UnsafeRawBufferPointer, _ range: Range<Int>, _ literal: StaticString) -> Bool {
        guard range.count == literal.utf8CodeUnitCount, let base = p.baseAddress else { return false }
        return memcmp(base + range.lowerBound, literal.utf8Start, range.count) == 0
    }

    /// A JSON number as an integer: decimals truncate, `null`/anything else is nil.
    static func int64(_ p: UnsafeRawBufferPointer, _ range: Range<Int>) -> Int64? {
        guard !range.isEmpty else { return nil }
        var i = range.lowerBound
        var negative = false
        if p[i] == 0x2D { negative = true; i += 1 }
        var value: Int64 = 0
        var digits = 0
        while i < range.upperBound {
            let c = p[i]
            guard c >= 0x30 && c <= 0x39 else { break }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(Int64(c - 0x30))
            guard !o1 && !o2 else { return nil }
            value = a
            digits += 1
            i += 1
        }
        guard digits > 0 else { return nil }
        if i < range.upperBound {
            let c = p[i]
            // An exponent changes the magnitude — take the slow, exact path.
            if c == 0x65 || c == 0x45 { return double(p, range).map { Int64($0) } }
            guard c == 0x2E else { return nil }
        }
        return negative ? -value : value
    }

    static func double(_ p: UnsafeRawBufferPointer, _ range: Range<Int>) -> Double? {
        guard !range.isEmpty, range.count < 64 else { return nil }
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: p[range]), as: UTF8.self)
        return Double(text)
    }

    /// The value of a JSON string (range includes the quotes). Plain strings are copied
    /// straight from the bytes; escaped ones go through JSONSerialization.
    static func string(_ p: UnsafeRawBufferPointer, _ range: Range<Int>) -> String? {
        guard range.count >= 2, p[range.lowerBound] == quote, p[range.upperBound - 1] == quote else { return nil }
        let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
        let bytes = UnsafeRawBufferPointer(rebasing: p[inner])
        if let base = bytes.baseAddress, memchr(base, Int32(backslash), bytes.count) != nil {
            let data = Data(UnsafeRawBufferPointer(rebasing: p[range]))
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func contains(_ p: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = p.baseAddress, p.count >= needle.utf8CodeUnitCount else { return false }
        return memmem(base, p.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
}

// MARK: - Timestamps

/// RFC 3339 timestamps ("2026-11-05T10:12:13.123Z") read straight from bytes — a formatter
/// per line would dominate the scan.
enum ISOTimestamp {
    /// Seconds since 1970, or nil. `range` excludes the quotes.
    static func parse(_ p: UnsafeRawBufferPointer, _ range: Range<Int>) -> Double? {
        let n = range.count
        guard n >= 19 else { return nil }
        let s = range.lowerBound
        func digits(_ at: Int, _ count: Int) -> Int? {
            var v = 0
            for k in 0..<count {
                let c = p[s + at + k]
                guard c >= 0x30 && c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard let year = digits(0, 4), p[s + 4] == 0x2D, let month = digits(5, 2), p[s + 7] == 0x2D,
              let day = digits(8, 2), p[s + 10] == 0x54 || p[s + 10] == 0x20 || p[s + 10] == 0x74,
              let hour = digits(11, 2), p[s + 13] == 0x3A, let minute = digits(14, 2), p[s + 16] == 0x3A,
              let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var i = 19
        var fraction = 0.0
        if i < n, p[s + i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < n, p[s + i] >= 0x30, p[s + i] <= 0x39 {
                fraction += Double(p[s + i] - 0x30) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < n {
            let c = p[s + i]
            if c == 0x5A || c == 0x7A {
                i += 1
            } else if c == 0x2B || c == 0x2D {
                let sign = c == 0x2B ? 1 : -1
                guard n - i >= 3, let oh = digits(i + 1, 2) else { return nil }
                var om = 0
                if n - i >= 6, p[s + i + 3] == 0x3A, let m = digits(i + 4, 2) { om = m; i += 6 }
                else if n - i >= 5, let m = digits(i + 3, 2) { om = m; i += 5 }
                else { i += 3 }
                offset = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }
        }
        guard i == n else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        return Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
    }

    static func parse(_ text: String) -> Double? {
        var text = text
        return text.withUTF8 { parse(UnsafeRawBufferPointer($0), 0..<$0.count) }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - Local days

/// Buckets instants into local calendar days, keyed yyyymmdd (20261105). Lines in a
/// transcript are in time order, so the last day's bounds are cached and almost every lookup
/// is two comparisons. Rebuild it when the time zone changes.
struct LocalDayKeyer {
    let calendar: Calendar
    private var cachedStart = Double.infinity
    private var cachedEnd = -Double.infinity
    private var cachedKey = 0

    init(calendar: Calendar) { self.calendar = calendar }

    mutating func key(for time: Double) -> Int {
        if time >= cachedStart && time < cachedEnd { return cachedKey }
        let date = Date(timeIntervalSince1970: time)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let c = calendar.dateComponents([.year, .month, .day], from: start)
        cachedKey = (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
        cachedStart = start.timeIntervalSince1970
        cachedEnd = end.timeIntervalSince1970
        return cachedKey
    }

    /// Local midnight that starts the day `key`.
    func start(of key: Int) -> Double? {
        let comps = DateComponents(year: key / 10_000, month: key / 100 % 100, day: key % 100)
        guard let date = calendar.date(from: comps) else { return nil }
        return calendar.startOfDay(for: date).timeIntervalSince1970
    }

    /// The day after `key`.
    func next(after key: Int) -> Int? {
        guard let start = start(of: key),
              let next = calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: start)) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: next)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// The day before `key`.
    func previous(before key: Int) -> Int? {
        guard let start = start(of: key),
              let prev = calendar.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970: start)) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: prev)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// "2026-10-17" → 20261017.
    static func key(isoDate: String) -> Int? {
        let parts = isoDate.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return y * 10_000 + m * 100 + d
    }
}

// MARK: - Claude Code transcript lines

/// One assistant line's usage, as logged. The same message is logged once per content block
/// while it streams, so these are running totals — feed them through `UsageLedger`.
struct ClaudeUsageLine: Equatable, Sendable {
    var id: String
    var model: String
    var timestamp: Double
    var counts: TokenCounts
}

enum ClaudeTranscriptLine {
    static let syntheticModel = "<synthetic>"

    /// Byte prefilter run on every line before any parsing: a usage line names both `"usage"`
    /// and `"assistant"` as JSON tokens. Inside a JSON string those quotes are escaped
    /// (`\"usage\"`), so the huge user/tool-result lines almost never pass.
    static func mayCarryUsage(_ line: UnsafeRawBufferPointer) -> Bool {
        JSONBytes.contains(line, "\"usage\"") && JSONBytes.contains(line, "\"assistant\"")
    }

    /// The usage of an assistant line, or nil for anything that doesn't count: other line
    /// types, no timestamp, no `message.usage`, the `<synthetic>` model, malformed JSON.
    static func parse(_ p: UnsafeRawBufferPointer) -> ClaudeUsageLine? {
        var type: Range<Int>?, timestamp: Range<Int>?, message: Range<Int>?, requestID: Range<Int>?, uuid: Range<Int>?
        let ok = JSONBytes.forEachMember(p, in: 0..<p.count) { key, value in
            if JSONBytes.equals(p, key, "type") { type = value }
            else if JSONBytes.equals(p, key, "timestamp") { timestamp = value }
            else if JSONBytes.equals(p, key, "message") { message = value }
            else if JSONBytes.equals(p, key, "requestId") { requestID = value }
            else if JSONBytes.equals(p, key, "uuid") { uuid = value }
        }
        guard ok, let type, JSONBytes.equals(p, type, "\"assistant\""),
              let timestamp, timestamp.count > 2,
              let time = ISOTimestamp.parse(p, (timestamp.lowerBound + 1)..<(timestamp.upperBound - 1)),
              let message else { return nil }

        var id: Range<Int>?, model: Range<Int>?, usage: Range<Int>?
        guard JSONBytes.forEachMember(p, in: message, { key, value in
            if JSONBytes.equals(p, key, "id") { id = value }
            else if JSONBytes.equals(p, key, "model") { model = value }
            else if JSONBytes.equals(p, key, "usage") { usage = value }
        }), let usage, p[usage.lowerBound] == JSONBytes.openBrace else { return nil }

        let modelName = model.flatMap { JSONBytes.string(p, $0) } ?? ""
        guard modelName != syntheticModel else { return nil }
        guard let messageID = id.flatMap({ JSONBytes.string(p, $0) })
                ?? requestID.flatMap({ JSONBytes.string(p, $0) })
                ?? uuid.flatMap({ JSONBytes.string(p, $0) }),
              !messageID.isEmpty else { return nil }

        var counts = TokenCounts()
        var creation: Int64?, write5m: Int64?, write1h: Int64?
        guard JSONBytes.forEachMember(p, in: usage, { key, value in
            if JSONBytes.equals(p, key, "input_tokens") { counts.input = max(0, JSONBytes.int64(p, value) ?? 0) }
            else if JSONBytes.equals(p, key, "output_tokens") { counts.output = max(0, JSONBytes.int64(p, value) ?? 0) }
            else if JSONBytes.equals(p, key, "cache_read_input_tokens") { counts.cacheRead = max(0, JSONBytes.int64(p, value) ?? 0) }
            else if JSONBytes.equals(p, key, "cache_creation_input_tokens") { creation = JSONBytes.int64(p, value) }
            else if JSONBytes.equals(p, key, "cache_creation"), p[value.lowerBound] == JSONBytes.openBrace {
                JSONBytes.forEachMember(p, in: value) { k, v in
                    if JSONBytes.equals(p, k, "ephemeral_5m_input_tokens") { write5m = JSONBytes.int64(p, v) }
                    else if JSONBytes.equals(p, k, "ephemeral_1h_input_tokens") { write1h = JSONBytes.int64(p, v) }
                }
            }
        }) else { return nil }

        // `cache_creation_input_tokens` is the authoritative total; the per-lifetime
        // breakdown under `cache_creation` is only used when it is missing.
        counts.cacheWrite = max(0, creation ?? ((write5m ?? 0) + (write1h ?? 0)))
        return ClaudeUsageLine(id: messageID, model: modelName, timestamp: time, counts: counts)
    }

    static func parse(_ data: Data) -> ClaudeUsageLine? {
        data.withUnsafeBytes { parse($0) }
    }
}

// MARK: - opencode rows

/// One `session_message` assistant row from opencode's database. Rows are rewritten while the
/// reply streams, so like transcript lines they are running totals.
struct OpencodeRow: Equatable, Sendable {
    var id: String
    var createdMs: Int64
    var updatedMs: Int64
    var counts: TokenCounts
}

enum OpencodeUsage {
    /// `data.tokens` as stored: `{"input":…,"output":…,"reasoning":…,"cache":{"read":…,"write":…}}`.
    static func counts(tokensJSON: String?) -> TokenCounts {
        guard var text = tokensJSON, !text.isEmpty else { return TokenCounts() }
        return text.withUTF8 { buffer -> TokenCounts in
            let p = UnsafeRawBufferPointer(buffer)
            var counts = TokenCounts()
            JSONBytes.forEachMember(p, in: 0..<p.count) { key, value in
                if JSONBytes.equals(p, key, "input") { counts.input = max(0, JSONBytes.int64(p, value) ?? 0) }
                else if JSONBytes.equals(p, key, "output") { counts.output = max(0, JSONBytes.int64(p, value) ?? 0) }
                else if JSONBytes.equals(p, key, "reasoning") { counts.reasoning = max(0, JSONBytes.int64(p, value) ?? 0) }
                else if JSONBytes.equals(p, key, "cache"), p[value.lowerBound] == JSONBytes.openBrace {
                    JSONBytes.forEachMember(p, in: value) { k, v in
                        if JSONBytes.equals(p, k, "read") { counts.cacheRead = max(0, JSONBytes.int64(p, v) ?? 0) }
                        else if JSONBytes.equals(p, k, "write") { counts.cacheWrite = max(0, JSONBytes.int64(p, v) ?? 0) }
                    }
                }
            }
            return counts
        }
    }

    static func row(id: String, createdMs: Int64, updatedMs: Int64, tokensJSON: String?) -> OpencodeRow {
        OpencodeRow(id: id, createdMs: createdMs, updatedMs: updatedMs, counts: counts(tokensJSON: tokensJSON))
    }
}

// MARK: - Dedupe ledger

/// Increase-only accounting per message: each sighting adds only what grew since the last
/// one. Keys are 64-bit FNV-1a hashes of the message id (a collision is ~1e-8 likely at a
/// million ids and would only merge two messages' maxima). Entries not seen for a day are
/// pruned so memory stays bounded; `coverageStart` in the engine handles what that forgets.
struct UsageLedger: Sendable {
    struct Entry: Equatable, Sendable {
        var counts: TokenCounts
        var lastSeen: Double
    }

    private(set) var entries: [UInt64: Entry] = [:]
    var count: Int { entries.count }

    static func key(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    func contains(_ key: UInt64) -> Bool { entries[key] != nil }

    /// Records the running totals `counts` seen at `seen` and returns only the increase.
    mutating func record(_ key: UInt64, counts: TokenCounts, seen: Double) -> TokenCounts {
        if var entry = entries[key] {
            let merged = entry.counts.merged(with: counts)
            let grown = merged.increase(from: entry.counts)
            entry.counts = merged
            entry.lastSeen = max(entry.lastSeen, seen)
            entries[key] = entry
            return grown
        }
        entries[key] = Entry(counts: counts, lastSeen: seen)
        return counts
    }

    mutating func prune(olderThan cutoff: Double) {
        entries = entries.filter { $0.value.lastSeen >= cutoff }
    }

    /// Entries seen at or after `since`, for the persisted cache.
    func records(since: Double) -> [LedgerRecord] {
        entries.compactMap { key, entry in
            entry.lastSeen >= since ? LedgerRecord(key: key, entry: entry) : nil
        }
    }

    init(records: [LedgerRecord] = []) {
        for record in records { entries[record.key] = record.entry }
    }
}

/// A ledger entry in the cache file: one flat array per entry keeps the file small.
struct LedgerRecord: Codable, Equatable, Sendable {
    var key: UInt64
    var entry: UsageLedger.Entry

    init(key: UInt64, entry: UsageLedger.Entry) {
        self.key = key
        self.entry = entry
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        key = try c.decode(UInt64.self)
        var counts = TokenCounts()
        counts.input = try c.decode(Int64.self)
        counts.output = try c.decode(Int64.self)
        counts.reasoning = try c.decode(Int64.self)
        counts.cacheRead = try c.decode(Int64.self)
        counts.cacheWrite = try c.decode(Int64.self)
        let seen = try c.decode(Double.self)
        entry = UsageLedger.Entry(counts: counts, lastSeen: seen)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(key)
        let t = entry.counts
        for value in [t.input, t.output, t.reasoning, t.cacheRead, t.cacheWrite] { try c.encode(value) }
        try c.encode(entry.lastSeen)
    }
}

// MARK: - Claude Code stats cache (the baseline)

/// `~/.claude/stats-cache.json`, as far as the counter needs it.
struct ClaudeStatsCache: Decodable, Sendable {
    struct ModelTotals: Decodable, Sendable {
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheReadInputTokens: Int64 = 0
        var cacheCreationInputTokens: Int64 = 0
        var total: Int64 { inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens }

        init(inputTokens: Int64 = 0, outputTokens: Int64 = 0, cacheReadInputTokens: Int64 = 0, cacheCreationInputTokens: Int64 = 0) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = c.lenientInt(.inputTokens)
            outputTokens = c.lenientInt(.outputTokens)
            cacheReadInputTokens = c.lenientInt(.cacheReadInputTokens)
            cacheCreationInputTokens = c.lenientInt(.cacheCreationInputTokens)
        }
    }

    struct Day: Decodable, Sendable {
        var date: String
        var tokensByModel: [String: Int64]

        init(date: String, tokensByModel: [String: Int64]) {
            self.date = date
            self.tokensByModel = tokensByModel
        }
    }

    var lastComputedDate: String?
    var firstSessionDate: String?
    var modelUsage: [String: ModelTotals]?
    var dailyModelTokens: [Day]?

    init(lastComputedDate: String?, firstSessionDate: String?, modelUsage: [String: ModelTotals]?, dailyModelTokens: [Day]?) {
        self.lastComputedDate = lastComputedDate
        self.firstSessionDate = firstSessionDate
        self.modelUsage = modelUsage
        self.dailyModelTokens = dailyModelTokens
    }

    private enum CodingKeys: String, CodingKey {
        case lastComputedDate, firstSessionDate, modelUsage, dailyModelTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastComputedDate = try? c.decodeIfPresent(String.self, forKey: .lastComputedDate)
        firstSessionDate = try? c.decodeIfPresent(String.self, forKey: .firstSessionDate)
        modelUsage = try? c.decodeIfPresent([String: ModelTotals].self, forKey: .modelUsage)
        dailyModelTokens = try? c.decodeIfPresent([Day].self, forKey: .dailyModelTokens)
    }
}

private extension KeyedDecodingContainer {
    func lenientInt(_ key: Key) -> Int64 {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return max(0, v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key), v.isFinite { return max(0, Int64(v)) }
        return 0
    }
}

/// What the stats cache contributes to this year, and where transcripts take over.
struct ClaudeBaseline: Equatable, Sendable {
    var tokens: Int64 = 0
    /// Days up to and including this key come from the stats cache; later ones from
    /// transcripts. nil = no usable cache: transcripts cover the whole year.
    var cutoffKey: Int?
}

enum ClaudeStatsBaseline {
    /// The year rule. `modelUsage` is all-time since `firstSessionDate`, so it is this year's
    /// baseline only when the first session was this year; otherwise this year's days of
    /// `dailyModelTokens` count. Cached days count only through `lastComputedDate` — and never
    /// today, which transcripts own (a cache computed today would otherwise freeze the live
    /// count), so a cache that already holds today has today's per-model share taken back out
    /// of `modelUsage`.
    static func compute(_ stats: ClaudeStatsCache?, year: Int, todayKey: Int, yesterdayKey: Int,
                        firstSessionYear: Int?) -> ClaudeBaseline {
        guard let stats, let last = stats.lastComputedDate.flatMap(LocalDayKeyer.key(isoDate:)) else {
            return ClaudeBaseline()
        }
        let cutoff = min(last, yesterdayKey)
        let usage = stats.modelUsage ?? [:]
        let days = (stats.dailyModelTokens ?? []).compactMap { day -> (Int, [String: Int64])? in
            LocalDayKeyer.key(isoDate: day.date).map { ($0, day.tokensByModel) }
        }
        var result = ClaudeBaseline(cutoffKey: cutoff)

        if firstSessionYear == year {
            var excluded: [String: Int64] = [:]
            for (key, byModel) in days where key > cutoff && key <= last {
                for (model, tokens) in byModel { excluded[model, default: 0] += max(0, tokens) }
            }
            for (model, totals) in usage {
                let total = totals.total
                guard total > 0 else { continue }
                let keep = Double(max(0, total - (excluded[model] ?? 0))) / Double(total)
                result.tokens += Int64((Double(total) * keep).rounded())
            }
        } else {
            for (key, byModel) in days where key / 10_000 == year && key <= cutoff {
                for tokens in byModel.values where tokens > 0 { result.tokens += tokens }
            }
        }
        return result
    }
}

// MARK: - Live rate

/// Tokens per second over the last two minutes: the rate (last 60 s) and a 24-bar sparkline
/// of 5-second buckets. Samples are keyed by when the tokens were spent, so a batch that
/// lands a second late still lands in the right bar.
struct TokenRateWindow: Equatable, Sendable {
    static let bucketSeconds = 5.0
    static let bucketCount = 24
    static let rateSeconds = 60.0
    static var span: Double { bucketSeconds * Double(bucketCount) }

    struct Sample: Equatable, Sendable {
        var second: Int64
        var tokens: Int64
    }

    private(set) var samples: [Sample] = []

    mutating func add(_ tokens: Int64, at time: Double) {
        guard tokens > 0, time.isFinite else { return }
        let second = Int64(time.rounded(.down))
        if let last = samples.last, last.second <= second {
            if last.second == second { samples[samples.count - 1].tokens += tokens } else { samples.append(Sample(second: second, tokens: tokens)) }
            return
        }
        if let i = samples.firstIndex(where: { $0.second >= second }) {
            if samples[i].second == second { samples[i].tokens += tokens } else { samples.insert(Sample(second: second, tokens: tokens), at: i) }
        } else {
            samples.append(Sample(second: second, tokens: tokens))
        }
    }

    /// Drops what has scrolled out of the sparkline.
    mutating func prune(now: Double) {
        let floor = Int64((now - Self.span).rounded(.down))
        if let first = samples.firstIndex(where: { $0.second >= floor }) {
            if first > 0 { samples.removeFirst(first) }
        } else {
            samples.removeAll()
        }
    }

    /// Tokens spent in the last 60 s — which, over a 60 s window, is tokens per minute.
    func tokensPerMinute(now: Double) -> Int64 {
        let floor = now - Self.rateSeconds
        return samples.reduce(0) { Double($1.second) > floor ? $0 + $1.tokens : $0 }
    }

    /// 24 buckets of 5 s, oldest first; the last ends now.
    func buckets(now: Double) -> [Int64] {
        var out = [Int64](repeating: 0, count: Self.bucketCount)
        for sample in samples {
            let age = max(0, now - Double(sample.second))
            guard age < Self.span else { continue }
            out[Self.bucketCount - 1 - Int(age / Self.bucketSeconds)] += sample.tokens
        }
        return out
    }

    func isIdle(now: Double) -> Bool { tokensPerMinute(now: now) == 0 }
}

// MARK: - Throttle

/// "At most once per `interval`": how long to wait before the next run may go. Times are
/// injected (monotonic uptime in the app), so it is testable and immune to clock changes.
struct PublishThrottle: Equatable, Sendable {
    var interval: Double
    private(set) var lastFired: Double?

    init(interval: Double) { self.interval = interval }

    func delay(now: Double) -> Double {
        guard let lastFired else { return 0 }
        return min(interval, max(0, lastFired + interval - now))
    }

    mutating func fire(now: Double) { lastFired = now }
}

// MARK: - Line splitting

/// Splits a byte stream into complete lines, chunk by chunk. A line cut by a chunk boundary
/// is held until a later chunk completes it; `consumed` counts only complete lines'
/// bytes (newline included), so a reader resumes from it and re-reads an unfinished tail
/// rather than counting half a line. Lines longer than `maxLineBytes` are skipped whole.
struct LineSplitter {
    let maxLineBytes: Int
    private(set) var consumed: UInt64 = 0
    private var pending: [UInt8] = []
    private var pendingLength = 0
    private var discarding = false

    init(maxLineBytes: Int = 64 << 20) { self.maxLineBytes = maxLineBytes }

    /// Bytes of an unfinished last line.
    var pendingBytes: Int { pendingLength }

    mutating func feed(_ chunk: UnsafeRawBufferPointer, line: (UnsafeRawBufferPointer) -> Void) {
        guard let base = chunk.baseAddress, !chunk.isEmpty else { return }
        var start = 0
        while start < chunk.count {
            guard let hit = memchr(base + start, 0x0A, chunk.count - start) else {
                let rest = chunk.count - start
                pendingLength += rest
                if discarding || pendingLength > maxLineBytes {
                    discarding = true
                    pending = []
                } else {
                    pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[start...]))
                }
                return
            }
            let newline = base.distance(to: UnsafeRawPointer(hit))
            let length = pendingLength + (newline - start)
            if !discarding && length <= maxLineBytes {
                if pending.isEmpty {
                    line(UnsafeRawBufferPointer(rebasing: chunk[start..<newline]))
                } else {
                    pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[start..<newline]))
                    pending.withUnsafeBytes { line($0) }
                }
            }
            consumed += UInt64(length + 1)
            if pending.capacity > 4 << 20 { pending = [] } else { pending.removeAll(keepingCapacity: true) }
            pendingLength = 0
            discarding = false
            start = newline + 1
        }
    }
}

// MARK: - Transcript file plan

/// What we last knew about a transcript file. `offset` is the end of the last complete line
/// read; identity is inode + size + mtime.
struct TrackedFile: Codable, Equatable, Sendable {
    var inode: UInt64
    var size: UInt64
    var offset: UInt64
    var mtime: Double

    private enum CodingKeys: String, CodingKey {
        case inode = "i", size = "s", offset = "o", mtime = "m"
    }
}

enum TranscriptReadPlan: Equatable, Sendable {
    /// Nothing new.
    case unchanged
    /// Record where the file ends without reading it: everything in it predates what
    /// transcripts are counted for (or it is too big to read).
    case markOnly
    /// Read the bytes appended since `offset`.
    case read(from: UInt64)
    /// Replaced (new inode) or truncated: read it again from the start. The ledger keeps
    /// already-counted messages from counting twice.
    case rescan

    static let maxFileBytes: UInt64 = 1 << 30

    static func make(known: TrackedFile?, inode: UInt64, size: UInt64, mtime: Double, countFrom: Double,
                     maxBytes: UInt64 = maxFileBytes) -> TranscriptReadPlan {
        guard size <= maxBytes else { return .markOnly }
        if let known {
            if known.inode != inode || size < known.offset { return .rescan }
            return size > known.offset ? .read(from: known.offset) : .unchanged
        }
        return mtime < countFrom ? .markOnly : .read(from: 0)
    }
}

// MARK: - Formatting

enum TokenFormat {
    /// "1,234,567,890" — grouping fixed to commas so the rolling digits never reflow by locale.
    static func grouped(_ n: Int64) -> String {
        let digits = String(n.magnitude)
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3 + 1)
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    private static let units: [(Double, String, String)] = [
        (1e3, "K", "thousand"), (1e6, "M", "million"), (1e9, "B", "billion"), (1e12, "T", "trillion"),
    ]

    private static func scaled(_ n: Int64, decimals: (Double) -> Int) -> (String, Int)? {
        let v = Double(n.magnitude)
        guard v >= 1000 else { return nil }
        var index = units.lastIndex(where: { v >= $0.0 }) ?? 0
        while true {
            let value = v / units[index].0
            let places = decimals(value)
            let scale = pow(10, Double(places))
            let rounded = (value * scale).rounded() / scale
            if rounded >= 1000 && index + 1 < units.count { index += 1; continue }
            let text = String(format: "%.\(places)f", rounded)
            return ((n < 0 ? "-" : "") + text, index)
        }
    }

    /// Year-scale totals: "1.23B", "123.5B", "712.0K", "950".
    static func compact(_ n: Int64) -> String {
        guard let (text, unit) = scaled(n, decimals: { $0 < 10 ? 2 : 1 }) else { return String(n) }
        return text + units[unit].1
    }

    /// Chips and rates: "2.4M", "712K", "7.1K", "950".
    static func short(_ n: Int64) -> String {
        guard let (text, unit) = scaled(n, decimals: { $0 < 10 ? 1 : 0 }) else { return String(n) }
        return text + units[unit].1
    }

    /// "2.4M/min".
    static func rate(perMinute n: Int64) -> String { short(n) + "/min" }

    /// For VoiceOver: "123.5 billion", "950".
    static func spoken(_ n: Int64) -> String {
        guard let (text, unit) = scaled(n, decimals: { _ in 1 }) else { return String(n) }
        return text + " " + units[unit].2
    }
}
