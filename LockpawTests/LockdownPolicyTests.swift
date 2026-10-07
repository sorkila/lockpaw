import XCTest
@testable import Lockpaw

final class LockdownPolicyTests: XCTestCase {

    /// AppKit raises if presentation options are combined illegally; a bad set would
    /// crash at lock time, so pin the dependencies here.
    func testPresentationOptionsAreAValidCombination() {
        let options = LockdownPolicy.presentationOptions
        if options.contains(.disableProcessSwitching) || options.contains(.hideMenuBar) {
            XCTAssertTrue(options.contains(.hideDock) || options.contains(.autoHideDock))
        }
        if options.contains(.disableAppleMenu) {
            XCTAssertTrue(options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar))
        }
        XCTAssertFalse(options.contains(.hideDock) && options.contains(.autoHideDock))
        XCTAssertFalse(options.contains(.hideMenuBar) && options.contains(.autoHideMenuBar))
    }

    /// The Dock owns Spaces and Mission Control; hiding it is what takes them away.
    func testLockdownSuppressesDockAndProcessSwitching() {
        XCTAssertTrue(LockdownPolicy.presentationOptions.contains(.hideDock))
        XCTAssertTrue(LockdownPolicy.presentationOptions.contains(.disableProcessSwitching))
    }

    /// Space swipes arrive as `.gesture` events — the one type that must never be dropped
    /// from the mask (#18).
    func testGestureMaskCoversSpaceSwipes() {
        let gesture = CGEventMask(1) << UInt32(NSEvent.EventType.gesture.rawValue)
        XCTAssertNotEqual(LockdownPolicy.gestureEventMask & gesture, 0)
    }

    /// Every type fits a 64-bit CGEventMask and none collide with the pointer events the
    /// overlay must keep receiving — the fallback-auth button needs mouse down/up.
    func testGestureMaskLeavesPointerEventsAlone() {
        for type in LockdownPolicy.gestureEventTypes { XCTAssertLessThan(type, 64) }
        let pointer: [CGEventType] = [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged]
        for type in pointer {
            XCTAssertEqual(LockdownPolicy.gestureEventMask & (CGEventMask(1) << type.rawValue), 0)
        }
    }
}
