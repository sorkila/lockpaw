import CoreGraphics

/// The real state of the macOS lock screen, read from the window server rather than taken
/// from the `com.apple.screenIsLocked` / `screenIsUnlocked` notifications, which any local
/// process can post. "Unlock with your Mac" must not be triggerable by a script.
enum SystemSession {
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
