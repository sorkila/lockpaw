import XCTest
@testable import Lockpaw

/// Energy over a multi-hour lock (review point 2): when the shared Aerial player runs.
final class WallpaperMotionTests: XCTestCase {
    private func plays(
        _ motion: WallpaperMotion = .pluggedIn, reduceMotion: Bool = false, onBattery: Bool = false,
        lowPower: Bool = false, layers: Int = 1
    ) -> Bool {
        WallpaperPlaybackPolicy.shouldPlay(.init(
            motion: motion, reduceMotion: reduceMotion, onBattery: onBattery,
            lowPowerMode: lowPower, visibleLayers: layers
        ))
    }

    func testPluggedInIsTheDefaultAndUnknownValuesFallBackToIt() {
        XCTAssertEqual(WallpaperMotion.resolved(from: WallpaperMotion.defaultValue), .pluggedIn)
        XCTAssertEqual(WallpaperMotion.resolved(from: nil), .pluggedIn)
        XCTAssertEqual(WallpaperMotion.resolved(from: "loops"), .pluggedIn)
        XCTAssertEqual(WallpaperMotion.resolved(from: "never"), .never)
    }

    func testPluggedInPausesOnBatteryAndInLowPowerMode() {
        XCTAssertTrue(plays(.pluggedIn))
        XCTAssertFalse(plays(.pluggedIn, onBattery: true))
        XCTAssertFalse(plays(.pluggedIn, lowPower: true))
    }

    func testAlwaysIgnoresPower() {
        XCTAssertTrue(plays(.always, onBattery: true, lowPower: true))
    }

    func testNeverHoldsTheFrame() {
        XCTAssertFalse(plays(.never))
    }

    func testReduceMotionNeverPlays() {
        for motion in WallpaperMotion.allCases {
            XCTAssertFalse(plays(motion, reduceMotion: true), motion.rawValue)
        }
    }

    func testNothingOnScreenMeansNoDecode() {
        // Faded to black (the lock UI unmounted) or the overlay gone: no layer shows the clip.
        for motion in WallpaperMotion.allCases {
            XCTAssertFalse(plays(motion, layers: 0), motion.rawValue)
        }
        XCTAssertTrue(plays(.always, layers: 3), "one shared player however many screens show it")
    }
}
