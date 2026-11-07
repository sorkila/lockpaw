import AppKit
import Combine

/// Persists `SupportAsk.State` and applies its rules. `LockController` reports every
/// unlock, and whether an agent pinged during it; this decides between the once-ever card
/// (`SupportCardPanel`) and the yearly menu line, which the menu bar dropdown reads from
/// `isShowing`.
@MainActor
final class SupportAskController: ObservableObject {
    static let shared = SupportAskController()

    private enum Key {
        static let firstUse = "supportAskFirstUse"
        static let lastAsked = "supportAskLastAsked"
        static let pendingSince = "supportAskPendingSince"
        static let dismissedForever = "supportAskNever"
        static let pingUnlocks = "supportAskPingUnlocks"
        static let cardShown = "supportAskCardShown"
        static let locks = "supportAskLocks"
    }

    /// The support page, tagged so visits from the card can be told apart in the site's stats.
    /// Only the word "card" goes along; nothing about the user does.
    private static let cardSupportURL: URL = {
        var components = URLComponents(url: SupporterLicence.supportPageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "from", value: "card")]
        return components?.url ?? SupporterLicence.supportPageURL
    }()

    @Published private(set) var isShowing = false

    private let defaults = UserDefaults.standard
    private let card = SupportCardPanel()
    private var pendingCard: DispatchWorkItem?
    private var supporterObserver: AnyCancellable?

    private init() {
        if defaults.object(forKey: Key.firstUse) == nil { defaults.set(Date(), forKey: Key.firstUse) }
        card.onAction = { [weak self] action in self?.handle(action) }
        // A licence entered in Settings: the supporter mascots arrive as the thank-you,
        // after paying and never as the reason to (gifts promised for giving crowd it out).
        supporterObserver = Supporter.shared.$isSupporter
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in self?.welcomeSupporter() }
        refresh()
    }

    private var state: SupportAsk.State {
        get {
            SupportAsk.State(
                firstUse: defaults.object(forKey: Key.firstUse) as? Date,
                lastAsked: defaults.object(forKey: Key.lastAsked) as? Date,
                pendingSince: defaults.object(forKey: Key.pendingSince) as? Date,
                dismissedForever: defaults.bool(forKey: Key.dismissedForever),
                pingUnlocks: defaults.integer(forKey: Key.pingUnlocks),
                cardShown: defaults.bool(forKey: Key.cardShown),
                locks: defaults.integer(forKey: Key.locks)
            )
        }
        set {
            defaults.set(newValue.firstUse, forKey: Key.firstUse)
            defaults.set(newValue.lastAsked, forKey: Key.lastAsked)
            defaults.set(newValue.pendingSince, forKey: Key.pendingSince)
            defaults.set(newValue.dismissedForever, forKey: Key.dismissedForever)
            defaults.set(newValue.pingUnlocks, forKey: Key.pingUnlocks)
            defaults.set(newValue.cardShown, forKey: Key.cardShown)
            defaults.set(newValue.locks, forKey: Key.locks)
        }
    }

    /// Lockpaw just did its job: the user unlocked. Every unlock counts toward the
    /// cover-only route to the card. Only one after an agent ping may raise the yearly menu
    /// line, as before.
    func noteUnlock(_ unlock: SupportAsk.Unlock, now: Date = Date()) {
        var current = SupportAsk.countingLock(SupportAsk.expiring(state, now: now))
        if unlock != .plain { current = SupportAsk.countingPingUnlock(current) }
        let isSupporter = Supporter.shared.isSupporter
        if SupportAsk.cardIsDue(current, isSupporter: isSupporter, unlock: unlock, now: now) {
            scheduleCard(after: unlock)
        } else if unlock != .plain, SupportAsk.shouldRaise(after: current, isSupporter: isSupporter, now: now) {
            current.pendingSince = now
        }
        state = current
        refresh(now: now)
    }

    /// A new lock: an unanswered card steps aside and the menu line carries the ask.
    func lockStarted() {
        pendingCard?.cancel()
        pendingCard = nil
        card.foldAway()
    }

    func refresh(now: Date = Date()) {
        let current = SupportAsk.expiring(state, now: now)
        if current != state { state = current }
        isShowing = SupportAsk.isShowing(current, isSupporter: Supporter.shared.isSupporter, now: now)
    }

    // MARK: - Menu line

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

    // MARK: - Card

    /// The cover is still fading out and the user is turning back to their agent's work,
    /// so the card waits a moment, then checks the moment is still right.
    private func scheduleCard(after unlock: SupportAsk.Unlock) {
        pendingCard?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCard = nil
            let now = Date()
            guard LockStatus.shared.state == .unlocked, Self.isCalm,
                  SupportAsk.cardIsDue(self.state, isSupporter: Supporter.shared.isSupporter, unlock: unlock, now: now)
            else { return }
            let reason = SupportAsk.cardReason(self.state)
            self.state = SupportAsk.showingCard(self.state, now: now)
            self.refresh(now: now)
            self.card.show(.ask(reason))
        }
        pendingCard = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.supportCardDelay, execute: work)
    }

    /// Nothing in full screen. A game, a video or a presentation is not a breakpoint; the
    /// card waits for the next unlock instead. (An auto-hiding menu bar is a system-wide
    /// preference for some people, so it doesn't count.)
    private static var isCalm: Bool {
        let options = NSApp.currentSystemPresentationOptions
        return !options.contains(.fullScreen) && !options.contains(.hideMenuBar)
    }

    private func handle(_ action: SupportCardPanel.Action) {
        #if DEBUG
        if handlePreview(action) { return }
        #endif
        switch action {
        case .support:
            NSWorkspace.shared.open(Self.cardSupportURL)
            markAsked()
            card.show(.thanks)
        case .notNow:
            markAsked()
            card.show(.notNow)
        case .alreadySupport:
            neverAsk()
            card.show(.already)
        case .freeLicence:
            NSWorkspace.shared.open(SupporterLicence.supportPageURL)
            card.dismiss()
        case .openSettings(let section):
            card.dismiss()
            SettingsRequest.open(section)
        case .close:
            card.dismiss()
        }
    }

    private func welcomeSupporter() {
        refresh()
        let friends = Mascot.supporterCases.filter { $0.assetName.map(Mascot.bundledAssetExists) ?? false }
        guard !friends.isEmpty else { return }
        card.show(.welcome(friends: friends))
    }

    #if DEBUG
    /// `lockpaw://support-card`: the card as it would appear, links included, without
    /// touching the stored state.
    func previewCard() {
        isPreviewing = true
        card.show(.ask(.agents))
    }

    private var isPreviewing = false

    /// Walks the preview through every ending; returns false once it's over.
    private func handlePreview(_ action: SupportCardPanel.Action) -> Bool {
        guard isPreviewing else { return false }
        switch action {
        case .support:
            NSWorkspace.shared.open(Self.cardSupportURL)
            card.show(.thanks)
        case .notNow: card.show(.notNow)
        case .alreadySupport: card.show(.already)
        case .freeLicence:
            NSWorkspace.shared.open(SupporterLicence.supportPageURL)
            isPreviewing = false
            card.dismiss()
        case .openSettings(.about): previewWelcome()
        default: isPreviewing = false; card.dismiss()
        }
        return true
    }

    /// `lockpaw://support-card-welcome`: the welcome a new supporter sees.
    func previewWelcome() {
        card.show(.welcome(friends: Mascot.supporterCases.filter { $0.assetName.map(Mascot.bundledAssetExists) ?? false }))
    }
    #endif

    private func markAsked() {
        var current = state
        current.lastAsked = Date()
        current.pendingSince = nil
        state = current
        refresh()
    }
}
