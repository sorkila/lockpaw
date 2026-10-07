import XCTest
@testable import Lockpaw

final class AgentPingPayloadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000)

    private func ping(_ userInfo: [String: String]?) -> AgentPing {
        AgentPing.from(userInfo: userInfo, now: now)
    }

    // MARK: - Decoding

    func testBarePing_keepsTheOriginalWording() {
        let bare = ping(nil)
        XCTAssertEqual(bare.kind, .attention)
        XCTAssertNil(bare.agent)
        XCTAssertNil(bare.project)
        XCTAssertEqual(bare.summary(), "Your agent needs you")
        XCTAssertEqual(bare.receivedAt, now)
    }

    func testClaudeStop_isFinishedInTheProject() {
        let stop = ping([
            "agent": "claude",
            "hook_event_name": "Stop",
            "cwd": "/Users/me/Desktop/croq-app",
            "session_id": "abc",
        ])
        XCTAssertEqual(stop.kind, .finished)
        XCTAssertEqual(stop.agent, "Claude Code")
        XCTAssertEqual(stop.project, "croq-app")
        XCTAssertEqual(stop.sessionID, "abc")
        XCTAssertEqual(stop.summary(), "Claude Code finished in croq-app")
    }

    func testEmptyFields_areTreatedAsAbsent() {
        let empty = ping(["agent": "", "cwd": "", "session_id": ""])
        XCTAssertNil(empty.agent)
        XCTAssertNil(empty.project)
        XCTAssertNil(empty.sessionID)
    }

    func testSummaryWithoutProject() {
        XCTAssertEqual(ping(["agent": "codex"]).summary(), "Codex needs you")
    }

    // MARK: - Kind

    func testStop_isFinished() {
        XCTAssertEqual(AgentPing.kind(hookEvent: "Stop", notificationType: nil, error: nil), .finished)
    }

    func testGeminiAfterAgent_isFinished() {
        XCTAssertEqual(AgentPing.kind(hookEvent: "AfterAgent", notificationType: nil, error: nil), .finished)
    }

    func testStopFailureOnARateLimit() {
        XCTAssertEqual(AgentPing.kind(hookEvent: "StopFailure", notificationType: nil, error: "rate_limit"), .rateLimited)
    }

    func testStopFailureOnAnyOtherError_isFailed() {
        for error in ["overloaded", "billing_error", "max_output_tokens", "unknown", nil] {
            XCTAssertEqual(AgentPing.kind(hookEvent: "StopFailure", notificationType: nil, error: error), .failed)
        }
    }

    func testStopFailureSummary() {
        let failure = ping([
            "agent": "claude", "hook_event_name": "StopFailure", "error": "rate_limit", "cwd": "/w/croq-app",
        ])
        XCTAssertEqual(failure.summary(), "Claude Code hit a rate limit in croq-app")
    }

    func testNotificationTypes() {
        let expected: [String: AgentPing.Kind] = [
            "permission_prompt": .permission,
            "agent_needs_input": .needsInput,
            "elicitation_dialog": .needsInput,
            "quota_auto_resume_stale": .needsInput,
            "agent_completed": .finished,
            "idle_prompt": .finished,
            "ToolPermission": .permission,
        ]
        for (type, kind) in expected {
            XCTAssertEqual(
                AgentPing.kind(hookEvent: "Notification", notificationType: type, error: nil), kind, type
            )
        }
    }

    func testNotificationWithoutAType_isPlainAttention() {
        XCTAssertEqual(AgentPing.kind(hookEvent: "Notification", notificationType: nil, error: nil), .attention)
    }

    func testUnknownEvent_isPlainAttention() {
        XCTAssertEqual(AgentPing.kind(hookEvent: "SomethingNew", notificationType: nil, error: nil), .attention)
    }

    // MARK: - Names

    func testKnownAgentsGetTheirDisplayName() {
        XCTAssertEqual(AgentPing.displayName(forAgent: "claude"), "Claude Code")
        XCTAssertEqual(AgentPing.displayName(forAgent: "Gemini"), "Gemini CLI")
    }

    func testUnknownAgentKeepsItsOwnName() {
        XCTAssertEqual(AgentPing.displayName(forAgent: "my-bot"), "my-bot")
    }

    func testProjectName() {
        XCTAssertEqual(AgentPing.projectName(fromWorkingDirectory: "/Users/me/Desktop/Pupitre"), "Pupitre")
        XCTAssertEqual(AgentPing.projectName(fromWorkingDirectory: "/Users/me/Desktop/Pupitre/"), "Pupitre")
        XCTAssertNil(AgentPing.projectName(fromWorkingDirectory: "/"))
    }

    func testCodexPermissionRequestHook_isPermission() {
        XCTAssertEqual(AgentPing.kind(hookEvent: "PermissionRequest", notificationType: nil, error: nil), .permission)
    }

    func testExplicitFlagBeatsThePayload() {
        XCTAssertEqual(AgentPing.kind(flag: .done, hookEvent: "Notification", notificationType: "permission_prompt", error: nil), .finished)
        XCTAssertEqual(AgentPing.kind(flag: .waiting, hookEvent: nil, notificationType: nil, error: nil), .needsInput)
        XCTAssertEqual(AgentPing.kind(flag: .error, hookEvent: nil, notificationType: nil, error: nil), .failed)
    }

    func testSummaryCanLeaveTheProjectOut() {
        let stop = ping(["agent": "claude", "hook_event_name": "Stop", "project": "client-x"])
        XCTAssertEqual(stop.summary(), "Claude Code finished in client-x")
        XCTAssertEqual(stop.summary(includingProject: false), "Claude Code finished")
    }

    func testLegacyCwdStillDecodesToTheBasename() {
        XCTAssertEqual(ping(["cwd": "/Users/me/w/croq-app"]).project, "croq-app")
    }

    // MARK: - CLI side

    func testUserInfo_forwardsOnlyTheKnownStringFieldsAndTheBasename() {
        let info = AgentPing.userInfo(arguments: ["ping", "--agent", "claude"], stdinPayload: [
            "hook_event_name": "StopFailure",
            "error": "rate_limit",
            "error_details": "429 Too Many Requests",
            "cwd": "/Users/me/w/croq-app",
            "session_id": "abc",
            "last_assistant_message": "a long private message",
            "transcript_path": "/somewhere.jsonl",
            "stop_hook_active": false,
        ])
        XCTAssertEqual(info, [
            "agent": "claude",
            "hook_event_name": "StopFailure",
            "error": "rate_limit",
            "project": "croq-app",
            "session_id": "abc",
        ])
    }

    func testUserInfo_isEmptyForABarePing() {
        XCTAssertTrue(AgentPing.userInfo(arguments: ["ping"], stdinPayload: [:]).isEmpty)
    }

    func testUserInfoRoundTripsThroughDecoding() {
        let info = AgentPing.userInfo(arguments: ["ping", "--agent", "claude"], stdinPayload: [
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "cwd": "/w/Pupitre",
        ])
        XCTAssertEqual(ping(info).summary(), "Claude Code needs permission in Pupitre")
    }

    /// Codex `notify` passes its payload as the last argument, with stdin at /dev/null.
    func testCodexNotifyArgvPayload() {
        let payload = #"{"type":"agent-turn-complete","thread-id":"t-1","turn-id":"9","cwd":"/Users/me/w/billing","input-messages":["secret"],"last-assistant-message":"secret"}"#
        let info = AgentPing.userInfo(arguments: ["ping", "--agent", "codex", payload], stdinPayload: [:])
        XCTAssertEqual(info, ["agent": "codex", "kind": "done", "project": "billing", "session_id": "t-1"])
        XCTAssertEqual(ping(info).summary(), "Codex finished in billing")
    }

    func testArgvThatIsNotACodexPayloadIsIgnored() {
        XCTAssertEqual(AgentPing.userInfo(arguments: ["ping", "{not json"], stdinPayload: [:]), [:])
        XCTAssertEqual(AgentPing.userInfo(arguments: ["ping", #"{"no":"type"}"#], stdinPayload: [:]), [:])
    }

    func testKindFlagsReachTheWire() {
        XCTAssertEqual(AgentPing.userInfo(arguments: ["ping", "--agent", "cursor", "--done"], stdinPayload: [:]),
                       ["agent": "cursor", "kind": "done"])
        XCTAssertEqual(AgentPing.userInfo(arguments: ["ping", "--waiting"], stdinPayload: [:])["kind"], "waiting")
        XCTAssertEqual(AgentPing.userInfo(arguments: ["ping", "--error"], stdinPayload: [:])["kind"], "error")
    }
}
