import Foundation

/// When Lockpaw asks for support. Pure and tested, because an ask that nags is worse
/// than no ask.
///
/// The first ask is a card, shown once ever: after a week of use and five unlocks that
/// followed an agent ping, at an unlock where every agent had finished (a breakpoint, not
/// an agent waiting for permission). After that, at most once a year, a line in the menu
/// bar dropdown. Never for supporters, never after "Don't ask again" or "I already support
/// Lockpaw", never on the lock screen. A pending ask waits in the menu until the user opens
/// it, and lapses after a week if they don't.
enum SupportAsk {
    static let minimumUse: TimeInterval = 7 * 86_400
    static let interval: TimeInterval = 365 * 86_400
    static let pendingLifetime: TimeInterval = 7 * 86_400
    /// Unlocks after an agent ping before the card may come up: Lockpaw has proven itself.
    static let cardMinimumPingUnlocks = 5

    struct State: Equatable {
        var firstUse: Date?
        var lastAsked: Date?
        var pendingSince: Date?
        var dismissedForever = false
        var pingUnlocks = 0
        var cardShown = false
    }

    /// An unlock after an agent ping: count it. Whether the card is due is a separate
    /// question, asked again when the card would actually appear.
    static func countingPingUnlock(_ state: State) -> State {
        var state = state
        state.pingUnlocks += 1
        return state
    }

    /// Whether this unlock is the card's moment. `allFinished`: every ping this lock was a
    /// finished agent, so the user is coming back to look, not rushing to approve something.
    static func cardIsDue(_ state: State, isSupporter: Bool, allFinished: Bool, now: Date) -> Bool {
        guard allFinished, !state.cardShown, state.pingUnlocks >= cardMinimumPingUnlocks else { return false }
        return isEligible(state, isSupporter: isSupporter, now: now)
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
