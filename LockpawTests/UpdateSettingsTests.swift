import XCTest
@testable import Lockpaw

/// Settings → About's two update switches, against a fake Sparkle.
final class UpdateSettingsTests: XCTestCase {
    /// Behaves like Sparkle 2.10 (`SPUUpdaterSettings`): the install preference reads as off
    /// while checks are off, and a write to it while checks are off is dropped.
    private final class FakeAutoUpdate: AutoUpdateSettings {
        var automaticallyChecksForUpdates: Bool
        /// What Sparkle keeps in defaults as `SUAutomaticallyUpdate`.
        private(set) var storedInstalls: Bool
        var automaticallyDownloadsUpdates: Bool {
            get { automaticallyChecksForUpdates && storedInstalls }
            set { if automaticallyChecksForUpdates { storedInstalls = newValue } }
        }
        init(checks: Bool, downloads: Bool) {
            automaticallyChecksForUpdates = checks
            storedInstalls = downloads
        }
    }

    private func model(checks: Bool, downloads: Bool) -> (UpdateCheckViewModel, FakeAutoUpdate) {
        let fake = FakeAutoUpdate(checks: checks, downloads: downloads)
        let model = UpdateCheckViewModel()
        model.attach(autoUpdate: fake)
        return (model, fake)
    }

    func testReadsSparklesPreferencesOnAttach() {
        let (model, _) = model(checks: true, downloads: true)
        XCTAssertTrue(model.checksAutomatically)
        XCTAssertTrue(model.downloadsAutomatically)
    }

    func testInstallsShowOffWhileChecksAreOff() {
        let (model, _) = model(checks: false, downloads: true)
        XCTAssertFalse(model.checksAutomatically)
        XCTAssertFalse(model.downloadsAutomatically)
    }

    func testTurningChecksOffAlsoTurnsInstallsOff() {
        let (model, fake) = model(checks: true, downloads: true)
        model.setChecksAutomatically(false)
        XCTAssertFalse(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(fake.storedInstalls)
        XCTAssertFalse(model.downloadsAutomatically)
    }

    /// Found on hardware in 1.7.3 (28): installs only looked off, and came back with checks.
    func testInstallsStayOffWhenChecksComeBackOn() {
        let (model, fake) = model(checks: true, downloads: true)
        model.setChecksAutomatically(false)
        model.setChecksAutomatically(true)
        XCTAssertTrue(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(fake.automaticallyDownloadsUpdates)
        XCTAssertFalse(model.downloadsAutomatically)
    }

    func testTurningChecksOnLeavesInstallsAlone() {
        let (model, fake) = model(checks: false, downloads: false)
        model.setChecksAutomatically(true)
        XCTAssertTrue(fake.automaticallyChecksForUpdates)
        XCTAssertFalse(fake.automaticallyDownloadsUpdates)
    }

    func testInstallsCannotTurnOnWithoutChecks() {
        let (model, fake) = model(checks: false, downloads: false)
        model.setDownloadsAutomatically(true)
        XCTAssertFalse(fake.automaticallyDownloadsUpdates)
        XCTAssertFalse(model.downloadsAutomatically)
    }

    func testInstallsToggleWhileChecksAreOn() {
        let (model, fake) = model(checks: true, downloads: false)
        model.setDownloadsAutomatically(true)
        XCTAssertTrue(fake.automaticallyDownloadsUpdates)
        model.setDownloadsAutomatically(false)
        XCTAssertFalse(fake.automaticallyDownloadsUpdates)
    }

    func testRefreshPicksUpChangesSparkleMadeItself() {
        let (model, fake) = model(checks: false, downloads: false)
        fake.automaticallyChecksForUpdates = true
        model.refreshAutoUpdate()
        XCTAssertTrue(model.checksAutomatically)
    }

    func testNothingHappensBeforeSparkleIsAttached() {
        let model = UpdateCheckViewModel()
        model.setChecksAutomatically(true)
        XCTAssertFalse(model.checksAutomatically)
    }
}
