import Foundation

/// Decides whether the app may quit right now.
///
/// While the screen is guarded, Lockpaw is the active app and its overlay is the key
/// window, so an app-wide Cmd+Q would reach it. The input tap normally swallows that
/// keystroke, but macOS turns on secure input while the Touch ID / password sheet is
/// up, and secure input hides keystrokes from event taps. That is the reported
/// bypass: press the hotkey, choose "Use Password…", hit Cmd+Q, and the guard is
/// gone. The fix lives at the only chokepoint every quit path shares:
/// `applicationShouldTerminate`, which consults this policy.
///
/// Pure and unit-tested. Quitting is allowed only when fully unlocked — during
/// `.locking` the overlay is going up, during `.unlocking` auth may still fail and
/// return to `.locked`.
enum TerminationPolicy {
    static func allowsQuit(state: LockState) -> Bool {
        state == .unlocked
    }
}

/// The current lock state, mirrored for code that has no `LockController` reference
/// (the app delegate). `LockController` writes it on every state change.
@MainActor
final class LockStatus {
    static let shared = LockStatus()
    private(set) var state: LockState = .unlocked

    private init() {}

    func update(_ state: LockState) {
        self.state = state
    }
}
