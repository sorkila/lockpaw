import XCTest
@testable import Lockpaw

final class AgentPingQueueTests: XCTestCase {

    private func ping(session: String, event: String = "Stop", at seconds: TimeInterval = 0) -> AgentPing {
        AgentPing.from(
            userInfo: ["agent": "claude", "session_id": session, "hook_event_name": event],
            now: Date(timeIntervalSince1970: seconds)
        )
    }

    private func ping(_ kind: AgentPing.Kind, session: String, at seconds: TimeInterval = 0) -> AgentPing {
        AgentPing(agent: "Claude Code", project: nil, kind: kind, sessionID: session, receivedAt: Date(timeIntervalSince1970: seconds))
    }

    func testStartsEmpty() {
        let queue = AgentPingQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.latest)
        XCTAssertNil(queue.glowPing)
        XCTAssertEqual(queue.glowTone, .teal)
        XCTAssertTrue(queue.tally.isEmpty)
    }

    func testDifferentSessionsEachGetARow_oldestFirst() {
        var queue = AgentPingQueue()
        queue.record(ping(session: "a"))
        queue.record(ping(session: "b"))
        XCTAssertEqual(queue.pings.map(\.sessionID), ["a", "b"])
        XCTAssertEqual(queue.latest?.sessionID, "b")
    }

    func testRepeatPingFromTheSameSession_replacesItsRowAndMovesItLast() {
        var queue = AgentPingQueue()
        queue.record(ping(session: "a", event: "Notification", at: 0))
        queue.record(ping(session: "b", at: 1))
        queue.record(ping(session: "a", event: "Stop", at: 2))

        XCTAssertEqual(queue.pings.map(\.sessionID), ["b", "a"])
        XCTAssertEqual(queue.latest?.kind, .finished)
        XCTAssertEqual(queue.latest?.receivedAt, Date(timeIntervalSince1970: 2))
    }

    /// Claude's idle_prompt restates a Stop a minute later; the wait time must keep counting.
    func testRepeatInTheSameState_keepsTheOriginalWaitTime() {
        var queue = AgentPingQueue()
        queue.record(ping(.finished, session: "a", at: 0))
        queue.record(ping(.permission, session: "b", at: 10))
        queue.record(ping(.finished, session: "a", at: 60))

        XCTAssertEqual(queue.pings.map(\.sessionID), ["a", "b"])
        XCTAssertEqual(queue.pings.first?.receivedAt, Date(timeIntervalSince1970: 0))
    }

    func testBarePings_collapseIntoOneRow() {
        var queue = AgentPingQueue()
        queue.record(AgentPing.from(userInfo: nil))
        queue.record(AgentPing.from(userInfo: nil))
        XCTAssertEqual(queue.pings.count, 1)
    }

    func testClear() {
        var queue = AgentPingQueue()
        queue.record(ping(session: "a"))
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.glowTone, .teal)
    }

    // MARK: - Glow precedence

    /// The review's case: an amber "needs permission" must not be repainted teal when a
    /// different session finishes later.
    func testWaitingOutranksALaterFinish() {
        var queue = AgentPingQueue()
        queue.record(ping(.permission, session: "a", at: 0))
        queue.record(ping(.finished, session: "b", at: 5))

        XCTAssertEqual(queue.glowPing?.sessionID, "a")
        XCTAssertEqual(queue.glowTone, .amber)
    }

    func testErrorOutranksALaterFinish() {
        var queue = AgentPingQueue()
        queue.record(ping(.rateLimited, session: "a", at: 0))
        queue.record(ping(.finished, session: "b", at: 5))
        queue.record(ping(.attention, session: "c", at: 6))

        XCTAssertEqual(queue.glowPing?.sessionID, "a")
        XCTAssertEqual(queue.glowTone, .amber)
    }

    func testTheLatestBreaksTiesBetweenUrgentPings() {
        var queue = AgentPingQueue()
        queue.record(ping(.permission, session: "a", at: 0))
        queue.record(ping(.failed, session: "b", at: 5))
        XCTAssertEqual(queue.glowPing?.sessionID, "b")

        queue.record(ping(.needsInput, session: "c", at: 9))
        XCTAssertEqual(queue.glowPing?.sessionID, "c")
    }

    func testTheLatestBreaksTiesBetweenCalmPings() {
        var queue = AgentPingQueue()
        queue.record(ping(.finished, session: "a", at: 0))
        queue.record(ping(.attention, session: "b", at: 5))
        XCTAssertEqual(queue.glowPing?.sessionID, "b")
        XCTAssertEqual(queue.glowTone, .teal)
    }

    /// Outstanding means outstanding: once the waiting session finishes, nothing urgent is left.
    func testTheGlowCalmsWhenTheUrgentSessionMovesOn() {
        var queue = AgentPingQueue()
        queue.record(ping(.permission, session: "a", at: 0))
        queue.record(ping(.finished, session: "b", at: 5))
        queue.record(ping(.finished, session: "a", at: 9))

        XCTAssertEqual(queue.glowTone, .teal)
        XCTAssertEqual(queue.glowPing?.sessionID, "a")
    }

    /// Red is reserved for auth failure; an agent error glows amber and carries a red marker.
    func testEveryKindMapsToItsStatusAndTone() {
        let expected: [(AgentPing.Kind, AgentPingStatus, AgentGlowTone)] = [
            (.finished, .done, .teal),
            (.attention, .attention, .teal),
            (.permission, .waiting, .amber),
            (.needsInput, .waiting, .amber),
            (.rateLimited, .error, .amber),
            (.failed, .error, .amber),
        ]
        for (kind, status, tone) in expected {
            XCTAssertEqual(kind.status, status, "\(kind)")
            XCTAssertEqual(kind.status.glowTone, tone, "\(kind)")
        }
    }

    // MARK: - Rows and tally

    func testRowsPutUrgentFirst_newestFirstWithin() {
        var queue = AgentPingQueue()
        queue.record(ping(.permission, session: "a", at: 0))
        queue.record(ping(.finished, session: "b", at: 1))
        queue.record(ping(.failed, session: "c", at: 2))
        queue.record(ping(.finished, session: "d", at: 3))

        XCTAssertEqual(queue.rows.map(\.sessionID), ["c", "a", "d", "b"])
    }

    func testTallyCountsSessionsPerStateInAFixedOrder() {
        var queue = AgentPingQueue()
        queue.record(ping(.finished, session: "a"))
        queue.record(ping(.finished, session: "b"))
        queue.record(ping(.permission, session: "c"))
        queue.record(ping(.rateLimited, session: "d"))

        XCTAssertEqual(queue.tally.map { $0.status }, [.waiting, .error, .done])
        XCTAssertEqual(queue.tally.map { $0.count }, [1, 1, 2])
        XCTAssertEqual(queue.tally.map(\.label), ["1 waiting", "1 error", "2 done"])
    }

    func testTallyLabels() {
        XCTAssertEqual(AgentPingStatus.done.tallyLabel(count: 3), "3 done")
        XCTAssertEqual(AgentPingStatus.waiting.tallyLabel(count: 2), "2 waiting")
        XCTAssertEqual(AgentPingStatus.error.tallyLabel(count: 1), "1 error")
        XCTAssertEqual(AgentPingStatus.error.tallyLabel(count: 2), "2 errors")
        XCTAssertEqual(AgentPingStatus.attention.tallyLabel(count: 1), "1 needs you")
        XCTAssertEqual(AgentPingStatus.attention.tallyLabel(count: 2), "2 need you")
    }
}
