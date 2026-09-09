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

    /// True while the armed-Touch-ID path is live for this lock session — deliberately not
    /// the precise in-flight state of one evaluation. The lock screen reads it for its
    /// unlock prompt, and that caption must not flicker: `.rearmImmediately` flips the
    /// in-flight state twice per finger press (a partial read is a rejection), and
    /// re-rendering the lock screen mid-breath re-targets the mascot's long breathing
    /// animation, which reads on screen as the dog stuttering and jumping in size. So this
    /// goes true on the first arm of a lock session and false only when the path really is
    /// gone — suspended, or the session over. `passiveEvaluationInFlight` carries the
    /// precise state for the tick.
    @Published private(set) var passiveAuthLive = false

    /// The precise state: an evaluation is armed right now. Internal — never drives the UI.
    private var passiveEvaluationInFlight = false

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
    /// Stable reasons not to arm again before the next lock(): biometry that is gone or
    /// locked out, or secure input coming up while armed.
    private var passiveAuthSuspended = false
    /// Whether this Mac can arm at all. Sampled once per lock session and again after sleep
    /// or a session switch, not on every tick — answering it builds an LAContext.
    private var biometryAvailable = false
    /// Secure-input reading taken as the current arm started, so the tick can tell a flip
    /// caused by arming from one that was already there.
    private var secureInputBeforeArm = false

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
                self.armPassiveAuthAfterInterruption()
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
                self.armPassiveAuthAfterInterruption()
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
        passiveAuthSuspended = false
        biometryAvailable = authenticator.isBiometryAvailable
        logger.info("lock: biometryAvailable=\(self.biometryAvailable)")
        errorClearTask?.cancel()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.state == .locked || self.state == .unlocking,
                      let start = self.lockStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
                self.tickPassiveAuth()
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

    private func handleAuthFailure() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        failCount += 1
        lastAuthFailTime = Date()
        lastError = failCount >= Constants.Timing.maxAuthAttempts ? "Too many attempts. Wait \(Int(Constants.Timing.authRateLimitCooldown)) seconds." : "Try again"

        overlayManager.blockSystemDialogs()
        inputBlocker.startBlocking()
        transitionTo(.locked)
        scheduleErrorClear()
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
        disarmPassiveAuth(endingSession: true)
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
        disarmPassiveAuth(endingSession: true)
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

    /// Arm the sensor so a finger press unlocks with no click first. Always disarms first,
    /// so there is never more than one LAContext in flight.
    private func armPassiveAuth() {
        disarmPassiveAuth()
        guard PassiveAuthPolicy.shouldArm(
            state: state,
            unlockCommitted: unlockSucceeded,
            biometryAvailable: biometryAvailable,
            suspended: passiveAuthSuspended,
            authenticationInProgress: authenticationInProgress,
            failCount: failCount,
            lastFailure: lastAuthFailTime,
            now: Date()
        ) else {
            logger.info("passiveAuth: arm refused — state=\(String(describing: self.state)), committed=\(self.unlockSucceeded), biometry=\(self.biometryAvailable), suspended=\(self.passiveAuthSuspended), authInProgress=\(self.authenticationInProgress), failCount=\(self.failCount)")
            return
        }

        logger.info("passiveAuth: arming (biometry=\(self.biometryAvailable), suspended=\(self.passiveAuthSuspended), failCount=\(self.failCount))")
        let generation = passiveAuthGeneration
        secureInputBeforeArm = IsSecureEventInputEnabled()
        passiveEvaluationInFlight = true
        passiveAuthLive = true
        passiveAuthTask = Task { @MainActor [weak self] in
            await self?.runPassiveAuth(generation: generation)
        }
    }

    /// Sleep and session switches both invalidate the evaluation and can change enrolment
    /// under us, so re-sample availability before arming again.
    private func armPassiveAuthAfterInterruption() {
        biometryAvailable = authenticator.isBiometryAvailable
        armPassiveAuth()
    }

    /// Cancelling the Swift task does not stop the evaluation — the LAContext has to be
    /// invalidated too, or the sensor stays armed after the overlay is gone.
    /// `endingSession` distinguishes a handoff from a teardown: the button path and a
    /// session switch disarm and re-arm within the same lock, and must leave the published
    /// flag alone, while unlocking really does end the path.
    private func disarmPassiveAuth(endingSession: Bool = false) {
        passiveAuthGeneration &+= 1
        passiveEvaluationInFlight = false
        if endingSession { passiveAuthLive = false }
        guard let task = passiveAuthTask else { return }
        passiveAuthTask = nil
        task.cancel()
        authenticator.cancelPending()
    }

    private func runPassiveAuth(generation: Int) async {
        let result = await authenticator.armBiometrics()
        logger.info("passiveAuth: ended authenticated=\(result.authenticated) error=\(result.errorCode.map { String($0.rawValue) } ?? "nil") generation=\(generation)/\(self.passiveAuthGeneration) state=\(String(describing: self.state))")
        guard generation == passiveAuthGeneration, state == .locked else { return }
        passiveEvaluationInFlight = false

        switch PassiveAuthPolicy.outcome(result) {
        case .unlock:
            logger.info("passiveAuth: match — unlocking")
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            unlockSucceeded = true
            try? await Task.sleep(nanoseconds: Constants.Timing.unlockSuccessAnimNs)
            guard generation == passiveAuthGeneration else { return }
            unlock()

        case .rearmImmediately:
            // Deliberately silent: no haptic, no lastError, no attempt spent. A rejected
            // finger may well be a bag strap, and the user who meant it can simply touch
            // again — the sensor is live before their hand is back.
            armPassiveAuth()

        case .rearmOnNextTick:
            break

        case .standDown:
            passiveAuthSuspended = true
            passiveAuthLive = false
        }
    }

    /// Rides the one-second lock tick, which is already running for the elapsed clock.
    private func tickPassiveAuth() {
        guard state == .locked else { return }

        if passiveEvaluationInFlight {
            // Secure input hides keystrokes from event taps (the #10 bypass), so an armed
            // sensor that turned it on would silently kill the unlock hotkey — the primary
            // way out. Measurement says the biometric prompt leaves it alone, unlike the
            // password sheet, but one early sample is the shape that fails worst: a later
            // flip on a slower machine or a future OS would go unnoticed for the whole
            // session with no recovery. So keep looking for as long as we stay armed.
            if !secureInputBeforeArm, IsSecureEventInputEnabled() {
                logger.warning("Secure input came up while Touch ID was armed — standing down, hotkey unlock takes priority")
                passiveAuthSuspended = true
                disarmPassiveAuth(endingSession: true)
            }
            return
        }

        logger.info("passiveAuth: tick found nothing armed — re-arming")
        // Nothing armed while the screen is still covered: an evaluation the system
        // cancelled or expired under us, including after hours of being armed. Re-arming
        // from the tick rather than from the outcome caps retries at one a second, so an
        // ending that repeats without user input cannot spin.
        armPassiveAuth()
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
