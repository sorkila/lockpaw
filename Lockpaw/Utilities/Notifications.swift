import Foundation

/// All notification names in one place.
extension Notification.Name {
    static let lockpawLock = Notification.Name("lockpawLock")
    static let lockpawUnlock = Notification.Name("lockpawUnlock")
    static let lockpawUnlockPassword = Notification.Name("lockpawUnlockPassword")
    static let lockpawInputBlockerFailed = Notification.Name("lockpawInputBlockerFailed")
    static let lockpawSessionLost = Notification.Name("lockpawSessionLost")
    static let toggleLockpaw = Notification.Name("toggleLockpaw")
    static let lockpawHotkeyPreferenceChanged = Notification.Name("lockpawHotkeyPreferenceChanged")
    /// Posted when an AI agent pings (bridged from the distributed notification, or fired by the in-app test button).
    static let lockpawPing = Notification.Name("lockpawPing")
    /// Posted (throttled) by InputBlocker when a physical keyboard/scroll event hits its
    /// tap while locked — the tap swallows those events before NSEvent monitors can see
    /// them, so fade-to-black needs this side channel to reveal the lock UI.
    static let lockpawPhysicalInput = Notification.Name("lockpawPhysicalInput")
}
