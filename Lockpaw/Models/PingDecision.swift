import Foundation

/// Pure decision for how Lockpaw reacts to an agent ping, given the current lock
/// state and the user's sound preference. Kept free of UI and side effects so the
/// branching logic can be unit-tested directly.
struct PingDecision: Equatable {
    let shouldPulse: Bool
    let shouldNotify: Bool
    let withSound: Bool

    static let none = PingDecision(shouldPulse: false, shouldNotify: false, withSound: false)

    static func make(state: LockState, soundEnabled: Bool) -> PingDecision {
        // A ping only matters while the screen is covered and the user has stepped away.
        // When unlocked (user present) stay silent — the agent's own UI is already visible.
        // During transient .locking / .unlocking states, do nothing.
        guard state == .locked else { return .none }
        return PingDecision(shouldPulse: true, shouldNotify: true, withSound: soundEnabled)
    }
}
