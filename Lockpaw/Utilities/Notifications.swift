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
}
