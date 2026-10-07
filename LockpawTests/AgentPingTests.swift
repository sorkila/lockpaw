import XCTest
@testable import Lockpaw

final class AgentPingTests: XCTestCase {

    // MARK: - Locked: pulse + notify

    func testLockedWithSoundOff_pulsesAndNotifiesSilently() {
        let d = PingDecision.make(state: .locked, soundEnabled: false)
        XCTAssertTrue(d.shouldPulse)
        XCTAssertTrue(d.shouldNotify)
        XCTAssertFalse(d.withSound)
    }

    func testLockedWithSoundOn_pulsesAndNotifiesWithSound() {
        let d = PingDecision.make(state: .locked, soundEnabled: true)
        XCTAssertTrue(d.shouldPulse)
        XCTAssertTrue(d.shouldNotify)
        XCTAssertTrue(d.withSound)
    }

    // MARK: - Not locked: no-op (user is present, or mid-transition)

    func testUnlocked_isNoOp() {
        let d = PingDecision.make(state: .unlocked, soundEnabled: true)
        XCTAssertEqual(d, .none)
        XCTAssertFalse(d.shouldPulse)
        XCTAssertFalse(d.shouldNotify)
        XCTAssertFalse(d.withSound)
    }

    func testLocking_isNoOp() {
        XCTAssertEqual(PingDecision.make(state: .locking, soundEnabled: true), .none)
    }

    func testUnlocking_isNoOp() {
        // Auth in progress means the user is right there — don't pulse or notify.
        XCTAssertEqual(PingDecision.make(state: .unlocking, soundEnabled: true), .none)
    }

    // MARK: - Sound only ever attaches when actually notifying

    func testSoundNeverSetWhenNotNotifying() {
        for state in [LockState.unlocked, .locking, .unlocking] {
            let d = PingDecision.make(state: state, soundEnabled: true)
            XCTAssertFalse(d.withSound, "withSound must be false when not notifying (state: \(state))")
        }
    }
}

final class PingGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func ping(_ kind: AgentPing.Kind, agent: String? = "Claude Code", session: String? = "s1") -> AgentPing {
        AgentPing(agent: agent, project: nil, kind: kind, sessionID: session, receivedAt: now)
    }

    /// Claude's idle_prompt repeats a turn's end a minute after Stop.
    func testSameSessionSameKindIsAnnouncedOnce() {
        var gate = PingGate()
        XCTAssertTrue(gate.admits(ping(.finished), now: now))
        XCTAssertFalse(gate.admits(ping(.finished), now: now.addingTimeInterval(60)))
    }

    func testAChangeOfKindAlwaysGoesThrough() {
        var gate = PingGate()
        XCTAssertTrue(gate.admits(ping(.finished), now: now))
        XCTAssertTrue(gate.admits(ping(.permission), now: now.addingTimeInterval(1)))
    }

    /// The old global debounce dropped this: Codex finishes, Claude is blocked a second later.
    func testDifferentAgentsInsideTwoSecondsBothGetThrough() {
        var gate = PingGate()
        XCTAssertTrue(gate.admits(ping(.finished, agent: "Codex", session: "t1"), now: now))
        XCTAssertTrue(gate.admits(ping(.permission, agent: "Claude Code", session: "s9"), now: now.addingTimeInterval(1)))
    }

    func testBarePingsFallBackToTheShortDebounce() {
        var gate = PingGate()
        XCTAssertTrue(gate.admits(ping(.attention, agent: nil, session: nil), now: now))
        XCTAssertFalse(gate.admits(ping(.attention, agent: nil, session: nil), now: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.admits(ping(.attention, agent: nil, session: nil), now: now.addingTimeInterval(3)))
        XCTAssertTrue(gate.admits(ping(.attention, agent: "my-bot", session: nil), now: now.addingTimeInterval(3.5)))
    }

    func testResetStartsANewLockSession() {
        var gate = PingGate()
        XCTAssertTrue(gate.admits(ping(.finished), now: now))
        gate.reset()
        XCTAssertTrue(gate.admits(ping(.finished), now: now))
    }
}

final class SeasonalTodayTests: XCTestCase {
    @MainActor func testTodayMatchesCurrent() {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        XCTAssertEqual(SeasonalSkin.today(now: date), SeasonalSkin.current(on: date))
    }
}
