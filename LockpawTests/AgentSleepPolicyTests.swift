import XCTest
@testable import Lockpaw

final class AgentSleepPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let delay: TimeInterval = 300

    private func step(
        _ state: AgentSleepPolicy.State = .init(),
        enabled: Bool = true, locked: Bool = true, working: Int, at seconds: TimeInterval
    ) -> (AgentSleepPolicy.State, AgentSleepPolicy.Action) {
        AgentSleepPolicy.step(
            state, enabled: enabled, locked: locked, activeSessions: working,
            now: t0.addingTimeInterval(seconds), delay: delay
        )
    }

    func testSleepsOnceTheLastSessionHasBeenQuietForTheDelay() {
        var (state, action) = step(working: 2, at: 0)
        XCTAssertEqual(action, .none)
        (state, action) = step(state, working: 0, at: 10)
        XCTAssertEqual(action, .none, "the delay starts when the last one goes quiet")
        (state, action) = step(state, working: 0, at: 10 + delay - 1)
        XCTAssertEqual(action, .none)
        (state, action) = step(state, working: 0, at: 10 + delay)
        XCTAssertEqual(action, .sleep)
        XCTAssertTrue(state.released)
    }

    func testSleepsOncePerQuietSpell() {
        var (state, _) = step(working: 1, at: 0)
        (state, _) = step(state, working: 0, at: 0)
        (state, _) = step(state, working: 0, at: delay)
        let (_, again) = step(state, working: 0, at: delay * 3)
        XCTAssertEqual(again, .none, "after a wake the Mac sleeps on its own terms, not Lockpaw's")
    }

    func testWorkInsideTheDelay_restartsIt() {
        var (state, _) = step(working: 1, at: 0)
        (state, _) = step(state, working: 0, at: 0)
        (state, _) = step(state, working: 1, at: delay - 1)
        (state, _) = step(state, working: 0, at: delay)
        let (_, action) = step(state, working: 0, at: delay + delay - 1)
        XCTAssertEqual(action, .none)
    }

    func testWorkAfterSleeping_restoresTheHolds() {
        var (state, _) = step(working: 1, at: 0)
        (state, _) = step(state, working: 0, at: 0)
        (state, _) = step(state, working: 0, at: delay)
        let (next, action) = step(state, working: 1, at: delay * 2)
        XCTAssertEqual(action, .restoreHolds)
        XCTAssertFalse(next.released)
        // ...and the next quiet spell sleeps again.
        let (quiet, _) = step(next, working: 0, at: delay * 3)
        XCTAssertEqual(step(quiet, working: 0, at: delay * 4).1, .sleep)
    }

    func testNoTrackedWorkThisLock_neverSleeps() {
        // A lock with nothing Lockpaw can see (Codex, or no agent at all) keeps the Mac
        // awake exactly as before.
        var (state, _) = step(working: 0, at: 0)
        (state, _) = step(state, working: 0, at: delay * 10)
        XCTAssertEqual(state.released, false)
        XCTAssertEqual(step(state, working: 0, at: delay * 20).1, .none)
    }

    func testOffOrUnlocked_doesNothing() {
        XCTAssertEqual(step(enabled: false, working: 0, at: 0).1, .none)
        let worked = AgentSleepPolicy.State(sawWork: true, idleSince: t0, released: false)
        XCTAssertEqual(step(worked, enabled: false, working: 0, at: delay * 2).1, .none)
        XCTAssertEqual(step(worked, locked: false, working: 0, at: delay * 2).1, .none)
        XCTAssertEqual(step(worked, locked: false, working: 0, at: delay * 2).0, .init(), "the next lock starts fresh")
    }

    func testTurnedOffAfterSleeping_restoresTheHolds() {
        let released = AgentSleepPolicy.State(sawWork: true, idleSince: t0, released: true)
        XCTAssertEqual(step(released, enabled: false, working: 0, at: delay * 2).1, .restoreHolds)
        XCTAssertEqual(step(released, locked: false, working: 0, at: delay * 2).1, .none,
                       "unlocking releases the holds itself")
    }

    func testDelay_fallsBackForAnythingNotOffered() {
        XCTAssertEqual(AgentSleepPolicy.delay(minutes: 15), 900)
        XCTAssertEqual(AgentSleepPolicy.delay(minutes: 7), TimeInterval(AgentSleepPolicy.defaultDelayMinutes * 60))
    }

    func testSomeoneAtTheKeyboard_restartsTheQuietSpell() {
        var (state, _) = step(working: 1, at: 0)
        (state, _) = step(state, working: 0, at: 0)
        state = AgentSleepPolicy.notingPresence(state, now: t0.addingTimeInterval(delay - 1))
        XCTAssertEqual(step(state, working: 0, at: delay).1, .none, "never sleeps under someone typing")
        XCTAssertEqual(step(state, working: 0, at: delay * 2 - 1).1, .sleep)
    }

    func testPresence_changesNothingBeforeTheQuietSpellOrAfterSleeping() {
        let working = AgentSleepPolicy.State(sawWork: true, idleSince: nil, released: false)
        XCTAssertEqual(AgentSleepPolicy.notingPresence(working, now: t0), working)
        let slept = AgentSleepPolicy.State(sawWork: true, idleSince: t0, released: true)
        XCTAssertEqual(AgentSleepPolicy.notingPresence(slept, now: t0.addingTimeInterval(9)), slept)
    }
}
