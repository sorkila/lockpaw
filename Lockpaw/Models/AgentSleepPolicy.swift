import Foundation

/// "Sleep when agents finish": while locked, once every agent session Lockpaw saw active
/// (working, running a command, or waiting on the user) has finished and the chosen delay
/// has passed, put the Mac to sleep. A pure reducer, so every
/// branch is unit-tested. `AgentSleepController` gathers the inputs and runs the actions.
enum AgentSleepPolicy {
    /// Checkbox, off by default.
    static let enabledKey = "sleepWhenAgentsFinish"
    /// Delay picker in minutes, shown only while enabled.
    static let delayKey = "sleepWhenAgentsFinishDelay"
    static let delayOptions = [5, 15, 30]
    static let defaultDelayMinutes = 5

    /// The stored delay, falling back to the default for anything not offered.
    static func delay(minutes: Int) -> TimeInterval {
        TimeInterval((delayOptions.contains(minutes) ? minutes : defaultDelayMinutes) * 60)
    }

    struct State: Equatable {
        /// A tracked session was active at some point during this lock. Nothing happens
        /// without it: a lock with no agent Lockpaw can see (Codex, Cursor, Copilot and
        /// Aider only say when they finish) keeps the Mac awake, as before.
        var sawWork = false
        /// When the last active session finished.
        var idleSince: Date?
        /// Sleep was requested for this quiet spell. The sleep holds stay released, so the
        /// Mac can sleep on its own again after a wake, until an agent starts working.
        var released = false
    }

    enum Action: Equatable {
        case none
        /// Release Lockpaw's sleep holds (the idle assertion and lid-closed mode), then sleep.
        case sleep
        /// Put the holds back: work resumed, or the setting was turned off mid-lock.
        case restoreHolds
    }

    static func step(
        _ state: State,
        enabled: Bool,
        locked: Bool,
        activeSessions: Int,
        now: Date,
        delay: TimeInterval
    ) -> (State, Action) {
        // Unlocking releases the holds anyway; the next lock starts fresh.
        guard locked else { return (State(), .none) }
        guard enabled else { return (State(), state.released ? .restoreHolds : .none) }

        var next = state
        if activeSessions > 0 {
            next.sawWork = true
            next.idleSince = nil
            guard state.released else { return (next, .none) }
            next.released = false
            return (next, .restoreHolds)
        }

        guard next.sawWork, !next.released else { return (next, .none) }
        let since = next.idleSince ?? now
        next.idleSince = since
        guard now.timeIntervalSince(since) >= delay else { return (next, .none) }
        next.released = true
        return (next, .sleep)
    }

    /// Someone is at the keyboard (typing the password, say): restart the quiet spell, so
    /// the Mac never goes to sleep under them.
    static func notingPresence(_ state: State, now: Date) -> State {
        guard !state.released, state.idleSince != nil else { return state }
        var next = state
        next.idleSince = now
        return next
    }
}
