import Foundation

enum LockState: Equatable {
    case unlocked
    case locking
    case locked
    case unlocking

    /// Valid state transitions to prevent invalid jumps.
    func canTransition(to next: LockState) -> Bool {
        switch (self, next) {
        case (.unlocked, .locking),
             (.locking, .locked),
             (.locking, .unlocked),   // failed to lock (no accessibility)
             (.locked, .unlocking),
             (.unlocking, .locked),   // auth failed
             (.unlocking, .unlocked), // auth succeeded
             (.locked, .unlocked):    // force unlock (session lost)
            return true
        default:
            return false
        }
    }
}
