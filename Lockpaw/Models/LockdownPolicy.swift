import AppKit

/// Which trackpad gestures the input blocker swallows while locked, kept out of the
/// controller so the rules are unit-tested. Covers the gap the overlay windows alone can't:
/// a Space switch. The overlays join every Space, but while a Space slides in (three-finger
/// swipe, Mission Control) its contents are drawn uncovered — and holding the swipe
/// mid-gesture keeps them on screen (#18).
///
/// An earlier revision also applied kiosk presentation options (hidden Dock and menu bar,
/// no process switching or force quit). They were dropped: they only apply while Lockpaw is
/// the active app, and the LocalAuthentication agent holds activation for as long as Touch ID
/// is armed — most of a lock on a Touch ID Mac — so all they reliably added was screen-
/// parameter churn. Swallowing the gesture stream at the tap is the defence that holds.
enum LockdownPolicy {
    /// The Dock's private control stream, `kCGSEventDockControl`. Space swipes and Mission
    /// Control reach the Dock as this type; it shares its raw value with `NSEvent.EventType
    /// .magnify`, which is why a mask that only listed "magnify" happened to cover it. Named
    /// separately so dropping pinch from the list can never reopen #18.
    static let dockControlEventType: UInt32 = 30

    /// Trackpad gesture event types (NSEvent.EventType raw values) swallowed while locked.
    /// CGEventType has no cases for these, so they're raw values.
    static let gestureEventTypes: [UInt32] = [
        UInt32(NSEvent.EventType.rotate.rawValue),        // 18
        UInt32(NSEvent.EventType.beginGesture.rawValue),  // 19
        UInt32(NSEvent.EventType.endGesture.rawValue),    // 20
        UInt32(NSEvent.EventType.gesture.rawValue),       // 29
        dockControlEventType,                             // 30 (also .magnify)
        UInt32(NSEvent.EventType.swipe.rawValue),         // 31
        UInt32(NSEvent.EventType.smartMagnify.rawValue),  // 32
    ]

    static var gestureEventMask: CGEventMask {
        gestureEventTypes.reduce(CGEventMask(0)) { mask, type in mask | (CGEventMask(1) << type) }
    }

    /// While the system auth dialog is up the keyboard must reach it, but a gesture still
    /// must not switch Spaces — the dialog can sit open indefinitely. One tap serves both
    /// modes so switching between them never leaves a window with no tap installed.
    static func swallows(eventType: UInt32, gesturesOnly: Bool) -> Bool {
        gesturesOnly ? gestureEventTypes.contains(eventType) : true
    }
}
