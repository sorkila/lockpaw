import AppKit
import os.log

private let logger = Logger(subsystem: "com.eriknielsen.lockpaw", category: "ClaudePresence")

/// Keeps `ClaudePresence.markerURL` present while someone is at the Mac, so Claude Code
/// (with `CLAUDE_CLIENT_PRESENCE_FILE` set) skips its phone pushes then and sends them once
/// you lock or walk away. Every decision goes through `ClaudePresence.reduce`; this class
/// only turns system notifications into events and makes the file match.
///
/// Always on and harmless on its own: an empty file nothing reads unless the user also sets
/// the env var. Stale-file edge: if Lockpaw crashes while unlocked, the file stays and
/// pushes stay quiet until the next launch, which rewrites it from the real state (and
/// launch at login runs at every login).
@MainActor
final class ClaudePresenceMarker {
    static let shared = ClaudePresenceMarker(url: ClaudePresence.markerURL)

    let url: URL
    private(set) var signals = ClaudePresence.Signals()
    private var observers: [(NotificationCenter, Any)] = []

    init(url: URL) {
        self.url = url
    }

    /// Called once from `applicationDidFinishLaunching`.
    func start() {
        handle(.launched(sessionLocked: SystemSession.isScreenLocked))
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, () -> ClaudePresence.Event)] = [
            (workspace, NSWorkspace.willSleepNotification, { .willSleep }),
            (workspace, NSWorkspace.didWakeNotification, { .didWake(sessionLocked: SystemSession.isScreenLocked) }),
            (workspace, NSWorkspace.screensDidSleepNotification, { .displaysDidSleep }),
            (workspace, NSWorkspace.screensDidWakeNotification, { .displaysDidWake(sessionLocked: SystemSession.isScreenLocked) }),
            (distributed, .systemScreenLocked, { .macOSLockHint }),
            (distributed, .systemScreenUnlocked, { .macOSUnlockHint(sessionLocked: SystemSession.isScreenLocked) }),
        ]
        observers = events.map { center, name, event in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(event()) }
            })
        }
    }

    /// `LockController` reports every state change here.
    func lockStateChanged(_ state: LockState) {
        handle(.lockpawState(unlocked: state == .unlocked))
    }

    func handle(_ event: ClaudePresence.Event) {
        signals = ClaudePresence.reduce(signals, event)
        apply()
    }

    /// Make the file match. Checked against the disk each time, so a file someone else
    /// removed comes back on the next event. Create is an atomic write of nothing.
    private func apply() {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        if signals.isPresent, !exists {
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url, options: .atomic)
            } catch {
                logger.error("Couldn't create the presence marker: \(error.localizedDescription, privacy: .public)")
            }
        } else if !signals.isPresent, exists {
            do {
                try fm.removeItem(at: url)
            } catch {
                logger.error("Couldn't remove the presence marker: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
