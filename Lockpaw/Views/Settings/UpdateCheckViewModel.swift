import AppKit
import Sparkle

/// Sparkle's two automatic-update preferences. `SPUUpdater` is the real one; tests use a fake.
protocol AutoUpdateSettings: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
}

extension SPUUpdater: AutoUpdateSettings {}

/// Sparkle's state for the Updates rows in Settings → About. Only a check the user started
/// reports back; background checks stay silent. The two switches write straight to Sparkle,
/// which stores them in Lockpaw's defaults, so the `defaults` keys and Sparkle's own first-run
/// question keep working.

final class UpdateCheckViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var canCheckForUpdates = false
    @Published var isChecking = false
    @Published var updateStatus: UpdateStatus?
    /// Mirrors of Sparkle's preferences, refreshed whenever Settings → About appears.
    @Published private(set) var checksAutomatically = false
    @Published private(set) var downloadsAutomatically = false

    enum UpdateStatus {
        case upToDate
        case available(String)
        case error(String)
    }

    weak var updater: SPUUpdater?
    private weak var autoUpdate: AutoUpdateSettings?
    private var userInitiated = false
    /// Installs a downloaded update at a quiet moment instead of waiting for a quit.
    private var quietInstall: QuietInstallController?

    func bind(to updater: SPUUpdater) {
        self.updater = updater
        quietInstall = MainActor.assumeIsolated { QuietInstallController(updater: updater) }
        attach(autoUpdate: updater)
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func attach(autoUpdate settings: AutoUpdateSettings) {
        autoUpdate = settings
        refreshAutoUpdate()
    }

    /// Re-reads Sparkle, which may have changed a preference itself (its first-run question).
    func refreshAutoUpdate() {
        checksAutomatically = autoUpdate?.automaticallyChecksForUpdates ?? false
        downloadsAutomatically = checksAutomatically && (autoUpdate?.automaticallyDownloadsUpdates ?? false)
    }

    /// Turning checks off also turns automatic installs off, so nothing installs unasked.
    /// Installs go off first: Sparkle ignores a write to the install preference while checks
    /// are off, so the other order leaves it stored as on and it returns with the next check.
    func setChecksAutomatically(_ on: Bool) {
        guard let autoUpdate else { return }
        if !on { autoUpdate.automaticallyDownloadsUpdates = false }
        autoUpdate.automaticallyChecksForUpdates = on
        refreshAutoUpdate()
    }

    /// Automatic installs only make sense while Lockpaw checks on its own.
    func setDownloadsAutomatically(_ on: Bool) {
        guard let autoUpdate, !on || autoUpdate.automaticallyChecksForUpdates else { return }
        autoUpdate.automaticallyDownloadsUpdates = on
        refreshAutoUpdate()
    }

    func checkForUpdates() {
        guard let updater else { return }
        NSApp.activate(ignoringOtherApps: true)
        userInitiated = true
        isChecking = true
        updateStatus = nil
        updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard userInitiated else { return }
        userInitiated = false
        isChecking = false
        updateStatus = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard userInitiated else { return }
        userInitiated = false
        isChecking = false
        updateStatus = .upToDate
    }

    /// With automatic installs on, Sparkle downloads an update and then waits for Lockpaw to
    /// quit, running no more checks until then. Returning true takes the install over: the
    /// block installs and relaunches with no UI, and `QuietInstallController` calls it at a
    /// quiet moment (never while the screen is guarded). Sparkle still installs on quit if
    /// that comes first.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        guard let quietInstall else { return false }
        let version = item.displayVersionString
        MainActor.assumeIsolated { quietInstall.offer(version: version, install: immediateInstallHandler) }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let quietInstall = quietInstall
        MainActor.assumeIsolated { quietInstall?.clear("installing") }
    }

    /// The cycle that offered the block is over (an abort or a finished cycle), so the
    /// block would do nothing now.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let quietInstall = quietInstall
        MainActor.assumeIsolated { quietInstall?.clear("update cycle ended") }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let quietInstall = quietInstall
        MainActor.assumeIsolated { quietInstall?.clear("aborted: \(error.localizedDescription)") }
        guard userInitiated else { return }
        userInitiated = false
        isChecking = false
        updateStatus = .error(error.localizedDescription)
    }
}
