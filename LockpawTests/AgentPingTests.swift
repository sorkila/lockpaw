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
