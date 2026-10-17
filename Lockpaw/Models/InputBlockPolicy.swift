import Foundation

/// Pure rules that keep the lock hotkey from stranding the keyboard, free of event taps and
/// timers so both can be unit-tested directly.
enum InputBlockPolicy {
    /// Holding the hotkey auto-repeats its keyDown. Each repeat used to toggle, so a held key
    /// flipped lock → unlock → lock, fast enough to land an unlock inside the window below.
    /// Only the first press toggles; repeats are swallowed.
    static func hotkeyShouldToggle(isAutorepeat: Bool) -> Bool {
        !isAutorepeat
    }

    /// `lock()` starts the keyboard blocker a beat after the overlay appears. If an unlock
    /// lands inside that beat, starting it anyway leaves the keyboard blocked with no cover
    /// up; the hotkey is then the only way out. So the deferred start only goes ahead while
    /// the screen is still locked.
    static func shouldStartDeferredBlocking(state: LockState) -> Bool {
        state == .locked
    }
}
