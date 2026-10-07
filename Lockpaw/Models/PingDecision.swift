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

/// Which pings get announced (glow pulse, notification, relay) during one lock session.
/// Replaces a single global 2s debounce, which dropped a *different* agent's ping — Codex
/// finishing, then Claude blocked a second later, came through as "Codex finished" only.
///
/// - A session already announced with the same kind stays quiet. That absorbs Claude's
///   `idle_prompt`, which repeats a turn's end a minute after `Stop`, and chatty hooks.
/// - A change of kind always goes through: done → waiting is the news.
/// - Pings with no session id (a bare `lockpaw ping` from a script) fall back to the old
///   short debounce, keyed by agent and kind so different sources never shadow each other.
///
/// Reset at every lock, so a turn that ended just before locking still glows once after.
struct PingGate {
    private var announced: [String: AgentPing.Kind] = [:]
    private var lastBare: [String: Date] = [:]

    mutating func admits(_ ping: AgentPing, now: Date = Date()) -> Bool {
        if let session = ping.sessionID {
            let key = "\(ping.agent ?? "-")/\(session)"
            if announced[key] == ping.kind { return false }
            announced[key] = ping.kind
            return true
        }
        let key = "\(ping.agent ?? "-")|\(ping.kind)"
        if let last = lastBare[key], now.timeIntervalSince(last) < Constants.Timing.pingDebounce { return false }
        lastBare[key] = now
        return true
    }

    mutating func reset() {
        announced.removeAll()
        lastBare.removeAll()
    }
}
