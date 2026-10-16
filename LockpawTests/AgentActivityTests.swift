import XCTest
@testable import Lockpaw

final class AgentActivityTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Mapping

    func testHookEvents_mapToTurnsToolsAndEnds() {
        XCTAssertEqual(AgentActivity.event(forHook: "UserPromptSubmit"), .turnStarted)
        XCTAssertEqual(AgentActivity.event(forHook: "BeforeAgent"), .turnStarted)
        XCTAssertEqual(AgentActivity.event(forHook: "PreToolUse"), .toolStarted)
        XCTAssertEqual(AgentActivity.event(forHook: "BeforeTool"), .toolStarted)
        XCTAssertEqual(AgentActivity.event(forHook: "PostToolUse"), .toolFinished)
        XCTAssertEqual(AgentActivity.event(forHook: "AfterTool"), .toolFinished)
        XCTAssertEqual(AgentActivity.event(forHook: "SessionEnd"), .ended)
        XCTAssertNil(AgentActivity.event(forHook: "Stop"), "Stop is a ping, not activity")
        XCTAssertNil(AgentActivity.event(forHook: nil))
    }

    func testOnlyARealEndFinishes_waitingHoldsAwake() {
        for kind: AgentPing.Kind in [.finished, .failed, .rateLimited] {
            XCTAssertEqual(AgentActivity.event(for: kind), .finished, "\(kind)")
        }
        XCTAssertEqual(AgentActivity.event(for: .permission), .waiting)
        XCTAssertEqual(AgentActivity.event(for: .needsInput), .waiting)
        XCTAssertNil(AgentActivity.event(for: .attention))
    }

    // MARK: - Wire format

    func testCLI_sendsOnlyAgentEventAndSession() {
        let info = AgentActivity.userInfo(
            arguments: ["activity", "--agent", "claude"],
            stdinPayload: [
                "hook_event_name": "PreToolUse",
                "session_id": "abc",
                "cwd": "/Users/me/secret-project",
                "tool_input": ["command": "make test"],
                "transcript_path": "/Users/me/.claude/x.jsonl",
            ]
        )
        XCTAssertEqual(info, ["agent": "claude", "hook_event_name": "PreToolUse", "session_id": "abc"])
    }

    func testCLI_sendsNothingWithoutATrackedEventOrSession() {
        XCTAssertNil(AgentActivity.userInfo(arguments: [], stdinPayload: [:]),
                     "an unparseable payload (too big, too slow) is no report, never a bare ping")
        XCTAssertNil(AgentActivity.userInfo(arguments: [], stdinPayload: ["hook_event_name": "PostToolUse"]))
        XCTAssertNil(AgentActivity.userInfo(arguments: [], stdinPayload: ["hook_event_name": "Stop", "session_id": "a"]))
    }

    func testReport_roundTripsWithTheDisplayName() {
        let info = AgentActivity.userInfo(
            arguments: ["activity", "--agent", "claude"],
            stdinPayload: ["hook_event_name": "UserPromptSubmit", "session_id": "abc"]
        )
        XCTAssertEqual(
            AgentActivity.report(from: info),
            AgentActivity.Report(agent: "Claude Code", sessionID: "abc", event: .turnStarted)
        )
        XCTAssertNil(AgentActivity.report(from: nil))
    }

    func testReportAndPing_trackTheSameSession() {
        // The ping path names the agent by display name too, so Stop clears the entry
        // the activity report made.
        var activity = AgentActivity()
        activity.record(AgentActivity.report(from: [
            "agent": "claude", "hook_event_name": "UserPromptSubmit", "session_id": "abc",
        ])!, at: t0)
        let stop = AgentPing.from(userInfo: ["agent": "claude", "hook_event_name": "Stop", "session_id": "abc"])
        activity.record(AgentActivity.event(for: stop.kind)!, agent: stop.agent, sessionID: stop.sessionID, at: t0)
        XCTAssertEqual(activity.activeSessions(at: t0), 0)
    }

    // MARK: - Tracking

    func testActiveUntilFinishedOrEnded() {
        var activity = AgentActivity()
        activity.record(.turnStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.turnStarted, agent: "Claude Code", sessionID: "b", at: t0)
        XCTAssertEqual(activity.activeSessions(at: t0), 2)

        activity.record(.finished, agent: "Claude Code", sessionID: "a", at: t0)
        XCTAssertEqual(activity.activeSessions(at: t0), 1)

        activity.record(.ended, agent: "Claude Code", sessionID: "b", at: t0)
        XCTAssertEqual(activity.activeSessions(at: t0), 0)
    }

    func testSameSessionIdUnderAnotherAgent_isAnotherSession() {
        var activity = AgentActivity()
        activity.record(.turnStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.finished, agent: "Gemini CLI", sessionID: "a", at: t0)
        XCTAssertEqual(activity.activeSessions(at: t0), 1)
    }

    func testSessionlessReports_areIgnored() {
        var activity = AgentActivity()
        activity.record(.turnStarted, agent: "Claude Code", sessionID: nil, at: t0)
        XCTAssertEqual(activity.activeSessions(at: t0), 0)
    }

    func testSilenceBetweenTools_goesStale() {
        // Esc sends no Stop and a killed process no SessionEnd; a stale entry must not
        // keep the Mac awake for good.
        var activity = AgentActivity()
        activity.record(.turnStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.toolStarted, agent: "Claude Code", sessionID: "a", at: at(60))
        activity.record(.toolFinished, agent: "Claude Code", sessionID: "a", at: at(120))
        XCTAssertEqual(activity.activeSessions(at: at(120 + AgentActivity.staleAfter - 1)), 1)
        XCTAssertEqual(activity.activeSessions(at: at(120 + AgentActivity.staleAfter)), 0)
    }

    func testALongCommand_holdsForHours() {
        // A build or training run reports nothing until it ends. Sleeping under it loses work.
        var activity = AgentActivity()
        activity.record(.turnStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.toolStarted, agent: "Claude Code", sessionID: "a", at: t0)
        XCTAssertEqual(activity.activeSessions(at: at(6 * 60 * 60)), 1)
        XCTAssertEqual(activity.activeSessions(at: at(AgentActivity.busyStaleAfter)), 0,
                       "a finish that never arrives can't hold the Mac awake for good")
    }

    func testParallelTools_holdUntilTheLastOneFinishes() {
        var activity = AgentActivity()
        activity.record(.toolStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.toolStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.toolFinished, agent: "Claude Code", sessionID: "a", at: t0)
        XCTAssertEqual(activity.activeSessions(at: at(AgentActivity.staleAfter * 2)), 1, "one call still open")
        activity.record(.toolFinished, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.toolFinished, agent: "Claude Code", sessionID: "a", at: t0)  // never below zero
        XCTAssertEqual(activity.activeSessions(at: at(AgentActivity.staleAfter)), 0)
    }

    func testANewTurn_clearsACallWhoseFinishNeverCame() {
        var activity = AgentActivity()
        activity.record(.toolStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.turnStarted, agent: "Claude Code", sessionID: "a", at: t0)
        XCTAssertEqual(activity.activeSessions(at: at(AgentActivity.staleAfter)), 0)
    }

    func testWaitingOnTheUser_holdsForHours_untilWorkResumes() {
        var activity = AgentActivity()
        activity.record(.toolStarted, agent: "Claude Code", sessionID: "a", at: t0)
        activity.record(.waiting, agent: "Claude Code", sessionID: "a", at: t0)
        XCTAssertEqual(activity.activeSessions(at: at(6 * 60 * 60)), 1)

        // Approved: the tool runs and finishes, and the session is an ordinary working one.
        activity.record(.toolFinished, agent: "Claude Code", sessionID: "a", at: at(60))
        activity.record(.toolFinished, agent: "Claude Code", sessionID: "a", at: at(60))
        XCTAssertEqual(activity.activeSessions(at: at(60 + AgentActivity.staleAfter)), 0)
    }
}
