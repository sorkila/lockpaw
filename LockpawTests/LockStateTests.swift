import XCTest
@testable import Lockpaw

final class LockStateTests: XCTestCase {

    // MARK: - Valid transitions

    func testUnlockedCanTransitionToLocking() {
        XCTAssertTrue(LockState.unlocked.canTransition(to: .locking))
    }

    func testLockingCanTransitionToLocked() {
        XCTAssertTrue(LockState.locking.canTransition(to: .locked))
    }

    func testLockingCanTransitionToUnlocked() {
        XCTAssertTrue(LockState.locking.canTransition(to: .unlocked),
                      "Locking should be able to fall back to unlocked (e.g. no accessibility)")
    }

    func testLockedCanTransitionToUnlocking() {
        XCTAssertTrue(LockState.locked.canTransition(to: .unlocking))
    }

    func testUnlockingCanTransitionToLocked() {
        XCTAssertTrue(LockState.unlocking.canTransition(to: .locked),
                      "Unlocking should be able to return to locked on auth failure")
    }

    func testUnlockingCanTransitionToUnlocked() {
        XCTAssertTrue(LockState.unlocking.canTransition(to: .unlocked))
    }

    func testLockedCanTransitionToUnlocked() {
        XCTAssertTrue(LockState.locked.canTransition(to: .unlocked),
                      "Force unlock (session lost) should be allowed")
    }

    // MARK: - Invalid transitions

    func testUnlockedCannotTransitionToLocked() {
        XCTAssertFalse(LockState.unlocked.canTransition(to: .locked),
                       "Cannot skip locking phase")
    }

    func testUnlockedCannotTransitionToUnlocking() {
        XCTAssertFalse(LockState.unlocked.canTransition(to: .unlocking))
    }

    func testLockedCannotTransitionToLocking() {
        XCTAssertFalse(LockState.locked.canTransition(to: .locking))
    }

    func testLockingCannotTransitionToUnlocking() {
        XCTAssertFalse(LockState.locking.canTransition(to: .unlocking))
    }

    func testUnlockingCannotTransitionToLocking() {
        XCTAssertFalse(LockState.unlocking.canTransition(to: .locking))
    }

    // MARK: - Self-transitions are invalid

    func testUnlockedCannotTransitionToSelf() {
        XCTAssertFalse(LockState.unlocked.canTransition(to: .unlocked))
    }

    func testLockingCannotTransitionToSelf() {
        XCTAssertFalse(LockState.locking.canTransition(to: .locking))
    }

    func testLockedCannotTransitionToSelf() {
        XCTAssertFalse(LockState.locked.canTransition(to: .locked))
    }

    func testUnlockingCannotTransitionToSelf() {
        XCTAssertFalse(LockState.unlocking.canTransition(to: .unlocking))
    }
}
