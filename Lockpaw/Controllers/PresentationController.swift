import AppKit
import Combine
import SwiftUI

/// Drives what the lock overlay *shows* — the normal lock UI, pure black
/// (fade-to-black burn-in protection), or a bounded agent-attention pulse —
/// without ever touching the security-relevant `LockState`. All branching lives
/// in `PresentationLogic` (pure, unit-tested); this class only runs the effects:
/// one one-shot timer slot, NSEvent mouse monitors, the `.lockpawPhysicalInput`
/// side channel, and per-direction cross-fade animations.
@MainActor
final class PresentationController: ObservableObject {
    /// What every overlay screen renders. Mutated only via `setPresentation`.
    @Published private(set) var presentation: LockPresentation = .visible

    /// Bumped when a ping (re)starts the attention pulse — the pulse view keys off
    /// it, and it guards stale pulse-end timer closures (same generation pattern as
    /// LockScreenView.triggerPingGlow()).
    @Published private(set) var attentionGeneration = 0

    private var configuredTimeout: TimeInterval?
    private var armed: ArmedTimer?
    /// Single one-shot slot — arming always invalidates the previous timer, which
    /// is what makes a stale blackout/reblack fire structurally impossible.
    private var timer: Timer?
    private var monitors: [Any] = []
    private var physicalInputObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var active = false
    private var lastHandledInput = Date.distantPast

    private static let mouseMask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    /// Called from lock() after the overlay is up and *before* the transition to
    /// .locked — the state sink observes that entry and arms the blackout timer.
    /// With `timeout == nil` (feature off) nothing is installed at all: no monitors,
    /// no subscriptions, and `presentation` stays `.visible` for the whole session.
    func start(
        timeout: TimeInterval?,
        state: Published<LockState>.Publisher,
        error: Published<String?>.Publisher
    ) {
        stopInternals()
        presentation = .visible  // pre-display reset; nothing is on screen yet
        configuredTimeout = timeout
        guard timeout != nil else { return }
        active = true

        // .locked entries arm (initial lock AND re-entry after a failed auth);
        // anything else means the auth UI or teardown owns the screen.
        state
            .removeDuplicates()
            .sink { [weak self] newState in
                Task { @MainActor [weak self] in
                    self?.apply(newState == .locked ? .lockEngaged : .lockStateLeftLocked)
                }
            }
            .store(in: &cancellables)

        // Errors must be visible wherever they're set (auth failure, rate limit,
        // input-blocker failure, accessibility revocation, session interruption, …).
        error
            .compactMap { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.apply(.errorSurfaced)
                }
            }
            .store(in: &cancellables)

