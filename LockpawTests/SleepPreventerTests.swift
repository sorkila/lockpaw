import XCTest
@testable import Lockpaw

final class SleepPreventerTests: XCTestCase {
    func testInitialState() {
        XCTAssertFalse(SleepPreventer().isActive)
    }

    func testPreventSleepActivates() {
        let p = SleepPreventer()
        p.preventSleep()
        XCTAssertTrue(p.isActive)
        p.allowSleep()
    }

    func testAllowSleepDeactivates() {
        let p = SleepPreventer()
        p.preventSleep()
        p.allowSleep()
        XCTAssertFalse(p.isActive)
    }

    func testPreventSleepIsIdempotent() {
        let p = SleepPreventer()
        p.preventSleep()
        p.preventSleep()
        XCTAssertTrue(p.isActive)
        p.allowSleep()
    }

    func testAllowSleepWithoutPreventIsSafe() {
        let p = SleepPreventer()
        p.allowSleep()
        XCTAssertFalse(p.isActive)
    }
}
