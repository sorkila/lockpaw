import Foundation

/// All notification names in one place.
extension Notification.Name {
    static let bevakLock = Notification.Name("bevakLock")
    static let bevakUnlock = Notification.Name("bevakUnlock")
    static let bevakUnlockPassword = Notification.Name("bevakUnlockPassword")
    static let bevakInputBlockerFailed = Notification.Name("bevakInputBlockerFailed")
    static let bevakSessionLost = Notification.Name("bevakSessionLost")
    static let toggleBevaka = Notification.Name("toggleBevaka")
    static let bevakHotkeyPreferenceChanged = Notification.Name("bevakHotkeyPreferenceChanged")
}
