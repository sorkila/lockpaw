import XCTest
@testable import Lockpaw

final class WebhookRelayTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func ping(_ kind: AgentPing.Kind, session: String? = "s1", project: String? = "client-x") -> AgentPing {
        AgentPing(agent: "Claude Code", project: project, kind: kind, sessionID: session, receivedAt: now)
    }

    private func json(_ request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }

    // MARK: - What leaves the Mac

    func testWebhookSendsAgentKindAndMessage_noProjectByDefault() throws {
        let config = WebhookRelay.Config(provider: .webhook, webhookURL: "https://example.com/hook")
        let body = try json(WebhookRelay.request(for: ping(.permission), config: config, now: now))
        XCTAssertEqual(body["source"], "lockpaw")
        XCTAssertEqual(body["agent"], "Claude Code")
        XCTAssertEqual(body["kind"], "waiting")
        XCTAssertEqual(body["message"], "Claude Code needs permission")
        XCTAssertNil(body["project"])
        XCTAssertNil(body["session_id"])
        XCTAssertEqual(Set(body.keys), ["source", "agent", "kind", "message", "timestamp"])
    }

    func testProjectOnlyWhenOptedIn() throws {
        var config = WebhookRelay.Config(provider: .webhook, webhookURL: "https://example.com/hook")
        config.includeProject = true
        let body = try json(WebhookRelay.request(for: ping(.finished), config: config, now: now))
        XCTAssertEqual(body["project"], "client-x")
        XCTAssertEqual(body["message"], "Claude Code finished in client-x")
    }

    func testNtfyPostsToTheTopicWithKindTag() throws {
        let config = WebhookRelay.Config(provider: .ntfy, ntfyTopic: "lockpaw-abc")
        let request = try WebhookRelay.request(for: ping(.failed), config: config)
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh/lockpaw-abc")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Tags"), "error")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Priority"), "high")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "Claude Code stopped on an error")
    }

    func testNtfyRejectsATopicThatCouldEscapeThePath() {
        for topic in ["", "a/../b", "a b", "x?y=1"] {
            let config = WebhookRelay.Config(provider: .ntfy, ntfyTopic: topic)
            XCTAssertThrowsError(try WebhookRelay.request(for: ping(.finished), config: config), topic)
        }
    }

    func testPushoverFormEncodesEveryField() throws {
        var config = WebhookRelay.Config(provider: .pushover, pushoverUser: "u&x", pushoverToken: "t=1")
        config.includeProject = true
        let p = AgentPing(agent: "Codex", project: "a+b&c", kind: .finished, sessionID: nil, receivedAt: now)
        let request = try WebhookRelay.request(for: p, config: config)
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertEqual(body, "token=t%3D1&user=u%26x&title=Lockpaw&message=Codex%20finished%20in%20a%2Bb%26c&priority=0")
    }

    func testMissingConfigurationThrows() {
        XCTAssertThrowsError(try WebhookRelay.request(for: ping(.finished), config: .init(provider: .off)))
        XCTAssertThrowsError(try WebhookRelay.request(for: ping(.finished), config: .init(provider: .pushover)))
        XCTAssertThrowsError(try WebhookRelay.request(for: ping(.finished), config: .init(provider: .webhook, webhookURL: "notaurl")))
        XCTAssertThrowsError(try WebhookRelay.request(for: ping(.finished), config: .init(provider: .webhook, webhookURL: "file:///etc/passwd")))
    }

    func testKindWords() {
        XCTAssertEqual(WebhookRelay.word(for: .finished), "done")
        XCTAssertEqual(WebhookRelay.word(for: .needsInput), "waiting")
        XCTAssertEqual(WebhookRelay.word(for: .rateLimited), "error")
        XCTAssertEqual(WebhookRelay.word(for: .attention), "attention")
    }

    func testRandomTopicIsLongAndPathSafe() {
        let topic = WebhookRelay.randomTopic()
        XCTAssertTrue(topic.hasPrefix("lockpaw-"))
        XCTAssertEqual(topic.count, 28)
        XCTAssertNotEqual(topic, WebhookRelay.randomTopic())
    }

    // MARK: - Throttle

    func testThrottleLetsOnePerSessionPerWindow() {
        var throttle = RelayThrottle()
        XCTAssertTrue(throttle.allows(ping(.finished), now: now))
        XCTAssertFalse(throttle.allows(ping(.finished), now: now.addingTimeInterval(10)))
        XCTAssertTrue(throttle.allows(ping(.finished), now: now.addingTimeInterval(31)))
    }

    func testThrottleAlwaysPassesAChangeOfKind() {
        var throttle = RelayThrottle()
        XCTAssertTrue(throttle.allows(ping(.finished), now: now))
        XCTAssertTrue(throttle.allows(ping(.permission), now: now.addingTimeInterval(1)))
    }

    func testThrottleIsPerSession() {
        var throttle = RelayThrottle()
        XCTAssertTrue(throttle.allows(ping(.finished, session: "a"), now: now))
        XCTAssertTrue(throttle.allows(ping(.finished, session: "b"), now: now))
    }
}
