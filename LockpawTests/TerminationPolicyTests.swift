import XCTest
@testable import Lockpaw

final class TerminationPolicyTests: XCTestCase {
    func testQuitAllowedOnlyWhenUnlocked() {
        XCTAssertTrue(TerminationPolicy.allowsQuit(state: .unlocked))
    }

    func testQuitRefusedWhileGuarded() {
        // The reported bypass: Cmd+Q reaching the app while the password sheet is up.
        XCTAssertFalse(TerminationPolicy.allowsQuit(state: .locked))
        XCTAssertFalse(TerminationPolicy.allowsQuit(state: .locking))
        XCTAssertFalse(TerminationPolicy.allowsQuit(state: .unlocking))
    }

    @MainActor
    func testLockStatusMirrorsUpdates() {
        LockStatus.shared.update(.locked)
        XCTAssertEqual(LockStatus.shared.state, .locked)
        LockStatus.shared.update(.unlocked)
        XCTAssertEqual(LockStatus.shared.state, .unlocked)
    }
}
