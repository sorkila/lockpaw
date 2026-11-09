import XCTest
@testable import Lockpaw

/// Settings → About's two update switches, against a fake Sparkle.
final class UpdateSettingsTests: XCTestCase {
    private final class FakeAutoUpdate: AutoUpdateSettings {
        var automaticallyChecksForUpdates: Bool
        var automaticallyDownloadsUpdates: Bool
        init(checks: Bool, downloads: Bool) {
            automaticallyChecksForUpdates = checks
            automaticallyDownloadsUpdates = downloads
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
