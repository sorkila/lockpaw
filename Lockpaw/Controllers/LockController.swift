import Foundation
import Combine
import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "LockController")

@MainActor
class LockController: ObservableObject {
    @Published private(set) var state: LockState = .unlocked
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

    private let overlayManager = OverlayWindowManager()
    private let inputBlocker = InputBlocker()
    private let authenticator = Authenticator()
    private let sleepPreventer = SleepPreventer()

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
        guard overlayManager.showOverlay(contentFactory: { [weak self] index, isPrimary in
            guard let self else { return AnyView(Color.black) }
            if isPrimary || mirrorAll {
                return AnyView(LockScreenView(
                    controller: self,
                    screenRole: .primary,
                    phaseOffset: mirrorAll ? 0 : CGFloat(index) * 0.15
                ))
            } else {
                return AnyView(AmbientScreenView(
                    phaseOffset: CGFloat(index) * 0.15
                ))
            }
        }) else {
            logger.error("Lock failed — no screens available for overlay")
            sleepPreventer.allowSleep()
            transitionTo(.unlocked)
            lastError = "No screens available"
            scheduleErrorClear()
            return
        }

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
