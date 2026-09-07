import Foundation
import Combine
import AppKit
import SwiftUI
import Carbon
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "LockController")

@MainActor
class LockController: ObservableObject {
    @Published private(set) var state: LockState = .unlocked {
        didSet { LockStatus.shared.update(state) }
    }
    @Published var lockStartTime: Date?
    @Published var elapsedTime: TimeInterval = 0
    @Published private(set) var isAuthenticating = false
    @Published var lastError: String?
    @Published private(set) var unlockSucceeded = false
    @Published private(set) var failCount = 0
    /// Incremented on each agent ping that should pulse the lock screen. The lock
    /// screen watches this token to trigger a one-shot attention glow.
    @Published private(set) var pingPulse: Int = 0

    /// True from the first agent ping until unlock — after the glow pulses finish,
    /// the lock screen keeps a subtle "your agent needs you" hint from this flag.
    @Published private(set) var agentAttention = false

    /// True while the Touch ID sensor is armed with no prompt on screen — the lock screen
    /// reads it to say a touch is enough, no button first.
    @Published private(set) var passiveAuthArmed = false

    private let overlayManager = OverlayWindowManager()
    private let inputBlocker = InputBlocker()
    private let authenticator = Authenticator()
    private let sleepPreventer = SleepPreventer()
    private let presentationController = PresentationController()

    private var timer: Timer?
    private var sleepObserver: Any?
    private var sessionLostObserver: Any?
    private var sessionActiveObserver: Any?
    private var inputBlockerFailedObserver: Any?
    private var accessibilityCheckTimer: Timer?
    private var errorClearTask: Task<Void, Never>?
    private var toggleObserver: Any?
    private var pingObserver: Any?
    private var authenticationInProgress = false
    private var sessionWasLost = false
    private var lastAuthFailTime: Date?
    private var lastPingTime: Date?
    private var passiveAuthTask: Task<Void, Never>?
    /// Bumped by every arm and disarm so a late-resolving evaluation can tell it is stale.
    private var passiveAuthGeneration = 0
    /// Set for the rest of the lock session when arming proved to cost more than it gives
    /// (see `secureInputProbe`). Cleared on the next lock().
    private var passiveAuthUnavailableForSession = false

