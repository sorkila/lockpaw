import Foundation

/// The once-a-year "consider supporting Lockpaw" line in the menu bar dropdown. Pure and
/// tested, because an ask that nags is worse than no ask.
///
/// It only ever comes up right after Lockpaw did its job — an unlock that followed an agent
/// ping — after two weeks of use, at most once a year, never for supporters, never again
/// after "Don't ask again". Never on the lock screen and never as a popup: it waits in the
/// menu until the user opens it, and lapses after a week if they don't.
enum SupportAsk {
    static let minimumUse: TimeInterval = 14 * 86_400
    static let interval: TimeInterval = 365 * 86_400
    static let pendingLifetime: TimeInterval = 7 * 86_400

    struct State: Equatable {
        var firstUse: Date?
        var lastAsked: Date?
        var pendingSince: Date?
        var dismissedForever = false
    }

    /// Whether a good moment (unlock after a ping) should raise the ask.
    static func shouldRaise(after state: State, isSupporter: Bool, now: Date) -> Bool {
        guard !isSupporter, !state.dismissedForever, state.pendingSince == nil,
              let firstUse = state.firstUse, now.timeIntervalSince(firstUse) >= minimumUse else { return false }
        if let lastAsked = state.lastAsked, now.timeIntervalSince(lastAsked) < interval { return false }
        return true
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
}
