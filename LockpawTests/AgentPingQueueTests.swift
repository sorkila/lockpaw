import XCTest
@testable import Lockpaw

final class AgentPingQueueTests: XCTestCase {

    private func ping(session: String, event: String = "Stop", at seconds: TimeInterval = 0) -> AgentPing {
        AgentPing.from(
            userInfo: ["agent": "claude", "session_id": session, "hook_event_name": event],
            now: Date(timeIntervalSince1970: seconds)
        )
    }

    func testStartsEmpty() {
        let queue = AgentPingQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.latest)
    }

    func testDifferentSessionsEachGetARow_oldestFirst() {
        var queue = AgentPingQueue()
        queue.record(ping(session: "a"))
        queue.record(ping(session: "b"))
        XCTAssertEqual(queue.pings.map(\.id), ["a", "b"])
        XCTAssertEqual(queue.latest?.id, "b")
    }

    func testRepeatPingFromTheSameSession_replacesItsRowAndMovesItLast() {
        var queue = AgentPingQueue()
        queue.record(ping(session: "a", event: "Notification", at: 0))
        queue.record(ping(session: "b", at: 1))
        queue.record(ping(session: "a", event: "Stop", at: 2))

        XCTAssertEqual(queue.pings.map(\.id), ["b", "a"])
        XCTAssertEqual(queue.latest?.kind, .finished)
        XCTAssertEqual(queue.latest?.receivedAt, Date(timeIntervalSince1970: 2))
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
    }
}