        // Mouse comes in via NSEvent monitors (InputBlocker's tap doesn't touch mouse
        // events). Keyboard/scroll never reach NSEvent — the tap swallows them and
        // posts .lockpawPhysicalInput instead.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseMask, handler: { [weak self] event in
            guard Self.isPhysical(event) else { return }
            Task { @MainActor [weak self] in self?.notePhysicalInput() }
        }) {
            monitors.append(global)
        }

        // The local monitor must decide consumption synchronously, so no Task hop:
        // handlers run on the main thread inside NSApp.sendEvent. Only a Bool crosses
        // the assumeIsolated boundary (NSEvent isn't Sendable).
        if let local = NSEvent.addLocalMonitorForEvents(matching: Self.mouseMask, handler: { [weak self] event in
            guard let self else { return event }
            let physical = Self.isPhysical(event)
            let isMouseDown = event.type == .leftMouseDown
                || event.type == .rightMouseDown
                || event.type == .otherMouseDown
            let consume = MainActor.assumeIsolated { () -> Bool in
                if physical { self.notePhysicalInput() }
                // Consume the reveal click so it can never press the auth button that
                // is about to mount (the orphaned mouseUp is harmless — AppKit buttons
                // need the down). Mouse moves always pass through so the cursor-rehide
                // monitor in OverlayWindowManager keeps working.
                return isMouseDown && self.presentation != .visible
            }
            return consume ? nil : event
        }) {
            monitors.append(local)
        }

        physicalInputObserver = NotificationCenter.default.addObserver(
            forName: .lockpawPhysicalInput, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.notePhysicalInput() }
        }
    }

    /// Called first thing in unlock()/forceUnlock(). Deliberately leaves
    /// `presentation` untouched: unlocking from black should fade the overlay out
    /// from black, not flash the lock UI — the next start() resets it.
    func stop() {
        stopInternals()
    }

    /// Called from handlePing() only when PingDecision said to pulse, so this
    /// inherits the existing debounce and the state == .locked gate.
    func notePing() {
        guard active else { return }
        apply(.agentPing)
    }

    deinit {
        timer?.invalidate()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let observer = physicalInputObserver { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Private

    private func stopInternals() {
        cancellables.removeAll()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let observer = physicalInputObserver {
            NotificationCenter.default.removeObserver(observer)
            physicalInputObserver = nil
        }
        timer?.invalidate()
        timer = nil
        armed = nil
        active = false
        configuredTimeout = nil
    }

    /// Hardware events carry eventSourceUnixProcessID == 0; synthetic posts carry the
    /// poster's PID. Best-effort: input remappers (Karabiner, BTT) repost hardware
    /// events under their own PID, so those users may need the unlock hotkey — which
    /// ignores this filter entirely. Events with no CGEvent count as physical.
    private static func isPhysical(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return true }
        return cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == 0
    }

    private func notePhysicalInput() {
        guard active else { return }
        if presentation == .visible {
            // Mouse moves arrive at event rate — don't re-arm a Timer per pixel.
            // The reveal path stays unthrottled so waking the screen is instant.
            let now = Date()
            guard now.timeIntervalSince(lastHandledInput) >= Constants.Timing.physicalInputThrottle else { return }
            lastHandledInput = now
        }
        apply(.physicalInput)
    }

    /// The only place effects happen: reduce, then run the decision.
    private func apply(_ event: PresentationEvent) {
        let decision = PresentationLogic.reduce(
            presentation: presentation, armed: armed, event: event, timeout: configuredTimeout
        )
        if decision.restartsAttentionPulse { attentionGeneration &+= 1 }
        switch decision.timer {
        case .none:
            break
        case .cancelAll:
            timer?.invalidate()
            timer = nil
            armed = nil
        case .armBlackout(let interval):
            arm(.blackout, after: interval)
        case .armReblack(let interval):
            arm(.reblack, after: interval)
        case .armAttentionEnd(let interval):
            arm(.attentionEnd, after: interval)
        }
        setPresentation(decision.presentation)
    }

    private func arm(_ kind: ArmedTimer, after interval: TimeInterval) {
        timer?.invalidate()
        armed = kind
        let generation = attentionGeneration
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armed = nil
                switch kind {
                case .blackout, .reblack:
                    self.apply(.inactivityTimerFired)
                case .attentionEnd:
                    // Belt-and-braces: the single slot already prevents stale fires,
                    // but a re-ping bumps the generation and re-arms, so check anyway.
                    guard generation == self.attentionGeneration else { return }
                    self.apply(.attentionPulseEnded)
                }
            }
        }
    }

    private func setPresentation(_ newPresentation: LockPresentation) {
        guard newPresentation != presentation else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            presentation = newPresentation
        } else {
            withAnimation(Self.animation(from: presentation, to: newPresentation)) {
                presentation = newPresentation
            }
        }
        // Pointer concealment stays with OverlayWindowManager's
        // setHiddenUntilMouseMoves machinery in every presentation state. Mixing
        // NSCursor.hide()/unhide() into it breaks the idle re-hide for the rest of
        // the session (documented as unpredictable when combined) — the cost is
        // only that a synthetic mouse nudge can show the pointer over black for
        // ~cursorIdleHide seconds before it re-conceals.
    }

    /// Direction-dependent cross-fade durations — the reason this uses withAnimation
    /// at the mutation site rather than an .animation(_:value:) view modifier, which
    /// can't express per-direction timing.
    static func animation(from: LockPresentation, to: LockPresentation) -> Animation {
        switch (from, to) {
        case (.visible, .black):
            return .easeInOut(duration: Constants.Timing.fadeToBlackDuration)
        case (.attention, .black):
            return .easeInOut(duration: Constants.Timing.attentionFadeOut)
        case (_, .attention):
            return .easeIn(duration: Constants.Timing.attentionFadeIn)
        default:
            return Constants.Anim.standard
        }
    }
}
