import XCTest
import SQLite3
@testable import Lockpaw

// MARK: - Helpers

/// Fixed zone so "local day" is deterministic: Los Angeles is UTC−8 on 2026-11-05.
private let la: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
}()

/// 2026-11-05 12:00 PST.
private let noon = Date(timeIntervalSince1970: ISOTimestamp.parse("2026-11-05T20:00:00Z")!)

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func usageLine(id: String, model: String = "claude-opus-4-6", time: String = "2026-11-05T18:00:00Z",
                       input: Int = 0, output: Int = 0, cacheRead: Int = 0, write5m: Int = 0, write1h: Int = 0,
                       speed: String? = nil, geo: String? = nil, type: String = "assistant",
                       breakdown: Bool = true, pretty: Bool = false) -> String {
    var usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead,
                                "cache_creation_input_tokens": write5m + write1h, "service_tier": "standard"]
    if breakdown { usage["cache_creation"] = ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h] }
    if let speed { usage["speed"] = speed }
    if let geo { usage["inference_geo"] = geo }
    let object: [String: Any] = [
        "parentUuid": "p-1", "isSidechain": false, "type": type, "timestamp": time, "uuid": UUID().uuidString,
        "requestId": "req_" + id,
        "message": ["id": id, "type": "message", "role": "assistant", "model": model, "usage": usage,
                    // Content that mentions usage, braces and quotes must not confuse the scanner.
                    "content": [["type": "text", "text": "the \"usage\": {\"input_tokens\": 999} } ] in text"],
                                ["type": "tool_use", "name": "Write", "input": ["usage": ["input_tokens": 12345], "path": "/x"]]]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: pretty ? [.prettyPrinted] : [])
    return String(decoding: data, as: UTF8.self)
}

private func parse(_ line: String) -> ClaudeUsageLine? {
    ClaudeTranscriptLine.parse(Data(line.utf8))
}

private func prefilter(_ line: String) -> Bool {
    Data(line.utf8).withUnsafeBytes { ClaudeTranscriptLine.mayCarryUsage($0) }
}

/// A scratch Claude config dir + opencode path + cache file.
private struct Sandbox {
    let root: URL
    var paths: TokenUsagePaths
    var projects: URL { paths.projects }

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lockpaw-tokens-\(UUID().uuidString)", isDirectory: true)
        paths = TokenUsagePaths(claudeConfig: root.appendingPathComponent("claude", isDirectory: true),
                                opencodeDatabase: root.appendingPathComponent("opencode/opencode.db"),
                                cacheFile: root.appendingPathComponent("support/token-usage.json"))
        try! FileManager.default.createDirectory(at: paths.projects.appendingPathComponent("proj"), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String) -> URL { projects.appendingPathComponent("proj/\(name)") }

    func write(_ name: String, _ lines: [String], tail: String = "") {
        let url = file(name)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data((lines.map { $0 + "\n" }.joined() + tail).utf8).write(to: url)
    }

    func append(_ name: String, _ text: String) {
        let handle = try! FileHandle(forWritingTo: file(name))
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data(text.utf8))
        try! handle.close()
    }

    func stats(lastComputed: String = "2026-10-17", firstSession: String = "2026-01-15T09:30:00.000Z",
               usage: [String: [String: Int]] = ["claude-opus-4-6": ["inputTokens": 1_000_000, "outputTokens": 1_000_000,
                                                                     "cacheReadInputTokens": 10_000_000, "cacheCreationInputTokens": 2_000_000]],
               daily: [[String: Any]] = []) {
        let object: [String: Any] = ["version": 5, "lastComputedDate": lastComputed, "firstSessionDate": firstSession,
                                     "modelUsage": usage, "dailyModelTokens": daily]
        try! JSONSerialization.data(withJSONObject: object).write(to: paths.statsCache)
    }

    func engine(_ clock: TestClock, chunk: Int = 64) -> TokenUsageEngine {
        TokenUsageEngine(paths: paths, calendar: la, chunkSize: chunk, now: { clock.now })
    }
}

/// Runs an engine through a first launch the way the worker does.
private func firstScan(_ engine: TokenUsageEngine) {
    engine.begin(with: nil)
    engine.syncClaude(paths: nil)
    engine.reconcileClaudeAfterScan()
    engine.finishFullScan()
}

private final class StubOpencode: OpencodeRowSource {
    var rows: [OpencodeRow] = []
    var failure: OpencodeReadError?
    var queries: [(Int64, Int64, Int64)] = []

    func rows(updatedAfterMs: Int64, createdFromMs: Int64, createdToMs: Int64) -> Result<[OpencodeRow], OpencodeReadError> {
        queries.append((updatedAfterMs, createdFromMs, createdToMs))
        if let failure { return .failure(failure) }
        return .success(rows.filter { $0.updatedMs > updatedAfterMs && $0.createdMs >= createdFromMs && $0.createdMs < createdToMs })
    }
}

private func ms(_ iso: String) -> Int64 { Int64(ISOTimestamp.parse(iso)! * 1000) }

/// Dollar amounts compared to a relative tolerance.
private func assertClose(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9,
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, accuracy: tolerance * max(1, abs(b)), file: file, line: line)
}

/// Expected dollar amounts as a plain sum.
private func sum(_ terms: Double...) -> Double { terms.reduce(0, +) }

// MARK: - Parsing

final class TokenTranscriptLineTests: XCTestCase {
    func testReadsUsageModelIDAndTime() throws {
        let u = try XCTUnwrap(parse(usageLine(id: "msg_1", input: 2, output: 2668, cacheRead: 707_394, write1h: 3177, geo: "global")))
        XCTAssertEqual(u.id, "msg_1")
        XCTAssertEqual(u.model, "claude-opus-4-6")
        XCTAssertEqual(u.timestamp, ISOTimestamp.parse("2026-11-05T18:00:00Z"))
        XCTAssertEqual(u.counts, TokenCounts(input: 2, output: 2668, cacheRead: 707_394, cacheWrite1h: 3177))
        XCTAssertEqual(u.geo, "global")
    }

    func testTheRealLineShapeFromClaudeCodeParses() throws {
        let line = #"{"parentUuid":"a","isSidechain":false,"userType":"external","cwd":"/x","sessionId":"s","version":"2.1.0","message":{"model":"claude-opus-5-5","id":"msg_01X","type":"message","role":"assistant","content":[{"type":"text","text":"done \"ok\" {"}],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":3177,"cache_read_input_tokens":707394,"output_tokens":2668,"server_tool_use":{"web_search_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":3177,"ephemeral_5m_input_tokens":0},"speed":"standard","inference_geo":"global"}},"requestId":"req_1","type":"assistant","uuid":"u1","timestamp":"2026-11-05T10:12:13.123Z"}"#
        XCTAssertTrue(prefilter(line))
        let u = try XCTUnwrap(parse(line))
        XCTAssertEqual(u.model, "claude-opus-5-5")
        XCTAssertEqual(u.counts.total, 2 + 3177 + 707_394 + 2668)
        XCTAssertEqual(u.counts.cacheWrite1h, 3177)
        XCTAssertEqual(u.counts.cacheWrite5m, 0)
        XCTAssertEqual(u.speed, "standard")
    }

