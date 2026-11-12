import Foundation

/// When a downloaded update may install and relaunch Lockpaw on its own. Pure, so every
/// safety condition is unit-tested.
///
/// With automatic installs on, Sparkle 2 downloads an update and then waits for the app to
/// quit, installing silently without a relaunch, and runs no more update checks until then.
/// Lockpaw rarely quits, so a Mac could sit on a downloaded update for days. Lockpaw takes
/// the install over (`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`) and
/// runs it at a quiet moment instead: nobody at the keyboard for a while, or just after the
/// Mac comes back from sleep, a macOS lock or a user switch.
///
/// Never while the screen is guarded: a relaunch would take the cover down. Never while the
/// lid-closed helper holds sleep off, the lock-screen password field is open or a password
/// is being checked (all of which also mean "guarded" today; they are checked on their own
/// so a later change to the lock flow can't open a gap here).
enum QuietInstallPolicy {
    /// Nobody has touched the keyboard, pointer or trackpad for this long.
    static let idleThreshold: TimeInterval = 10 * 60
    /// After Lockpaw itself unlocks: the cover is still fading and the user is right there,
    /// maybe about to lock again.
    static let settleAfterUnlock: TimeInterval = 60
    /// After a wake, macOS unlock or user switch back: let the session settle (Lockpaw
    /// rebuilds its hotkey tap then too) before relaunching.
    static let sessionReturnSettle: TimeInterval = 10
    /// How long after the session came back that still counts as "just came back".
    static let sessionReturnWindow: TimeInterval = 2 * 60

    struct Snapshot: Equatable {
        /// Settings → About → install automatically (which needs checks on as well).
        var installsAutomatically: Bool
        var lockState: LockState
        var passwordEntryOpen: Bool
        var authenticating: Bool
        var lidSleepHeld: Bool
        /// The macOS lock screen is up, read from the window server.
        var macOSLocked: Bool
        /// Seconds since the last keyboard, pointer or trackpad event in this session.
        var secondsIdle: TimeInterval
        /// nil when Lockpaw hasn't been unlocked since launch.
        var secondsSinceLockpawUnlock: TimeInterval?
        /// nil when the session hasn't come back from sleep, a lock or a switch while an
        /// update was pending.
        var secondsSinceSessionReturn: TimeInterval?
    }

    enum Reason: Equatable {
        case idle
        case sessionReturned
    }

    enum Hold: Equatable {
        case installsOff
        case guarded
        case passwordEntry
        case lidSleepHeld
        case justUnlocked
        case inUse
    }

    enum Decision: Equatable {
        case install(Reason)
        case wait(Hold)
    }

    static func decide(_ s: Snapshot) -> Decision {
        guard s.installsAutomatically else { return .wait(.installsOff) }
        guard s.lockState == .unlocked else { return .wait(.guarded) }
        guard !s.passwordEntryOpen, !s.authenticating else { return .wait(.passwordEntry) }
        guard !s.lidSleepHeld else { return .wait(.lidSleepHeld) }
        if let sinceUnlock = s.secondsSinceLockpawUnlock, sinceUnlock < settleAfterUnlock {
            return .wait(.justUnlocked)
        }
        if s.secondsIdle >= idleThreshold { return .install(.idle) }
        // Back from sleep or a lock only counts once macOS is really unlocked: the
        // notification can be posted by any process, the window server can't.
        if let sinceReturn = s.secondsSinceSessionReturn, !s.macOSLocked,
           sinceReturn >= sessionReturnSettle, sinceReturn <= sessionReturnWindow {
            return .install(.sessionReturned)
        }
        return .wait(.inUse)
    }
}

/// What the scheduler reads each time it decides. The app reads Sparkle, `LockStatus`,
/// the lid-closed controller, the window server and the HID idle timer; tests use a fake.
@MainActor
protocol QuietInstallEnvironment: AnyObject {
    var now: Date { get }
    var installsAutomatically: Bool { get }
    var lockState: LockState { get }
    var passwordEntryOpen: Bool { get }
    var authenticating: Bool { get }
    var lidSleepHeld: Bool { get }
    var macOSLocked: Bool { get }
    var secondsIdle: TimeInterval { get }
    /// When Lockpaw last went from guarded to unlocked, nil if never this run.
    var lockpawUnlockedAt: Date? { get }
}

/// Holds Sparkle's install-and-relaunch block for one pending update and fires it once, at
/// the first moment `QuietInstallPolicy` allows. Timer-free: `QuietInstallController` calls
/// `evaluate()` on a timer and after the session comes back.
@MainActor
final class QuietInstallScheduler {
    private let environment: QuietInstallEnvironment
    private let log: (String) -> Void
    private var install: (() -> Void)?
    private(set) var pendingVersion: String?
    private(set) var attempted = false
    private var sessionReturnedAt: Date?
    private var lastHold: QuietInstallPolicy.Hold?

    init(environment: QuietInstallEnvironment, log: @escaping (String) -> Void = { _ in }) {
        self.environment = environment
        self.log = log
    }

    /// An update is waiting and nothing has been tried for it yet.
    var isWaiting: Bool { install != nil && !attempted }

    /// Sparkle downloaded and prepared an update. A new offer replaces an older one.
    func offer(version: String, install: @escaping () -> Void) {
        self.install = install
        pendingVersion = version
        attempted = false
        sessionReturnedAt = nil
        lastHold = nil
        log("Update \(version) is ready; installing at a quiet moment")
    }

    /// Wake, macOS unlock or a user switch back. Repeats (they often arrive together)
    /// just move the mark.
    func noteSessionReturned() {
        guard isWaiting else { return }
        sessionReturnedAt = environment.now
    }

    /// The update installed, or Sparkle gave up on it. The block is never used again.
    func clear(_ why: String) {
        guard install != nil else { return }
        log("Pending update \(pendingVersion ?? "?") cleared: \(why)")
        install = nil
        pendingVersion = nil
        sessionReturnedAt = nil
        lastHold = nil
    }

    func snapshot() -> QuietInstallPolicy.Snapshot {
        let now = environment.now
        return QuietInstallPolicy.Snapshot(
            installsAutomatically: environment.installsAutomatically,
            lockState: environment.lockState,
            passwordEntryOpen: environment.passwordEntryOpen,
            authenticating: environment.authenticating,
            lidSleepHeld: environment.lidSleepHeld,
            macOSLocked: environment.macOSLocked,
            secondsIdle: environment.secondsIdle,
            secondsSinceLockpawUnlock: environment.lockpawUnlockedAt.map { now.timeIntervalSince($0) },
            secondsSinceSessionReturn: sessionReturnedAt.map { now.timeIntervalSince($0) }
        )
    }

    /// Installs if now is a quiet moment. Returns whether the install block was called.
    @discardableResult
    func evaluate() -> Bool {
        guard let install, !attempted else { return false }
        switch QuietInstallPolicy.decide(snapshot()) {
        case .wait(let hold):
            if hold != lastHold {
                lastHold = hold
                log("Update \(pendingVersion ?? "?") waits: \(hold)")
            }
            return false
        case .install(let reason):
            // Read everything again right before relaunching: nothing may have changed
            // between the decision and the call.
            guard case .install = QuietInstallPolicy.decide(snapshot()) else { return false }
            attempted = true
            self.install = nil
            log("Installing update \(pendingVersion ?? "?") and relaunching (\(reason))")
            install()
            return true
        }
    }
}
