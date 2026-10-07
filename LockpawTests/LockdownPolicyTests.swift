import XCTest
@testable import Lockpaw

final class LockdownPolicyTests: XCTestCase {

    /// Space swipes arrive as `.gesture` events — the one type that must never be dropped
    /// from the mask (#18).
    func testGestureMaskCoversSpaceSwipes() {
        let gesture = CGEventMask(1) << UInt32(NSEvent.EventType.gesture.rawValue)
        XCTAssertNotEqual(LockdownPolicy.gestureEventMask & gesture, 0)
    }

    /// The Dock's private control stream (`kCGSEventDockControl`, 30) is what drives Space
    /// switching. It shares a raw value with `.magnify`, so pin it by name: removing pinch
    /// from the list must not quietly reopen #18.
    func testGestureMaskCoversDockControlStream() {
        XCTAssertEqual(LockdownPolicy.dockControlEventType, 30)
        let dock = CGEventMask(1) << LockdownPolicy.dockControlEventType
        XCTAssertNotEqual(LockdownPolicy.gestureEventMask & dock, 0)
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

    /// Locked: everything the tap sees is swallowed.
    func testLockedSwallowsKeysAndGestures() {
        let types: [UInt32] = [
            CGEventType.keyDown.rawValue, CGEventType.flagsChanged.rawValue,
            CGEventType.scrollWheel.rawValue, UInt32(NSEvent.EventType.gesture.rawValue),
        ]
        for type in types {
            XCTAssertTrue(LockdownPolicy.swallows(eventType: type, gesturesOnly: false), "type \(type)")
        }
    }

    /// Auth dialog up: keys reach it, but gestures still can't switch Spaces.
    func testAuthDialogLetsKeysThroughButKeepsGesturesBlocked() {
        XCTAssertFalse(LockdownPolicy.swallows(eventType: CGEventType.keyDown.rawValue, gesturesOnly: true))
        XCTAssertFalse(LockdownPolicy.swallows(eventType: CGEventType.keyUp.rawValue, gesturesOnly: true))
        XCTAssertFalse(LockdownPolicy.swallows(eventType: CGEventType.scrollWheel.rawValue, gesturesOnly: true))
        for type in LockdownPolicy.gestureEventTypes {
            XCTAssertTrue(LockdownPolicy.swallows(eventType: type, gesturesOnly: true), "gesture \(type)")
        }
    }
}
