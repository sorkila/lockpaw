import AppKit
import Combine

/// Persists `SupportAsk.State` and applies its rules. The menu bar dropdown reads
/// `isShowing`; `LockController` reports the good moment (an unlock after an agent ping).
@MainActor
final class SupportAskController: ObservableObject {
    static let shared = SupportAskController()

    private enum Key {
        static let firstUse = "supportAskFirstUse"
        static let lastAsked = "supportAskLastAsked"
        static let pendingSince = "supportAskPendingSince"
        static let dismissedForever = "supportAskNever"
    }

    @Published private(set) var isShowing = false

    private let defaults = UserDefaults.standard

    private init() {
        if defaults.object(forKey: Key.firstUse) == nil { defaults.set(Date(), forKey: Key.firstUse) }
        refresh()
    }

    private var state: SupportAsk.State {
        get {
            SupportAsk.State(
                firstUse: defaults.object(forKey: Key.firstUse) as? Date,
                lastAsked: defaults.object(forKey: Key.lastAsked) as? Date,
                pendingSince: defaults.object(forKey: Key.pendingSince) as? Date,
                dismissedForever: defaults.bool(forKey: Key.dismissedForever)
            )
        }
        set {
            defaults.set(newValue.firstUse, forKey: Key.firstUse)
            defaults.set(newValue.lastAsked, forKey: Key.lastAsked)
            defaults.set(newValue.pendingSince, forKey: Key.pendingSince)
            defaults.set(newValue.dismissedForever, forKey: Key.dismissedForever)
        }
    }

    /// Lockpaw just did its job: the user unlocked after an agent pinged.
    func noteUnlockAfterPing(now: Date = Date()) {
        var current = SupportAsk.expiring(state, now: now)
        if SupportAsk.shouldRaise(after: current, isSupporter: Supporter.shared.isSupporter, now: now) {
            current.pendingSince = now
        }
        state = current
        refresh(now: now)
    }

    func refresh(now: Date = Date()) {
        let current = SupportAsk.expiring(state, now: now)
        if current != state { state = current }
        isShowing = SupportAsk.isShowing(current, isSupporter: Supporter.shared.isSupporter, now: now)
    }

    func support() {
        NSWorkspace.shared.open(SupporterLicence.supportPageURL)
        markAsked()
    }

    func notNow() { markAsked() }

    func neverAsk() {
        var current = state
        current.dismissedForever = true
        current.pendingSince = nil
        state = current
        refresh()
    }

    private func markAsked() {
        var current = state
        current.lastAsked = Date()
        current.pendingSince = nil
        state = current
        refresh()
    }
}
