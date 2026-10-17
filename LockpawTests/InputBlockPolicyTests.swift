import XCTest
@testable import Lockpaw

final class InputBlockPolicyTests: XCTestCase {

    func testFirstPressTogglesButAutoRepeatDoesNot() {
        XCTAssertTrue(InputBlockPolicy.hotkeyShouldToggle(isAutorepeat: false))
        XCTAssertFalse(InputBlockPolicy.hotkeyShouldToggle(isAutorepeat: true))
    }

    func testDeferredBlockerStartsOnlyWhileLocked() {
        XCTAssertTrue(InputBlockPolicy.shouldStartDeferredBlocking(state: .locked))
        for state in [LockState.unlocked, .locking, .unlocking] {
            XCTAssertFalse(InputBlockPolicy.shouldStartDeferredBlocking(state: state), "\(state)")
        }
    }
}
