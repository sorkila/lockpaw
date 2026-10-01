import AppKit

/// System-level lockdown while the screen is guarded, kept out of the controllers so
/// the rules are unit-tested. Covers the gap the overlay windows alone can't: a Space
/// switch. The overlays join every Space, but while a Space slides in (three-finger
/// swipe, Ctrl+arrow, Mission Control) its contents are drawn uncovered — and holding
/// the swipe mid-gesture keeps them on screen (#18).
enum LockdownPolicy {
    /// Kiosk-style presentation while locked: the Dock — which drives Spaces, Mission
    /// Control and App Exposé — and the menu bar are suppressed, and Cmd+Tab, the force-quit
    /// panel and Hide are disabled. These only apply while Lockpaw is the active app, so
    /// they are a second layer behind the gesture swallowing in the input blocker, not a
    /// replacement for it. AppKit throws on invalid combinations (process switching and a
    /// hidden menu bar both require a hidden Dock; a disabled Apple menu requires a hidden
    /// menu bar); `testPresentationOptionsAreAValidCombination` pins that.
    static let presentationOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableAppleMenu,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableHideApplication,
    ]

    /// Trackpad gesture event types (NSEvent.EventType raw values) swallowed while
    /// locked. Space swipes and Mission Control arrive as `.gesture` (29) streams;
    /// the rest are swallowed too since nothing under the cover should receive a pinch,
    /// rotate or swipe. CGEventType has no cases for these, so they're raw values.
    static let gestureEventTypes: [UInt32] = [
        UInt32(NSEvent.EventType.rotate.rawValue),        // 18
        UInt32(NSEvent.EventType.beginGesture.rawValue),  // 19
        UInt32(NSEvent.EventType.endGesture.rawValue),    // 20
        UInt32(NSEvent.EventType.gesture.rawValue),       // 29
        UInt32(NSEvent.EventType.magnify.rawValue),       // 30
        UInt32(NSEvent.EventType.swipe.rawValue),         // 31
        UInt32(NSEvent.EventType.smartMagnify.rawValue),  // 32
    ]

    static var gestureEventMask: CGEventMask {
        gestureEventTypes.reduce(CGEventMask(0)) { mask, type in mask | (CGEventMask(1) << type) }
    }
}
