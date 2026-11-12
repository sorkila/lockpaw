import AppKit
import CoreGraphics
import Sparkle
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "App")

/// Runs a downloaded update at a quiet moment instead of waiting for Lockpaw to quit (see
/// `QuietInstallPolicy`). Checks once a minute while an update is pending, and once more
/// shortly after a wake, macOS unlock or user switch back. The decision and the one-shot
/// bookkeeping live in `QuietInstallScheduler`; this class only supplies timers, session
/// notifications and the live readings.
@MainActor
final class QuietInstallController {
    private let scheduler: QuietInstallScheduler
    private var timer: Timer?
    private var sessionWork: DispatchWorkItem?
    private var observers: [(NotificationCenter, Any)] = []

    init(updater: SPUUpdater) {
        scheduler = QuietInstallScheduler(environment: LiveQuietInstallEnvironment(updater: updater)) { message in
            logger.notice("\(message, privacy: .public)")
        }
    }

    /// Sparkle's `willInstallUpdateOnQuit`: keep the block and start watching.
    func offer(version: String, install: @escaping () -> Void) {
        scheduler.offer(version: version, install: install)
        startWatching()
        scheduler.evaluate()
        stopWatchingIfDone()
    }

    func clear(_ why: String) {
        scheduler.clear(why)
        stopWatchingIfDone()
    }

    private func startWatching() {
        if timer == nil {
            let timer = Timer(timeInterval: Constants.Timing.quietInstallCheckInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let returns: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (distributed, .systemScreenUnlocked),
        ]
        observers = returns.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionReturned() }
            })
        }
    }

    private func stopWatchingIfDone() {
        guard !scheduler.isWaiting else { return }
        timer?.invalidate()
        timer = nil
        sessionWork?.cancel()
        sessionWork = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func tick() {
        scheduler.evaluate()
        stopWatchingIfDone()
    }

    /// Wake and unlock often arrive together; one evaluation once the session has settled.
    private func sessionReturned() {
        scheduler.noteSessionReturned()
        sessionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.sessionWork = nil
                self?.tick()
            }
        }
        sessionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + QuietInstallPolicy.sessionReturnSettle + 1, execute: work)
    }
}

/// The real readings behind `QuietInstallPolicy.Snapshot`.
@MainActor
private final class LiveQuietInstallEnvironment: QuietInstallEnvironment {
    private weak var updater: SPUUpdater?

    init(updater: SPUUpdater) { self.updater = updater }

    var now: Date { Date() }

    /// The Settings switch: Sparkle reads installs as off while checks are off.
    var installsAutomatically: Bool {
        guard let updater else { return false }
        return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    var lockState: LockState { LockStatus.shared.state }
    var passwordEntryOpen: Bool { LockStatus.shared.passwordEntryOpen }
    var authenticating: Bool { LockStatus.shared.authenticating }
    var lidSleepHeld: Bool { LidSleepController.shared.sleepHeld }
    var macOSLocked: Bool { SystemSession.isScreenLocked }
    var lockpawUnlockedAt: Date? { LockStatus.shared.unlockedAt }

    /// Any input event in this login session (`kCGAnyInputEventType`). Needs no permission.
    var secondsIdle: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
