import Foundation

/// When Lockpaw asks for support. Pure and tested, because an ask that nags is worse
/// than no ask.
///
/// The first ask is a card, shown once ever: after a week of use and five unlocks that
/// followed an agent ping, at an unlock where every agent had finished (a breakpoint, not
/// an agent waiting for permission). People who only use Lockpaw as a screen cover never
/// see an agent ping, so for them the same card comes after twenty locks and two weeks
/// since first use, at an unlock with no agent waiting. Either way it is the one card,
/// shown once. After that, at most once a year, a line in the menu
/// bar dropdown. Never for supporters, never after "Don't ask again" or "I already support
/// Lockpaw", never on the lock screen. A pending ask waits in the menu until the user opens
/// it, and lapses after a week if they don't.
enum SupportAsk {
    static let minimumUse: TimeInterval = 7 * 86_400
    static let interval: TimeInterval = 365 * 86_400
    static let pendingLifetime: TimeInterval = 7 * 86_400
    /// Unlocks after an agent ping before the card may come up: Lockpaw has proven itself.
    static let cardMinimumPingUnlocks = 5
    /// The cover-only route to the same card: twenty locks, and two weeks since first use,
    /// so a busy first afternoon doesn't count as Lockpaw having proven itself.
    static let cardMinimumLocks = 20
    static let cardMinimumCoverUse: TimeInterval = 14 * 86_400

    /// The unlock the card might follow.
    enum Unlock: Equatable {
        /// An agent pinged during the lock. `allFinished`: every ping was an agent
        /// finishing, so the user is coming back to look, not rushing to approve something.
        case afterPings(allFinished: Bool)
        /// No agent pinged: Lockpaw kept the screen covered and that was the whole job.
        case plain

        fileprivate var isBreakpoint: Bool {
            if case .afterPings(let allFinished) = self { return allFinished }
            return true
        }
    }

    /// Which opening line the card gets, so it only mentions agents to people who use them.
    enum CardReason: Equatable {
        case agents
        case cover
    }

    struct State: Equatable {
        var firstUse: Date?
        var lastAsked: Date?
        var pendingSince: Date?
        var dismissedForever = false
        var pingUnlocks = 0
        var cardShown = false
        /// Every unlock, ping or not. Counted from the release that added it.
        var locks = 0
    }

    /// An unlock after an agent ping: count it. Whether the card is due is a separate
    /// question, asked again when the card would actually appear.
    static func countingPingUnlock(_ state: State) -> State {
        var state = state
        state.pingUnlocks += 1
        return state
    }

    /// Any finished lock: count it, for the cover-only route to the card.
    static func countingLock(_ state: State) -> State {
        var state = state
        state.locks += 1
        return state
    }

    /// Whether this unlock is the card's moment. Never while an agent waits on the user.
    /// The agent route needs a ping this lock; the cover route takes any calm unlock.
    static func cardIsDue(_ state: State, isSupporter: Bool, unlock: Unlock, now: Date) -> Bool {
        guard unlock.isBreakpoint, !state.cardShown else { return false }
        let viaAgents = unlock != .plain && state.pingUnlocks >= cardMinimumPingUnlocks
        guard viaAgents || hasCoveredLongEnough(state, now: now) else { return false }
        return isEligible(state, isSupporter: isSupporter, now: now)
    }

    /// The card's opening line: agents for those who have earned it through pings.
    static func cardReason(_ state: State) -> CardReason {
        state.pingUnlocks >= cardMinimumPingUnlocks ? .agents : .cover
    }

    private static func hasCoveredLongEnough(_ state: State, now: Date) -> Bool {
        guard state.locks >= cardMinimumLocks, let firstUse = state.firstUse else { return false }
        return now.timeIntervalSince(firstUse) >= cardMinimumCoverUse
    }

    /// The card is up. It is also the pending ask, so if the user locks again before
    /// answering, the menu line carries it for the rest of the week.
    static func showingCard(_ state: State, now: Date) -> State {
        var state = state
        state.cardShown = true
        state.pendingSince = now
        return state
    }

    /// Whether a good moment (unlock after a ping) should raise the yearly menu line.
    /// Only once the card has had its turn: the card is always the first ask.
    static func shouldRaise(after state: State, isSupporter: Bool, now: Date) -> Bool {
        guard state.cardShown else { return false }
        return isEligible(state, isSupporter: isSupporter, now: now)
    }

    /// Whether the menu should show the ask now.
    static func isShowing(_ state: State, isSupporter: Bool, now: Date) -> Bool {
        guard !isSupporter, !state.dismissedForever, let pending = state.pendingSince else { return false }
        return now.timeIntervalSince(pending) < pendingLifetime
    }

    /// Housekeeping on read: a pending ask nobody saw within a week counts as asked.
    static func expiring(_ state: State, now: Date) -> State {
        guard let pending = state.pendingSince, now.timeIntervalSince(pending) >= pendingLifetime else { return state }
        var state = state
        state.pendingSince = nil
        state.lastAsked = pending
        return state
    }

    private static func isEligible(_ state: State, isSupporter: Bool, now: Date) -> Bool {
        guard !isSupporter, !state.dismissedForever, state.pendingSince == nil,
              let firstUse = state.firstUse, now.timeIntervalSince(firstUse) >= minimumUse else { return false }
        if let lastAsked = state.lastAsked, now.timeIntervalSince(lastAsked) < interval { return false }
        return true
    }
}