    init() {
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .toggleLockpaw, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .unlocked {
                    self.lock()
                } else if self.state == .locked {
                    if HotkeyConfig.requiresAuthenticationToUnlock {
                        self.requestUnlock()
                    } else {
                        self.quickUnlock()
                    }
                }
            }
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked else { return }
                self.inputBlocker.stopBlocking()
                self.inputBlocker.startBlocking()
                self.overlayManager.blockSystemDialogs()
                self.armPassiveAuth()
            }
        }

        sessionLostObserver = NotificationCenter.default.addObserver(
            forName: .lockpawSessionLost, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .locked || self.state == .unlocking {
                    self.sessionWasLost = true
                    self.disarmPassiveAuth()
                    if self.authenticationInProgress {
                        self.authenticator.cancelPending()
                        self.authenticationInProgress = false
                        self.isAuthenticating = false
                        self.overlayManager.blockSystemDialogs()
                        self.inputBlocker.startBlocking()
                        self.transitionTo(.locked)
                        self.lastError = "Session interrupted — try again"
                        self.scheduleErrorClear()
                    }
                }
            }
        }

        sessionActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked, self.sessionWasLost else { return }
                self.sessionWasLost = false
                self.inputBlocker.stopBlocking()
                self.inputBlocker.startBlocking()
                self.overlayManager.blockSystemDialogs()
                self.armPassiveAuth()
            }
        }

        inputBlockerFailedObserver = NotificationCenter.default.addObserver(
            forName: .lockpawInputBlockerFailed, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastError = "Input blocking failed"
                try? await Task.sleep(nanoseconds: Constants.Timing.errorDisplayBeforeForceUnlockNs)
                self.forceUnlock()
            }
        }

        pingObserver = NotificationCenter.default.addObserver(
            forName: .lockpawPing, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handlePing()
            }
        }
    }

    deinit {
        if let obs = toggleObserver { NotificationCenter.default.removeObserver(obs) }
        passiveAuthTask?.cancel()
        timer?.invalidate()
        accessibilityCheckTimer?.invalidate()
        errorClearTask?.cancel()
        if let obs = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = sessionLostObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = sessionActiveObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let obs = inputBlockerFailedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = pingObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Public

    func lock() {
        guard transitionTo(.locking) else { return }
        guard AccessibilityChecker.isEnabled else {
            AccessibilityChecker.promptIfNeeded()
            transitionTo(.unlocked)
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        sleepPreventer.preventSleep()

        let mirrorAll = UserDefaults.standard.integer(forKey: "multiDisplayMode") == 1
        let fadeTimeout = FadeToBlack.currentTimeout
        guard overlayManager.showOverlay(contentFactory: { [weak self] index, isPrimary in
            guard let self else { return AnyView(Color.black) }
            return AnyView(OverlayRootView(
                controller: self,
                presentationController: self.presentationController,
                showsLockUI: isPrimary || mirrorAll,
                phaseOffset: mirrorAll ? 0 : CGFloat(index) * 0.15
            ))
        }) else {
            logger.error("Lock failed — no screens available for overlay")
            sleepPreventer.allowSleep()
            transitionTo(.unlocked)
            lastError = "No screens available"
            scheduleErrorClear()
            return
        }

        // After the overlay is up (the failure path above never starts anything) and
        // before transitionTo(.locked) below, so the state sink observes the entry
        // into .locked and arms the blackout timer.
        presentationController.start(timeout: fadeTimeout, state: $state, error: $lastError)

        Task {
            try? await Task.sleep(nanoseconds: Constants.Timing.inputBlockerDelayNs)
            inputBlocker.startBlocking()
        }

        stopTimer()
        lockStartTime = Date()
        failCount = 0
        lastError = nil
        unlockSucceeded = false
        lastAuthFailTime = nil
        passiveAuthUnavailableForSession = false
        errorClearTask?.cancel()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.state == .locked || self.state == .unlocking,
                      let start = self.lockStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }

        startAccessibilityMonitoring()
        sessionWasLost = false
        transitionTo(.locked)
        armPassiveAuth()
    }

    /// Quick unlock via hotkey — no auth.
    func quickUnlock() {
        guard state == .locked, !authenticationInProgress else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        unlock()
    }

    /// Fallback unlock via Touch ID / Mac password.
    func requestUnlock() {
        guard state == .locked, !authenticationInProgress else { return }

        // Rate limit after 3 failures
        if failCount >= Constants.Timing.maxAuthAttempts, let lastFail = lastAuthFailTime,
           Date().timeIntervalSince(lastFail) < Constants.Timing.authRateLimitCooldown {
            let remaining = Int(Constants.Timing.authRateLimitCooldown - Date().timeIntervalSince(lastFail))
            lastError = "Too many attempts. Wait \(remaining)s."
            scheduleErrorClear()
            return
        }

        disarmPassiveAuth()
        guard transitionTo(.unlocking) else { return }
        authenticationInProgress = true
        isAuthenticating = true
        lastError = nil

        overlayManager.allowSystemDialogs()
        inputBlocker.stopBlocking()

        Task { @MainActor in
            let authenticated = await authenticator.authenticate()

            guard state == .unlocking else {
                authenticationInProgress = false
                isAuthenticating = false
                overlayManager.blockSystemDialogs()
                inputBlocker.startBlocking()
                return
            }

            authenticationInProgress = false
            isAuthenticating = false

            if authenticated {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                unlockSucceeded = true
                try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
                guard !Task.isCancelled else { return }
                unlock()
            } else {
                handleAuthFailure()
            }
        }
    }

    func requestPasswordUnlock() {
        guard state == .locked, !authenticationInProgress else { return }

        if failCount >= Constants.Timing.maxAuthAttempts, let lastFail = lastAuthFailTime,
           Date().timeIntervalSince(lastFail) < Constants.Timing.authRateLimitCooldown {
            let remaining = Int(Constants.Timing.authRateLimitCooldown - Date().timeIntervalSince(lastFail))
            lastError = "Too many attempts. Wait \(remaining)s."
            scheduleErrorClear()
            return
        }

        disarmPassiveAuth()
        guard transitionTo(.unlocking) else { return }
        authenticationInProgress = true
        isAuthenticating = true
        lastError = nil

        overlayManager.allowSystemDialogs()
        inputBlocker.stopBlocking()

        Task { @MainActor in
            let authenticated = await authenticator.authenticateWithPassword()

            guard state == .unlocking else {
                authenticationInProgress = false
                isAuthenticating = false
                overlayManager.blockSystemDialogs()
                inputBlocker.startBlocking()
                return
            }

            authenticationInProgress = false
            isAuthenticating = false

            if authenticated {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                unlockSucceeded = true
                try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
                guard !Task.isCancelled else { return }
                unlock()
            } else {
                handleAuthFailure()
            }
        }
    }

    // MARK: - Private

    /// React to an agent ping. Debounces chatty agents, then pulses the lock screen
    /// and/or posts a notification per `PingDecision` (no-op when unlocked).
    private func handlePing() {
        let now = Date()
        if let last = lastPingTime, now.timeIntervalSince(last) < Constants.Timing.pingDebounce { return }
        lastPingTime = now

        let soundEnabled = UserDefaults.standard.bool(forKey: Constants.agentPingSoundKey)
        let decision = PingDecision.make(state: state, soundEnabled: soundEnabled)
        if decision.shouldPulse {
            pingPulse &+= 1
            agentAttention = true
            presentationController.notePing()
        }
        if decision.shouldNotify { AgentNotifier.shared.notify(withSound: decision.withSound) }
    }

    private func noteAuthFailure() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        failCount += 1
        lastAuthFailTime = Date()
        lastError = failCount >= Constants.Timing.maxAuthAttempts ? "Too many attempts. Wait \(Int(Constants.Timing.authRateLimitCooldown)) seconds." : "Try again"
        scheduleErrorClear()
    }

    private func handleAuthFailure() {
        noteAuthFailure()
        overlayManager.blockSystemDialogs()
        inputBlocker.startBlocking()
        transitionTo(.locked)
        armPassiveAuth()
    }

    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task {
            try? await Task.sleep(nanoseconds: Constants.Timing.errorAutoClearNs)
            if !Task.isCancelled, lastError != nil { lastError = nil }
        }
    }

    @discardableResult
    private func transitionTo(_ newState: LockState) -> Bool {
        guard state.canTransition(to: newState) else {
            logger.warning("Invalid transition: \(String(describing: self.state)) → \(String(describing: newState))")
            return false
        }
        state = newState
        return true
    }

    private func unlock() {
        presentationController.stop()
        disarmPassiveAuth()
        stopAccessibilityMonitoring()
        stopTimer()
        errorClearTask?.cancel()
        lockStartTime = nil
        elapsedTime = 0
        clearAgentAttention()
        state = .unlocked
        overlayManager.dismissOverlay(animated: true)
        inputBlocker.stopBlocking()
        sleepPreventer.allowSleep()
    }

    private func forceUnlock() {
        presentationController.stop()
        disarmPassiveAuth()
        authenticationInProgress = false
        isAuthenticating = false
        authenticator.cancelPending()
        stopAccessibilityMonitoring()
        stopTimer()
        errorClearTask?.cancel()
        lockStartTime = nil
        elapsedTime = 0
        clearAgentAttention()
        state = .unlocked
        overlayManager.dismissOverlay()
        inputBlocker.stopBlocking()
        sleepPreventer.allowSleep()
    }

    // MARK: - Passive Touch ID

    /// Arm the sensor so a finger press unlocks with no click first, or schedule the arm
    /// for when the rate-limit cooldown expires. Always disarms first, so there is never
    /// more than one LAContext in flight.
    private func armPassiveAuth() {
        disarmPassiveAuth()
        guard !passiveAuthUnavailableForSession else { return }

        switch PassiveAuthPolicy.decide(
            state: state,
            biometryAvailable: authenticator.isBiometryAvailable,
            authenticationInProgress: authenticationInProgress,
            failCount: failCount,
            lastFailure: lastAuthFailTime,
            now: Date()
        ) {
        case .doNotArm:
            return

        case .armAfter(let delay):
            let generation = passiveAuthGeneration
            passiveAuthTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, generation == self.passiveAuthGeneration else { return }
                self.armPassiveAuth()
            }

        case .arm:
            let generation = passiveAuthGeneration
            passiveAuthArmed = true
            passiveAuthTask = Task { @MainActor [weak self] in
                await self?.runPassiveAuth(generation: generation)
            }
        }
    }

    /// Cancelling the Swift task does not stop the evaluation — the LAContext has to be
    /// invalidated too, or the sensor stays armed after the overlay is gone.
    private func disarmPassiveAuth() {
        passiveAuthGeneration &+= 1
        passiveAuthArmed = false
        guard let task = passiveAuthTask else { return }
        passiveAuthTask = nil
        task.cancel()
        authenticator.cancelPending()
    }

    private func runPassiveAuth(generation: Int) async {
        let probe = secureInputProbe(baseline: IsSecureEventInputEnabled(), generation: generation)
        let result = await authenticator.armBiometrics()
        probe.cancel()

        guard generation == passiveAuthGeneration, state == .locked else { return }
        passiveAuthArmed = false

        switch PassiveAuthPolicy.outcome(result) {
        case .unlock:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            unlockSucceeded = true
            try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
            guard generation == passiveAuthGeneration else { return }
            unlock()

        case .countFailureAndRearm:
            noteAuthFailure()
            armPassiveAuth()

        case .standDown:
            break
        }
    }

    /// macOS turns secure input on while a LocalAuthentication prompt is up, and secure
    /// input hides keystrokes from event taps (the #10 bypass). An armed sensor holds that
    /// prompt open for the whole locked session, so if it costs the unlock hotkey — the
    /// primary way out — the trade is not worth it. Sample once after arming and, only if
    /// arming is what flipped it, give the sensor back and leave the button in charge.
    private func secureInputProbe(baseline: Bool, generation: Int) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Constants.Timing.secureInputProbeNs)
            guard !Task.isCancelled, !baseline, IsSecureEventInputEnabled(),
                  let self, generation == self.passiveAuthGeneration else { return }
            logger.warning("Armed Touch ID turned secure input on — standing down, hotkey unlock takes priority")
            self.passiveAuthUnavailableForSession = true
            self.disarmPassiveAuth()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Once unlocked, the agent banners in Notification Center are stale — the user
    /// is back at the machine. Drop the flag and the delivered notifications together.
    private func clearAgentAttention() {
        agentAttention = false
        AgentNotifier.shared.clearDelivered()
    }

    private func startAccessibilityMonitoring() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.state == .locked, !AccessibilityChecker.isEnabled else { return }
                logger.critical("Accessibility revoked while locked — force unlocking")
                self.lastError = "Accessibility permission revoked"
                try? await Task.sleep(nanoseconds: Constants.Timing.errorDisplayBeforeForceUnlockNs)
                self.forceUnlock()
            }
        }
    }

    private func stopAccessibilityMonitoring() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }
}