    func testSkipsWhatDoesNotCount() {
        XCTAssertNil(parse(usageLine(id: "m", type: "user")))
        XCTAssertNil(parse(usageLine(id: "m", model: "<synthetic>")))
        XCTAssertNil(parse(usageLine(id: "m", time: "")))
        XCTAssertNil(parse(usageLine(id: "m", time: "yesterday")))
        XCTAssertNil(parse(#"{"type":"assistant","timestamp":"2026-11-05T10:00:00Z","message":{"id":"m","model":"x"}}"#))
        XCTAssertNil(parse(#"{"type":"assistant","timestamp":"2026-11-05T10:00:00Z","message":{"id":"m","usage":null}}"#))
        XCTAssertNil(parse(#"{"type":"summary","summary":"usage"}"#))
    }

    func testMalformedAndTruncatedLinesAreDropped() {
        let good = usageLine(id: "m", output: 5)
        XCTAssertNil(parse(String(good.dropLast(10))))
        XCTAssertNil(parse("{"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("not json \"usage\" \"assistant\""))
    }

    func testNestedUsageInsideContentIsNotTheMessageUsage() throws {
        let u = try XCTUnwrap(parse(usageLine(id: "m", input: 7, output: 9)))
        XCTAssertEqual(u.counts.input, 7)
        XCTAssertEqual(u.counts.output, 9)
    }

    func testWithoutABreakdownCacheWritesAreOneHour() throws {
        let u = try XCTUnwrap(parse(usageLine(id: "m", write5m: 0, write1h: 500, breakdown: false)))
        XCTAssertEqual(u.counts.cacheWrite1h, 500)
        XCTAssertEqual(u.counts.cacheWrite5m, 0)
        let split = try XCTUnwrap(parse(usageLine(id: "m", write5m: 300, write1h: 200)))
        XCTAssertEqual(split.counts.cacheWrite5m, 300)
        XCTAssertEqual(split.counts.cacheWrite1h, 200)
    }

    func testFallsBackToRequestIDWithoutAMessageID() throws {
        let line = #"{"type":"assistant","timestamp":"2026-11-05T10:00:00Z","requestId":"req_9","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"output_tokens":2}}}"#
        XCTAssertEqual(try XCTUnwrap(parse(line)).id, "req_9")
    }

    func testEscapedStringsDecode() throws {
        let line = #"{"type":"assistant","timestamp":"2026-11-05T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-6","usage":{"input_tokens":1}}}"#
        XCTAssertEqual(try XCTUnwrap(parse(line)).id, "m1")
    }

    func testTimestampsWithOffsetsAndNoFraction() {
        XCTAssertEqual(ISOTimestamp.parse("2026-11-05T10:00:00Z"), ISOTimestamp.parse("2026-11-05T12:00:00+02:00"))
        XCTAssertEqual(ISOTimestamp.parse("2026-11-05T10:00:00.5Z"), ISOTimestamp.parse("2026-11-05T10:00:00Z")! + 0.5)
        XCTAssertEqual(ISOTimestamp.parse("1970-01-01T00:00:00Z"), 0)
        XCTAssertNil(ISOTimestamp.parse("2026-13-05T10:00:00Z"))
    }
}

final class TokenBytePrefilterTests: XCTestCase {
    /// Every usage line, however it is serialised, passes; parsing then agrees with a full
    /// JSONSerialization decode.
    func testNeverDropsARealUsageLine() throws {
        for pretty in [false, true] {
            for (i, model) in ["claude-opus-4-6", "glm-5.3", "claude-haiku-5-5"].enumerated() {
                let line = usageLine(id: "msg_\(i)", model: model, input: i + 1, output: 10 * i, cacheRead: 99, write5m: i, write1h: 7,
                                     speed: i == 1 ? "fast" : nil, geo: "us", pretty: pretty)
                XCTAssertTrue(prefilter(line), "prefilter dropped \(model) pretty=\(pretty)")
                let parsed = try XCTUnwrap(parse(line))
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let message = try XCTUnwrap(object["message"] as? [String: Any])
                let usage = try XCTUnwrap(message["usage"] as? [String: Any])
                XCTAssertEqual(parsed.counts.input, Int64(try XCTUnwrap(usage["input_tokens"] as? Int)))
                XCTAssertEqual(parsed.counts.output, Int64(try XCTUnwrap(usage["output_tokens"] as? Int)))
                XCTAssertEqual(parsed.counts.cacheWrite, Int64(try XCTUnwrap(usage["cache_creation_input_tokens"] as? Int)))
                XCTAssertEqual(parsed.model, message["model"] as? String)
            }
        }
        // Spaces around colons, as other serialisers write it.
        let spaced = #"{"type" : "assistant", "timestamp" : "2026-11-05T10:00:00Z", "message" : {"id" : "m", "model" : "claude-opus-4-6", "usage" : {"input_tokens" : 4}}}"#
        XCTAssertTrue(prefilter(spaced))
        XCTAssertEqual(try XCTUnwrap(parse(spaced)).counts.input, 4)
    }

    func testToolResultLinesAreRejectedWithoutParsing() {
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"{\"usage\":{\"type\":\"assistant\"}}"}]}}"#
        XCTAssertFalse(prefilter(toolResult))
    }
}

// MARK: - Dedupe

final class TokenUsageLedgerTests: XCTestCase {
    func testRepeatedStreamingLinesAddOnlyTheirGrowth() {
        var ledger = UsageLedger()
        let key = UsageLedger.key("msg_1")
        let first = ledger.record(key, counts: TokenCounts(input: 10, output: 5, cacheRead: 1000), seen: 1) { _ in 0 }
        XCTAssertEqual(first.tokens.total, 1015)
        let same = ledger.record(key, counts: TokenCounts(input: 10, output: 5, cacheRead: 1000), seen: 2) { _ in 0 }
        XCTAssertTrue(same.tokens.isZero)
        let grown = ledger.record(key, counts: TokenCounts(input: 10, output: 80, cacheRead: 1000), seen: 3) { _ in 0 }
        XCTAssertEqual(grown.tokens, TokenCounts(output: 75))
        // An out-of-order, smaller sighting never subtracts.
        let older = ledger.record(key, counts: TokenCounts(input: 10, output: 20, cacheRead: 1000), seen: 4) { _ in 0 }
        XCTAssertTrue(older.tokens.isZero)
    }

    func testCostGrowsWithTheMergedTotals() {
        var ledger = UsageLedger()
        let key = UsageLedger.key("m")
        let price: (TokenCounts) -> Double = { TokenPricing.cost($0, model: "claude-opus-4-6")! }
        let a = ledger.record(key, counts: TokenCounts(output: 1_000_000), seen: 0, price: price)
        let b = ledger.record(key, counts: TokenCounts(output: 2_000_000), seen: 0, price: price)
        assertClose(a.cost, 25)
        assertClose(b.cost, 25)
    }

    func testIDsUnseenForADayArePruned() {
        var ledger = UsageLedger()
        _ = ledger.record(UsageLedger.key("old"), counts: TokenCounts(input: 1), seen: 100) { _ in 0 }
        _ = ledger.record(UsageLedger.key("new"), counts: TokenCounts(input: 1), seen: 100 + 90_000) { _ in 0 }
        ledger.prune(olderThan: 100 + 90_000 - 86_400)
        XCTAssertFalse(ledger.contains(UsageLedger.key("old")))
        XCTAssertTrue(ledger.contains(UsageLedger.key("new")))
    }
}

// MARK: - Days

final class TokenLocalDayTests: XCTestCase {
    func testBucketsByLocalDateNotUTC() {
        var keyer = LocalDayKeyer(calendar: la)
        // 07:30 UTC on the 5th is 23:30 on the 4th in Los Angeles.
        XCTAssertEqual(keyer.key(for: ISOTimestamp.parse("2026-11-05T07:30:00Z")!), 20261104)
        XCTAssertEqual(keyer.key(for: ISOTimestamp.parse("2026-11-05T08:00:00Z")!), 20261105)
        XCTAssertEqual(keyer.key(for: ISOTimestamp.parse("2027-01-01T07:59:59Z")!), 20261231)
        XCTAssertEqual(keyer.key(for: ISOTimestamp.parse("2027-01-01T08:00:00Z")!), 20270101)
    }

    func testDSTDaysAreStillOneDay() {
        let keyer = LocalDayKeyer(calendar: la)
        // 2026-11-01 has 25 hours in Los Angeles.
        let start = keyer.start(of: 20261101)!, next = keyer.start(of: 20261102)!
        XCTAssertEqual(next - start, 25 * 3600)
        XCTAssertEqual(keyer.next(after: 20261231), 20270101)
        XCTAssertEqual(keyer.previous(before: 20260301), 20260228)
        XCTAssertEqual(LocalDayKeyer.key(isoDate: "2026-10-17"), 20261017)
        XCTAssertNil(LocalDayKeyer.key(isoDate: "garbage"))
    }
}

// MARK: - Prices

final class TokenPricingTests: XCTestCase {
    func testDatedAndPrefixedIDsMatchTheirFamily() {
        XCTAssertEqual(TokenPricing.family(for: "claude-opus-4-5-20251101"), "opus-4-5")
        XCTAssertEqual(TokenPricing.family(for: "claude-haiku-4-5-20251001"), "haiku-4-5")
        XCTAssertEqual(TokenPricing.family(for: "claude-sonnet-4-5-20250929"), "sonnet-4-5")
        XCTAssertEqual(TokenPricing.family(for: "claude-opus-5"), "opus-5")
        XCTAssertEqual(TokenPricing.family(for: "claude-opus-5-20260301"), "opus-5")
        XCTAssertEqual(TokenPricing.family(for: "claude-opus-5-5"), "opus-5-5")
        XCTAssertEqual(TokenPricing.family(for: "claude-fable-5-1"), "fable-5-1")
        XCTAssertEqual(TokenPricing.family(for: "claude-mythos-5-1"), "mythos-5-1")
        XCTAssertEqual(TokenPricing.family(for: "us.anthropic.claude-opus-4-6-v1:0"), "opus-4-6")
        XCTAssertEqual(TokenPricing.family(for: "anthropic/claude-sonnet-4.6"), "sonnet-4-6")
        XCTAssertEqual(TokenPricing.family(for: "claude-opus-4-6[1m]"), "opus-4-6")
    }

    func testUnknownAndNonAnthropicModelsAreUnpriced() {
        for model in ["glm-5.3", "z-ai/glm-5.3-flash", "deepseek-v4-flash", "deepseek/deepseek-v4-flash-0731",
                      "qwen/qwen3.8-flash", "x-ai/grok-4.6", "claude-opus-4-1", "claude-3-5-sonnet-20241022", "opus-4-6", ""] {
            XCTAssertNil(TokenPricing.family(for: model), "\(model) should be unpriced")
            XCTAssertNil(TokenPricing.cost(TokenCounts(input: 1_000_000), model: model))
        }
    }

    func testBaseRatesPerTokenKind() {
        let m = "claude-opus-4-6"
        assertClose(TokenPricing.cost(TokenCounts(input: 1_000_000), model: m)!, 5)
        assertClose(TokenPricing.cost(TokenCounts(output: 1_000_000), model: m)!, 25)
        assertClose(TokenPricing.cost(TokenCounts(cacheRead: 1_000_000), model: m)!, 0.5)
        assertClose(TokenPricing.cost(TokenCounts(cacheWrite5m: 1_000_000), model: m)!, 6.25)
        assertClose(TokenPricing.cost(TokenCounts(cacheWrite1h: 1_000_000), model: m)!, 10)
        assertClose(TokenPricing.cost(TokenCounts(input: 1_000_000, output: 1_000_000), model: "claude-opus-5-5")!, 24)
        assertClose(TokenPricing.cost(TokenCounts(cacheRead: 1_000_000), model: "claude-sonnet-5-5")!, 0.10)
        assertClose(TokenPricing.cost(TokenCounts(cacheRead: 1_000_000), model: "claude-fable-5")!, 1)
        assertClose(TokenPricing.cost(TokenCounts(cacheRead: 1_000_000), model: "claude-fable-5-1")!, 0.25)
        XCTAssertEqual(TokenPricing.fetchedOn, "2026-11-05")
    }

    func testHaikuFiveFiveLongPromptTier() {
        let m = "claude-haiku-5-5"
        // Prompt = input + cache read + cache write; the tier starts above 100K.
        let atLimit = TokenCounts(input: 50_000, output: 1_000, cacheRead: 40_000, cacheWrite1h: 10_000)
        let baseTier = [50_000.0 * 0.10, 1_000.0 * 0.50, 40_000.0 * 0.01, 10_000.0 * 0.20].reduce(0, +) / 1e6
        assertClose(TokenPricing.cost(atLimit, model: m)!, baseTier)
        let over = TokenCounts(input: 50_001, output: 1_000, cacheRead: 40_000, cacheWrite1h: 10_000)
        let longTier = [50_001.0 * 0.50, 1_000.0 * 2.50, 40_000.0 * 0.05, 10_000.0 * 1.0].reduce(0, +) / 1e6
        assertClose(TokenPricing.cost(over, model: m)!, longTier)
        let over5m = TokenCounts(input: 200_000, cacheWrite5m: 1_000)
        let longWrite = [200_000.0 * 0.50, 1_000.0 * 0.625].reduce(0, +) / 1e6
        assertClose(TokenPricing.cost(over5m, model: m)!, longWrite)
        // Summed stats-cache totals are never judged as one huge prompt.
        assertClose(TokenPricing.cost(TokenCounts(input: 1_000_000), model: m, aggregate: true)!, 0.10)
    }

    func testFastModeRatesAndScaledCache() {
        let c = TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000)
        // opus-5-5: in 8, out 40, cache ×2.
        assertClose(TokenPricing.cost(c, model: "claude-opus-5-5", speed: "fast")!, sum(8, 40, 0.4, 10, 16))
        // opus-5 and opus-4-8: in 10, out 50, cache ×2.
        assertClose(TokenPricing.cost(c, model: "claude-opus-5", speed: "fast")!, sum(10, 50, 1, 12.5, 20))
        assertClose(TokenPricing.cost(c, model: "claude-opus-4-8", speed: "fast")!, sum(10, 50, 1, 12.5, 20))
        // No fast price listed: base rates.
        assertClose(TokenPricing.cost(c, model: "claude-opus-4-6", speed: "fast")!, sum(5, 25, 0.5, 6.25, 10))
        assertClose(TokenPricing.cost(c, model: "claude-opus-5", speed: "standard")!, sum(5, 25, 0.5, 6.25, 10))
    }

    func testUSGeoIsTenPercentOnFourSixAndLater() {
        let c = TokenCounts(input: 1_000_000)
        assertClose(TokenPricing.cost(c, model: "claude-opus-4-6", geo: "us")!, 5.5)
        assertClose(TokenPricing.cost(c, model: "claude-sonnet-5", geo: "us")!, 2.2)
        assertClose(TokenPricing.cost(c, model: "claude-opus-4-5-20251101", geo: "us")!, 5)
        assertClose(TokenPricing.cost(c, model: "claude-haiku-4-5-20251001", geo: "us")!, 1)
        assertClose(TokenPricing.cost(c, model: "claude-opus-4-6", geo: "global")!, 5)
        // Fast and US together.
        assertClose(TokenPricing.cost(c, model: "claude-opus-5", speed: "fast", geo: "us")!, 11)
    }

    func testFiveMinuteAndOneHourWritesPriceDifferently() {
        assertClose(TokenPricing.cost(TokenCounts(cacheWrite5m: 2_000_000, cacheWrite1h: 1_000_000), model: "claude-sonnet-4-6")!, sum(7.5, 6))
    }
}

// MARK: - Baseline

final class TokenStatsBaselineTests: XCTestCase {
    private let stats = ClaudeStatsCache(
        lastComputedDate: "2026-10-17", firstSessionDate: "2026-01-15T09:30:00.000Z",
        modelUsage: ["claude-opus-4-6": .init(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadInputTokens: 10_000_000, cacheCreationInputTokens: 2_000_000),
                     "glm-5.3": .init(inputTokens: 500, outputTokens: 500)],
        dailyModelTokens: [.init(date: "2025-12-31", tokensByModel: ["claude-opus-4-6": 999]),
                           .init(date: "2026-07-01", tokensByModel: ["claude-opus-4-6": 1_400_000, "glm-5.3": 100]),
                           .init(date: "2026-10-17", tokensByModel: ["claude-opus-4-6": 700_000])])

    func testFirstSessionThisYearUsesModelUsage() {
        var split = CacheWriteSplit()
        split.add(family: "opus-4-6", fiveMinute: 1_000_000, oneHour: 3_000_000)
        let b = ClaudeStatsBaseline.compute(stats, year: 2026, todayKey: 20261105, yesterdayKey: 20261104, firstSessionYear: 2026, split: split)
        XCTAssertEqual(b.tokens, 14_000_000 + 1_000)
        XCTAssertEqual(b.cutoffKey, 20261017)
        // 2M cache writes split 25% 5-minute / 75% 1-hour by the measured ratio.
        assertClose(b.cost, sum(5, 25, 5, 0.5 * 6.25, 1.5 * 10))
    }

    func testFirstSessionLastYearUsesThisYearsDaysAtBlendedRates() {
        let b = ClaudeStatsBaseline.compute(stats, year: 2026, todayKey: 20261105, yesterdayKey: 20261104, firstSessionYear: 2025, split: CacheWriteSplit())
        // 2025-12-31 is not this year; both 2026 days count, through lastComputedDate.
        XCTAssertEqual(b.tokens, 1_400_000 + 100 + 700_000)
        let blended = ClaudeStatsBaseline.cost(of: stats.modelUsage!["claude-opus-4-6"]!, model: "claude-opus-4-6", split: CacheWriteSplit())! / 14_000_000
        assertClose(b.cost, 2_100_000 * blended)
    }

    func testNoMeasuredSplitMeansOneHourWritesThenTheGlobalRatio() {
        let totals = ClaudeStatsCache.ModelTotals(cacheCreationInputTokens: 1_000_000)
        assertClose(ClaudeStatsBaseline.cost(of: totals, model: "claude-opus-4-6", split: CacheWriteSplit())!, 10)
        var global = CacheWriteSplit()
        global.add(family: "sonnet-4-6", fiveMinute: 500, oneHour: 500)   // too little for its own ratio, but it is all there is
        assertClose(ClaudeStatsBaseline.cost(of: totals, model: "claude-opus-4-6", split: global)!, 0.5 * 6.25 + 0.5 * 10)
        var own = global
        own.add(family: "opus-4-6", fiveMinute: 0, oneHour: 2_000_000)
        assertClose(ClaudeStatsBaseline.cost(of: totals, model: "claude-opus-4-6", split: own)!, 10)
    }

    func testCachedDaysNeverIncludeToday() {
        // A cache computed today: today's share comes back out of modelUsage, transcripts own it.
        var today = stats
        today.lastComputedDate = "2026-11-05"
        today.dailyModelTokens!.append(.init(date: "2026-11-05", tokensByModel: ["claude-opus-4-6": 7_000_000]))
        let b = ClaudeStatsBaseline.compute(today, year: 2026, todayKey: 20261105, yesterdayKey: 20261104, firstSessionYear: 2026, split: CacheWriteSplit())
        XCTAssertEqual(b.cutoffKey, 20261104)
        XCTAssertEqual(b.tokens, 7_000_000 + 1_000)
    }

    func testNoCacheMeansTranscriptsCoverTheYear() {
        let b = ClaudeStatsBaseline.compute(nil, year: 2026, todayKey: 20261105, yesterdayKey: 20261104, firstSessionYear: nil, split: CacheWriteSplit())
        XCTAssertEqual(b, ClaudeBaseline())
    }
}

// MARK: - opencode

final class OpencodeUsageTests: XCTestCase {
    func testTokensJSONParses() {
        let counts = OpencodeUsage.counts(tokensJSON: #"{"input":2110,"output":228,"reasoning":497,"cache":{"read":98688,"write":12}}"#)
        XCTAssertEqual(counts.total, 2110 + 228 + 497 + 98688 + 12)
        XCTAssertEqual(counts.reasoning, 497)
        XCTAssertTrue(OpencodeUsage.counts(tokensJSON: nil).isZero)
        XCTAssertTrue(OpencodeUsage.counts(tokensJSON: "garbage").isZero)
        XCTAssertEqual(OpencodeUsage.row(id: "r", createdMs: 1, updatedMs: 2, tokensJSON: nil, cost: -.infinity).cost, 0)
    }

    func testStreamingRowsAreDedupedAndCostIsRecorded() {
        let s = Sandbox(); defer { s.remove() }
        let engine = s.engine(TestClock(noon))
        engine.begin(with: nil)
        let source = StubOpencode()
        let created = ms("2026-11-05T19:00:00Z")
        source.rows = [OpencodeUsage.row(id: "a", createdMs: created, updatedMs: created + 1000, tokensJSON: #"{"input":100,"output":10}"#, cost: 0)]
        XCTAssertEqual(engine.scanOpencodeYear(source), .ok(rows: 1))
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 110)
        // The same row rewritten while streaming: only the growth counts, cost is opencode's own.
        source.rows = [OpencodeUsage.row(id: "a", createdMs: created, updatedMs: created + 5000, tokensJSON: #"{"input":100,"output":60,"reasoning":5}"#, cost: 0.25)]
        XCTAssertEqual(engine.pollOpencode(source), .ok(rows: 1))
        let snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.todayTokens, 165)
        assertClose(snap.yearCost, 0.25)
        // Re-reading it again (the poll overlaps) adds nothing.
        _ = engine.pollOpencode(source)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 165)
        // Last year's rows never count.
        source.rows.append(OpencodeUsage.row(id: "old", createdMs: ms("2025-12-31T12:00:00Z"), updatedMs: created + 9000, tokensJSON: #"{"input":5}"#, cost: 9))
        _ = engine.pollOpencode(source)
        XCTAssertEqual(engine.snapshot(isCounting: false).yearTokens, 165)
    }

    func testThePollUsesTheCreatedIndexWindow() throws {
        let s = Sandbox(); defer { s.remove() }
        let engine = s.engine(TestClock(noon))
        engine.begin(with: nil)
        let source = StubOpencode()
        let updated = ms("2026-11-05T19:00:00Z")
        source.rows = [OpencodeUsage.row(id: "a", createdMs: updated - 1000, updatedMs: updated, tokensJSON: #"{"input":1}"#, cost: 0)]
        _ = engine.scanOpencodeYear(source)
        XCTAssertGreaterThan(source.queries.count, 40)   // a week at a time
        _ = engine.pollOpencode(source)
        let poll = try XCTUnwrap(source.queries.last)
        XCTAssertEqual(poll.0, updated - TokenUsageEngine.opencodeOverlapMs)
        XCTAssertEqual(poll.1, updated - TokenUsageEngine.opencodeActiveWindowMs)
    }

    func testBusyOrMissingContributesNothingAndNeverThrows() {
        let s = Sandbox(); defer { s.remove() }
        let engine = s.engine(TestClock(noon))
        engine.begin(with: nil)
        let source = StubOpencode()
        source.failure = .busy
        XCTAssertEqual(engine.scanOpencodeYear(source), .busy)
        XCTAssertTrue(engine.opencodeNeedsYearScan)
        source.failure = .schema("no such table: session_message")
        XCTAssertEqual(engine.pollOpencode(source), .unavailable(.schema("no such table: session_message")))
        XCTAssertEqual(engine.snapshot(isCounting: false).yearTokens, 0)
        // When it becomes readable later, the year is read — as history, not as a live arrival.
        engine.reportsArrivals = true
        source.failure = nil
        source.rows = [OpencodeUsage.row(id: "a", createdMs: ms("2026-03-01T12:00:00Z"), updatedMs: ms("2026-03-01T12:01:00Z"),
                                         tokensJSON: #"{"input":500}"#, cost: 0)]
        XCTAssertEqual(engine.pollOpencode(source), .ok(rows: 1))
        let snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.yearTokens, 500)
        XCTAssertEqual(snap.arrivedTokens, 0)
        XCTAssertTrue(engine.reportsArrivals)
    }

    func testReadsARealSQLiteFileReadOnly() throws {
        let s = Sandbox(); defer { s.remove() }
        let url = s.paths.opencodeDatabase
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(OpencodeUsageSource(url: url).rows(updatedAfterMs: 0, createdFromMs: 0, createdToMs: .max), .failure(.missing))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE other (x)", nil, nil, nil)
        let wrong = OpencodeUsageSource(url: url).rows(updatedAfterMs: 0, createdFromMs: 0, createdToMs: .max)
        guard case .failure(.schema) = wrong else { return XCTFail("expected a schema error, got \(wrong)") }
        sqlite3_exec(db, """
            CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL,
              time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            CREATE INDEX session_message_time_created_idx ON session_message (time_created);
            INSERT INTO session_message VALUES ('a','s','assistant',1,1000,2000,'{"cost":0.5,"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":7,"write":3}}}');
            INSERT INTO session_message VALUES ('b','s','user',2,1000,2000,'{"tokens":{"input":99}}');
            INSERT INTO session_message VALUES ('c','s','assistant',3,1000,2000,'{"time":{}}');
            """, nil, nil, nil)
        let source = OpencodeUsageSource(url: url)
        let rows = try source.rows(updatedAfterMs: 0, createdFromMs: 0, createdToMs: 5000).get()
        XCTAssertEqual(rows.map(\.id).sorted(), ["a", "c"])
        let a = try XCTUnwrap(rows.first { $0.id == "a" })
        XCTAssertEqual(a.counts.total, 23)
        XCTAssertEqual(a.cost, 0.5)
        XCTAssertTrue(try source.rows(updatedAfterMs: 2000, createdFromMs: 0, createdToMs: 5000).get().isEmpty)
        // The writer keeps writing while our connection stays open.
        sqlite3_exec(db, "UPDATE session_message SET time_updated = 3000, data = '{\"tokens\":{\"input\":50}}' WHERE id = 'c'", nil, nil, nil)
        XCTAssertEqual(try source.rows(updatedAfterMs: 2000, createdFromMs: 0, createdToMs: 5000).get().map(\.counts.input), [50])
    }
}

// MARK: - Formatting

final class TokenFormatTests: XCTestCase {
    func testFullDigitsAreGroupedWithCommas() {
        XCTAssertEqual(TokenFormat.grouped(1_234_567_890), "1,234,567,890")
        XCTAssertEqual(TokenFormat.grouped(0), "0")
        XCTAssertEqual(TokenFormat.grouped(999), "999")
        XCTAssertEqual(TokenFormat.grouped(1000), "1,000")
        XCTAssertEqual(TokenFormat.grouped(-12_345), "-12,345")
    }

    func testCompactNumbers() {
        XCTAssertEqual(TokenFormat.compact(1_234_567_890), "1.23B")
        XCTAssertEqual(TokenFormat.compact(123_456_000_000), "123.5B")
        XCTAssertEqual(TokenFormat.compact(950), "950")
        XCTAssertEqual(TokenFormat.compact(999_960), "1.00M")
        XCTAssertEqual(TokenFormat.compact(1_500_000_000_000), "1.50T")
        XCTAssertEqual(TokenFormat.short(712_000), "712K")
        XCTAssertEqual(TokenFormat.short(7_140), "7.1K")
        XCTAssertEqual(TokenFormat.short(999_700), "1.0M")
        XCTAssertEqual(TokenFormat.rate(perMinute: 2_400_000), "2.4M/min")
        XCTAssertEqual(TokenFormat.spoken(123_456_000_000), "123.5 billion")
    }

    func testDollars() {
        XCTAssertEqual(TokenFormat.cost(12_345.4), "$12,345")
        XCTAssertEqual(TokenFormat.cost(98_765.43), "$98,765")
        XCTAssertEqual(TokenFormat.cost(7.421), "$7.42")
        XCTAssertEqual(TokenFormat.cost(0), "$0.00")
        XCTAssertEqual(TokenFormat.cost(.nan), "$0")
    }
}

// MARK: - Rate window

final class TokenRateWindowTests: XCTestCase {
    func testTokensPerMinuteCountsTheLastSixtySeconds() {
        var w = TokenRateWindow()
        w.add(1_000, at: 1_000)
        w.add(2_000, at: 1_050)
        w.add(500, at: 1_050.7)   // same second merges
        XCTAssertEqual(w.samples.count, 2)
        XCTAssertEqual(w.tokensPerMinute(now: 1_055), 3_500)
        XCTAssertEqual(w.tokensPerMinute(now: 1_100), 2_500)
        XCTAssertTrue(w.isIdle(now: 1_111))
    }

    func testTwentyFourFiveSecondBucketsOldestFirst() {
        var w = TokenRateWindow()
        w.add(7, at: 1_000)   // the newest bucket
        w.add(3, at: 996)     // 4 s ago: still the newest bucket
        w.add(5, at: 994)     // 6 s ago: the one before
        w.add(9, at: 881)     // 119 s ago: the oldest
        w.add(4, at: 870)     // 130 s ago: scrolled off
        let b = w.buckets(now: 1_000)
        XCTAssertEqual(b.count, 24)
        XCTAssertEqual(b[23], 10)
        XCTAssertEqual(b[22], 5)
        XCTAssertEqual(b[0], 9)
        XCTAssertEqual(b.reduce(0, +), 24)
    }

    func testLateSamplesLandInTheirOwnSecondAndOldOnesArePruned() {
        var w = TokenRateWindow()
        w.add(1, at: 100)
        w.add(1, at: 90)   // arrived late, earlier time
        XCTAssertEqual(w.samples.map(\.second), [90, 100])
        w.prune(now: 215)
        XCTAssertEqual(w.samples.map(\.second), [100])
        w.prune(now: 500)
        XCTAssertTrue(w.samples.isEmpty)
    }

    func testPublishThrottleFiresAtMostOncePerInterval() {
        var t = PublishThrottle(interval: 0.5)
        XCTAssertEqual(t.delay(now: 10), 0)
        t.fire(now: 10)
        assertClose(t.delay(now: 10.2), 0.3)
        XCTAssertEqual(t.delay(now: 10.5), 0)
        XCTAssertEqual(t.delay(now: 11), 0)
        // A clock that ran backwards never stalls it for longer than one interval.
        XCTAssertEqual(t.delay(now: 2), 0.5)
    }
}

// MARK: - Appended-bytes reader

final class TokenTranscriptReaderTests: XCTestCase {
    func testLinesSplitAcrossChunksAreReassembled() {
        var splitter = LineSplitter()
        var lines: [String] = []
        let text = "first line\nsecond, a longer line\nthird"
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: 4) {
            bytes[start..<min(bytes.count, start + 4)].withUnsafeBytes { chunk in
                splitter.feed(chunk) { lines.append(String(decoding: $0, as: UTF8.self)) }
            }
        }
        XCTAssertEqual(lines, ["first line", "second, a longer line"])
        XCTAssertEqual(splitter.consumed, UInt64("first line\nsecond, a longer line\n".utf8.count))
        XCTAssertEqual(splitter.pendingBytes, 5)
    }

    func testOverlongLinesAreSkippedButCounted() {
        var splitter = LineSplitter(maxLineBytes: 8)
        var lines: [String] = []
        Array("0123456789abc\nok\n".utf8).withUnsafeBytes { chunk in
            splitter.feed(chunk) { lines.append(String(decoding: $0, as: UTF8.self)) }
        }
        XCTAssertEqual(lines, ["ok"])
        XCTAssertEqual(splitter.consumed, 17)
    }

    func testReadPlans() {
        let known = TrackedFile(inode: 7, size: 100, offset: 100, mtime: 50)
        XCTAssertEqual(TranscriptReadPlan.make(known: known, inode: 7, size: 100, mtime: 60, countFrom: 0), .unchanged)
        XCTAssertEqual(TranscriptReadPlan.make(known: known, inode: 7, size: 150, mtime: 60, countFrom: 0), .read(from: 100))
        XCTAssertEqual(TranscriptReadPlan.make(known: known, inode: 7, size: 40, mtime: 60, countFrom: 0), .rescan)
        XCTAssertEqual(TranscriptReadPlan.make(known: known, inode: 8, size: 150, mtime: 60, countFrom: 0), .rescan)
        XCTAssertEqual(TranscriptReadPlan.make(known: nil, inode: 9, size: 10, mtime: 5, countFrom: 10), .markOnly)
        XCTAssertEqual(TranscriptReadPlan.make(known: nil, inode: 9, size: 10, mtime: 15, countFrom: 10), .read(from: 0))
        XCTAssertEqual(TranscriptReadPlan.make(known: nil, inode: 9, size: 10, mtime: 15, countFrom: 10, maxBytes: 9), .markOnly)
    }

    func testAPartialLastLineWaitsForItsNewline() {
        let s = Sandbox(); defer { s.remove() }
        let engine = s.engine(TestClock(noon), chunk: 7)
        let third = usageLine(id: "c", output: 300)
        s.write("a.jsonl", [usageLine(id: "a", output: 100), usageLine(id: "b", output: 200)], tail: String(third.prefix(40)))
        firstScan(engine)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 300)
        s.append("a.jsonl", String(third.dropFirst(40)) + "\n")
        engine.syncClaude(paths: [s.file("a.jsonl").path])
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 600)
    }

    func testTruncatedOrReplacedFilesAreRescannedWithoutDoubleCounting() throws {
        let s = Sandbox(); defer { s.remove() }
        let engine = s.engine(TestClock(noon), chunk: 32)
        let lines = [usageLine(id: "a", output: 100), usageLine(id: "b", output: 200)]
        s.write("a.jsonl", lines)
        firstScan(engine)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 300)

        // Shrunk below the stored offset (rewritten): read from 0, the ledger skips a.
        s.write("a.jsonl", [lines[0]])
        engine.syncClaude(paths: nil)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 300)

        // Replaced by a new inode holding the old lines and a new one.
        let path = s.file("a.jsonl")
        try FileManager.default.removeItem(at: path)
        s.write("a.jsonl", lines + [usageLine(id: "e", output: 7)])
        engine.syncClaude(paths: [path.path])
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 307)
    }

    func testDeletedFilesAreForgottenButTheirTokensStay() throws {
        let s = Sandbox(); defer { s.remove() }
        let engine = s.engine(TestClock(noon))
        s.write("a.jsonl", [usageLine(id: "a", output: 100)])
        firstScan(engine)
        try FileManager.default.removeItem(at: s.file("a.jsonl"))
        engine.syncClaude(paths: [s.file("a.jsonl").path])
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 100)
        XCTAssertTrue(engine.makeCache().claude.files.isEmpty)
    }
}

// MARK: - Engine

final class TokenUsageEngineTests: XCTestCase {
    func testBaselinePlusTranscriptsAfterTheCutoff() {
        let s = Sandbox(); defer { s.remove() }
        s.stats()
        s.write("a.jsonl", [
            usageLine(id: "before", time: "2026-10-17T20:00:00Z", output: 1_000),      // 10-17 local: in the stats cache
            usageLine(id: "after", time: "2026-10-18T20:00:00Z", output: 2_000),
            usageLine(id: "today", time: "2026-11-05T09:00:00Z", input: 10, output: 3_000),
            usageLine(id: "today", time: "2026-11-05T09:00:01Z", input: 10, output: 3_500), // streamed again
            usageLine(id: "glm", model: "glm-5.3", time: "2026-11-05T10:00:00Z", input: 40),
            usageLine(id: "yesterdayLocal", time: "2026-11-05T07:00:00Z", output: 4_000), // 23:00 on the 4th in LA
        ])
        let engine = s.engine(TestClock(noon))
        firstScan(engine)
        let snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.todayTokens, 3_510 + 40)
        XCTAssertEqual(snap.yearTokens, 14_000_000 + 2_000 + 3_510 + 40 + 4_000)
        let transcriptCost = sum(9_500 * 25, 10 * 5) / 1e6
        assertClose(snap.yearCost, sum(5, 25, 5, 20, transcriptCost))   // 2M writes, no split measured: 1-hour
        XCTAssertEqual(snap.year, 2026)
    }

    func testFilesOlderThanTheCutoffAreNeverRead() throws {
        let s = Sandbox(); defer { s.remove() }
        s.stats()
        s.write("old.jsonl", [usageLine(id: "x", time: "2026-11-05T09:00:00Z", output: 77)])   // content can't be trusted; mtime decides
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: ISOTimestamp.parse("2026-10-10T00:00:00Z")!)],
                                              ofItemAtPath: s.file("old.jsonl").path)
        s.write("x.superseded-1.jsonl", [usageLine(id: "y", output: 5)])
        let engine = s.engine(TestClock(noon))
        firstScan(engine)
        XCTAssertEqual(engine.bytesRead, 0)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 0)
    }

    func testSubagentTranscriptsCount() {
        let s = Sandbox(); defer { s.remove() }
        s.write("sess/subagents/agent-1.jsonl", [usageLine(id: "sub", output: 11)])
        s.write("sess.jsonl", [usageLine(id: "main", output: 22)])
        let engine = s.engine(TestClock(noon))
        firstScan(engine)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 33)
    }

    func testMissingFoldersCountZero() {
        let s = Sandbox(); defer { s.remove() }
        try? FileManager.default.removeItem(at: s.paths.claudeConfig)
        let engine = s.engine(TestClock(noon))
        firstScan(engine)
        XCTAssertEqual(engine.pollOpencode(OpencodeUsageSource(url: s.paths.opencodeDatabase)), .unavailable(.missing))
        let snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.todayTokens, 0)
        XCTAssertEqual(snap.yearTokens, 0)
        XCTAssertEqual(snap.yearCost, 0)
    }

    func testMidnightStartsANewDayAndJanuaryANewYear() {
        let s = Sandbox(); defer { s.remove() }
        let clock = TestClock(noon)
        let engine = s.engine(clock)
        s.write("a.jsonl", [usageLine(id: "a", time: "2026-11-05T09:00:00Z", output: 100)])
        firstScan(engine)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 100)
        clock.now = Date(timeIntervalSince1970: ISOTimestamp.parse("2026-11-06T08:30:00Z")!)   // 00:30 on the 6th
        XCTAssertEqual(engine.refreshCalendar(), .day)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 0)
        s.append("a.jsonl", usageLine(id: "b", time: "2026-11-06T08:29:00Z", output: 5) + "\n")
        engine.syncClaude(paths: nil)
        let snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.todayTokens, 5)
        XCTAssertEqual(snap.yearTokens, 105)
        clock.now = Date(timeIntervalSince1970: ISOTimestamp.parse("2027-01-01T08:00:01Z")!)
        XCTAssertEqual(engine.refreshCalendar(), .year)
    }

    func testLiveArrivalsFeedTheRateAndTheChip() {
        let s = Sandbox(); defer { s.remove() }
        let engine = s.engine(TestClock(noon))
        s.write("a.jsonl", [usageLine(id: "a", time: "2026-11-05T19:59:30Z", output: 100)])
        firstScan(engine)
        var snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.arrivedTokens, 0)                       // the scan is not an arrival
        XCTAssertEqual(snap.recent.tokensPerMinute(now: noon.timeIntervalSince1970), 100)
        engine.reportsArrivals = true
        s.append("a.jsonl", usageLine(id: "b", time: "2026-11-05T19:59:59Z", output: 40) + "\n")
        engine.syncClaude(paths: [s.file("a.jsonl").path])
        snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.arrivedTokens, 40)
        XCTAssertEqual(snap.recent.tokensPerMinute(now: noon.timeIntervalSince1970), 140)
        XCTAssertEqual(engine.snapshot(isCounting: false).arrivedTokens, 0)
    }

    func testAChangedLastComputedDateRebuildsAndAMovedCutoffDropsCoveredDays() {
        let s = Sandbox(); defer { s.remove() }
        s.stats(lastComputed: "2026-11-05", daily: [["date": "2026-11-05", "tokensByModel": ["claude-opus-4-6": 1_000_000]]])
        s.write("a.jsonl", [usageLine(id: "a", time: "2026-11-05T09:00:00Z", output: 100)])
        let clock = TestClock(noon)
        let engine = s.engine(clock)
        firstScan(engine)
        // Cache computed today: today still comes from transcripts.
        var snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.todayTokens, 100)
        XCTAssertEqual(snap.yearTokens, 13_000_000 + 100)
        // Next day: the cache now covers the 5th; its transcript day is dropped, no rescan.
        clock.now = Date(timeIntervalSince1970: ISOTimestamp.parse("2026-11-06T20:00:00Z")!)
        XCTAssertEqual(engine.refreshCalendar(), .day)
        XCTAssertEqual(engine.reconcileStats(reload: false), .baseline)
        snap = engine.snapshot(isCounting: false)
        XCTAssertEqual(snap.yearTokens, 14_000_000)
        // A recomputed stats cache: rebuild the transcript side.
        s.stats(lastComputed: "2026-11-06")
        XCTAssertEqual(engine.reconcileStats(reload: true), .rebuildNeeded)
    }

    /// Turning the counter off mid-scan: the engine stops between files and between chunks,
    /// and the opencode year scan stays undone rather than half-read.
    func testAStopRequestEndsAScanWithoutReadingFurther() {
        let s = Sandbox(); defer { s.remove() }
        s.write("a.jsonl", [usageLine(id: "a", output: 100)])
        s.write("b.jsonl", [usageLine(id: "b", output: 200)])
        let engine = s.engine(TestClock(noon))
        engine.shouldStop = { true }
        firstScan(engine)
        XCTAssertEqual(engine.bytesRead, 0)
        XCTAssertEqual(engine.snapshot(isCounting: false).todayTokens, 0)
        let source = StubOpencode()
        source.rows = [OpencodeUsage.row(id: "o", createdMs: ms("2026-03-01T12:00:00Z"), updatedMs: ms("2026-03-01T12:01:00Z"),
                                         tokensJSON: #"{"input":5}"#, cost: 0)]
        XCTAssertEqual(engine.scanOpencodeYear(source), .busy)
        XCTAssertTrue(source.queries.isEmpty)
        XCTAssertTrue(engine.opencodeNeedsYearScan)
    }
}

// MARK: - Cache file

final class TokenUsageCacheTests: XCTestCase {
    func testRoundTripsAndResumesWithoutReReading() throws {
        let s = Sandbox(); defer { s.remove() }
        s.stats()
        s.write("a.jsonl", [usageLine(id: "a", output: 100), usageLine(id: "b", time: "2026-10-20T10:00:00Z", output: 200)])
        s.write("sess/subagents/agent-1.jsonl", [usageLine(id: "c", output: 300)])
        let clock = TestClock(noon)
        let first = s.engine(clock)
        firstScan(first)
        let before = first.snapshot(isCounting: false)
        XCTAssertGreaterThan(first.bytesRead, 0)
        let made = first.makeCache()
        try made.write(to: s.paths.cacheFile)

        let cache = try XCTUnwrap(TokenUsageCache.load(from: s.paths.cacheFile))
        XCTAssertEqual(cache, made)
        let second = s.engine(clock)
        let resumed = second.begin(with: cache)
        XCTAssertTrue(resumed.claude)
        second.syncClaude(paths: nil)
        XCTAssertEqual(second.bytesRead, 0)
        let after = second.snapshot(isCounting: false)
        XCTAssertEqual(after.todayTokens, before.todayTokens)
        XCTAssertEqual(after.yearTokens, before.yearTokens)
        assertClose(after.yearCost, before.yearCost)

        // Only the appended bytes are read next time.
        let appended = usageLine(id: "d", output: 4) + "\n"
        s.append("a.jsonl", appended)
        second.syncClaude(paths: nil)
        XCTAssertEqual(second.bytesRead, UInt64(appended.utf8.count))
        XCTAssertEqual(second.snapshot(isCounting: false).todayTokens, before.todayTokens + 4)
    }

    func testAMessageStillStreamingAcrossARelaunchCountsOnce() throws {
        let s = Sandbox(); defer { s.remove() }
        let clock = TestClock(noon)
        let first = s.engine(clock)
        s.write("a.jsonl", [usageLine(id: "m", time: "2026-11-05T19:59:00Z", input: 10, output: 50, cacheRead: 5_000)])
        firstScan(first)
        let cache = first.makeCache()
        // After the relaunch the same message is logged again with more output; the file was
        // also replaced (new inode), so every line is read again.
        try FileManager.default.removeItem(at: s.file("a.jsonl"))
        s.write("a.jsonl", [usageLine(id: "m", time: "2026-11-05T19:59:00Z", input: 10, output: 50, cacheRead: 5_000),
                            usageLine(id: "m", time: "2026-11-05T19:59:30Z", input: 10, output: 90, cacheRead: 5_000)])
        let second = s.engine(clock)
        second.begin(with: cache)
        second.syncClaude(paths: nil)
        XCTAssertEqual(second.snapshot(isCounting: false).todayTokens, 5_100)
    }

    func testHistoryCopiedIntoANewFileIsNotCountedAgain() {
        let s = Sandbox(); defer { s.remove() }
        let clock = TestClock(Date(timeIntervalSince1970: ISOTimestamp.parse("2026-11-07T20:00:00Z")!))
        let engine = s.engine(clock)
        let old = usageLine(id: "old", time: "2026-11-05T18:00:00Z", output: 1_000)   // two days ago
        s.write("a.jsonl", [old])
        firstScan(engine)   // prunes the ledger to a day: "old" is forgotten
        XCTAssertEqual(engine.snapshot(isCounting: false).yearTokens, 1_000)
        // A resumed/forked session copies that history into a new file, then carries on.
        s.write("fork.jsonl", [old, usageLine(id: "new", time: "2026-11-07T19:59:00Z", output: 7)])
        engine.syncClaude(paths: [s.file("fork.jsonl").path])
        XCTAssertEqual(engine.snapshot(isCounting: false).yearTokens, 1_007)
    }

    func testUnreadableOrStaleCachesAreIgnored() throws {
        let s = Sandbox(); defer { s.remove() }
        try FileManager.default.createDirectory(at: s.paths.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: s.paths.cacheFile)
        XCTAssertNil(TokenUsageCache.load(from: s.paths.cacheFile))
        let engine = s.engine(TestClock(noon))
        var cache = engine.makeCache()
        cache.year = 2025
        let resumed = engine.begin(with: cache)
        XCTAssertFalse(resumed.claude)
        XCTAssertFalse(resumed.opencode)
        s.stats()
        let other = s.engine(TestClock(noon))
        var built = other.makeCache()
        built.claude.statsLastComputedDate = "2026-09-01"
        XCTAssertFalse(other.begin(with: built).claude)
    }

    func testTheCacheLivesInLockpawsApplicationSupportFolder() {
        let support = URL(fileURLWithPath: "/tmp/Support", isDirectory: true)
        let paths = TokenUsagePaths.standard(environment: [:], home: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
                                             applicationSupport: support)
        XCTAssertEqual(paths.cacheFile.path, "/tmp/Support/Lockpaw/token-usage.json")
        XCTAssertEqual(paths.claudeConfig.path, "/tmp/home/.claude")
        XCTAssertEqual(paths.opencodeDatabase.path, "/tmp/home/.local/share/opencode/opencode.db")
        let custom = TokenUsagePaths.standard(environment: ["CLAUDE_CONFIG_DIR": "/tmp/profile", "XDG_DATA_HOME": "/tmp/data"],
                                              home: URL(fileURLWithPath: "/tmp/home", isDirectory: true), applicationSupport: support)
        XCTAssertEqual(custom.claudeConfig.path, "/tmp/profile")
        XCTAssertEqual(custom.opencodeDatabase.path, "/tmp/data/opencode/opencode.db")
    }
}

// MARK: - Off by default, and off means off

@MainActor
final class TokenUsageMonitorTests: XCTestCase {
    private var sandbox: Sandbox!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Set when the monitor resolves its paths — which it does only to start a worker.
    private var pathsResolved = 0

    override func setUpWithError() throws {
        sandbox = Sandbox()
        // Today's tokens, so a running monitor has something to count and a cache to write.
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        sandbox.write("a.jsonl", [usageLine(id: "live", time: now, output: 100)])
        // Its own suite, never `.standard`: in the test host the app's shared monitor follows
        // `.standard`, and flipping the key there would start it on the machine's real data.
        suiteName = "com.eriknielsen.lockpaw.tests.TokenUsageMonitor"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        sandbox.remove()
    }

    private func makeMonitor() -> TokenUsageMonitor {
        TokenUsageMonitor(defaults: defaults, paths: { [unowned self] in
            self.pathsResolved += 1
            return self.sandbox.paths
        })
    }

    private var cacheExists: Bool { FileManager.default.fileExists(atPath: sandbox.paths.cacheFile.path) }

    private func waitUntil(_ seconds: Double = 10, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func testTheCounterIsOffByDefault() {
        XCTAssertFalse(TokenCounterPreference.defaultShow)
        XCTAssertEqual(TokenCounterPreference.showKey, "showTokenCounter")
    }

    /// With the setting never touched, nothing runs: no worker, no paths resolved (so no
    /// file access, no FSEvents stream, no SQLite connection), and no cache file appears.
    func testOffMeansTheMonitorNeverStarts() async throws {
        let monitor = makeMonitor()
        monitor.followPreference()
        XCTAssertFalse(monitor.isRunning)
        XCTAssertNil(monitor.worker)
        // Activity in the watched folder while off changes nothing either.
        sandbox.append("a.jsonl", usageLine(id: "more", time: ISO8601DateFormatter().string(from: Date()), output: 5) + "\n")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(pathsResolved, 0)
        XCTAssertFalse(cacheExists)
        XCTAssertEqual(monitor.todayTokens, 0)
        XCTAssertTrue(monitor.isCounting)

        // Explicitly off is the same as never set.
        defaults.set(false, forKey: TokenCounterPreference.showKey)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(pathsResolved, 0)
    }

    /// Settings flips it while the app runs: on starts the worker (it counts and saves its
    /// cache); off stops it and the worker is released — its FSEvents stream retained it, so
    /// a released worker means the stream is gone, and the database connection with it — and
    /// nothing is read or written afterwards.
    func testTurningItOnStartsAndTurningItOffReleasesEverything() async throws {
        let monitor = makeMonitor()
        monitor.followPreference()
        XCTAssertFalse(monitor.isRunning)

        defaults.set(true, forKey: TokenCounterPreference.showKey)
        let started = try await waitUntil { monitor.isRunning }
        XCTAssertTrue(started)
        XCTAssertEqual(pathsResolved, 1)
        let counted = try await waitUntil { !monitor.isCounting && monitor.todayTokens == 100 }
        XCTAssertTrue(counted, "today: \(monitor.todayTokens), counting: \(monitor.isCounting)")
        let saved = try await waitUntil { self.cacheExists }
        XCTAssertTrue(saved)

        weak var worker = monitor.worker
        XCTAssertNotNil(worker)
        defaults.set(false, forKey: TokenCounterPreference.showKey)
        let stopped = try await waitUntil { !monitor.isRunning }
        XCTAssertTrue(stopped)
        let released = try await waitUntil { worker == nil }
        XCTAssertTrue(released, "the stopped worker is still alive")
        XCTAssertEqual(monitor.todayTokens, 0)
        XCTAssertTrue(monitor.isCounting)

        // Off again: new tokens in the watched folder are not read and the cache is not touched.
        let written = try FileManager.default.attributesOfItem(atPath: sandbox.paths.cacheFile.path)[.modificationDate] as? Date
        sandbox.append("a.jsonl", usageLine(id: "after-off", time: ISO8601DateFormatter().string(from: Date()), output: 7) + "\n")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let after = try FileManager.default.attributesOfItem(atPath: sandbox.paths.cacheFile.path)[.modificationDate] as? Date
        XCTAssertEqual(written, after)
        XCTAssertEqual(monitor.todayTokens, 0)
        XCTAssertEqual(pathsResolved, 1)

        // And on once more resumes from the cache it left.
        defaults.set(true, forKey: TokenCounterPreference.showKey)
        let resumed = try await waitUntil { !monitor.isCounting && monitor.todayTokens == 107 }
        XCTAssertTrue(resumed, "today: \(monitor.todayTokens)")
        defaults.set(false, forKey: TokenCounterPreference.showKey)
        _ = try await waitUntil { !monitor.isRunning }
    }
}
