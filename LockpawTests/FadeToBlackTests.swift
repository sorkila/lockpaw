import XCTest
@testable import Lockpaw

final class FadeToBlackTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: FadeToBlack.enabledKey)
        UserDefaults.standard.removeObject(forKey: FadeToBlack.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FadeToBlack.enabledKey)
        UserDefaults.standard.removeObject(forKey: FadeToBlack.storageKey)
        super.tearDown()
    }

    // MARK: - Defaults & resolution

    func testDisabledByDefault() {
        XCTAssertFalse(FadeToBlack.defaultEnabled)
        XCTAssertNil(FadeToBlack.currentTimeout)  // unset defaults → feature off
    }

    func testDefaultDelayIsFiveMinutes() {
        XCTAssertEqual(FadeToBlack.defaultValue, FadeToBlack.afterFiveMinutes.rawValue)
    }

    func testResolvedRoundTripsAllCases() {
        for delay in FadeToBlack.allCases {
            XCTAssertEqual(FadeToBlack.resolved(from: delay.rawValue), delay)
        }
    }

    /// Unknown and legacy values (the pre-checkbox build stored "off" /
    /// "afterFifteenMinutes" under the same key) fall back to the default delay.
    func testResolvedFallsBackToDefaultDelay() {
        XCTAssertEqual(FadeToBlack.resolved(from: "garbage"), .afterFiveMinutes)
        XCTAssertEqual(FadeToBlack.resolved(from: "off"), .afterFiveMinutes)
        XCTAssertEqual(FadeToBlack.resolved(from: "afterFifteenMinutes"), .afterFiveMinutes)
    }

    /// Pins the fallback and defaultValue together — they must never drift apart.
    func testFallbackAgreesWithDefaultValue() {
        XCTAssertEqual(FadeToBlack.resolved(from: "garbage").rawValue, FadeToBlack.defaultValue)
    }

    // MARK: - Presentation values

    func testTimeoutMapping() {
        XCTAssertEqual(FadeToBlack.afterOneMinute.timeout, 60)
        XCTAssertEqual(FadeToBlack.afterFiveMinutes.timeout, 300)
        XCTAssertEqual(FadeToBlack.afterTenMinutes.timeout, 600)
    }

    func testDisplayNames() {
        XCTAssertEqual(FadeToBlack.afterOneMinute.displayName, "1 min")
        XCTAssertEqual(FadeToBlack.afterFiveMinutes.displayName, "5 min")
        XCTAssertEqual(FadeToBlack.afterTenMinutes.displayName, "10 min")
    }

    /// allCases drives the Settings segmented control — the order is user-facing.
    func testAllCasesOrder() {
        XCTAssertEqual(FadeToBlack.allCases, [.afterOneMinute, .afterFiveMinutes, .afterTenMinutes])
    }

    // MARK: - Effective timeout (checkbox × delay)

    func testCurrentTimeoutNilWhileDisabledEvenWithDelayStored() {
        UserDefaults.standard.set(FadeToBlack.afterOneMinute.rawValue, forKey: FadeToBlack.storageKey)
        XCTAssertNil(FadeToBlack.currentTimeout)
    }

    func testCurrentTimeoutUsesStoredDelayWhenEnabled() {
        UserDefaults.standard.set(true, forKey: FadeToBlack.enabledKey)
        UserDefaults.standard.set(FadeToBlack.afterTenMinutes.rawValue, forKey: FadeToBlack.storageKey)
        XCTAssertEqual(FadeToBlack.currentTimeout, 600)
    }

    func testCurrentTimeoutDefaultsToFiveMinutesWhenEnabledWithoutDelay() {
        UserDefaults.standard.set(true, forKey: FadeToBlack.enabledKey)
        XCTAssertEqual(FadeToBlack.currentTimeout, 300)
    }
}
