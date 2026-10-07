import XCTest
@testable import Lockpaw

final class SeasonalSkinTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }

    private func season(_ year: Int, _ month: Int, _ day: Int) -> SeasonalSkin? {
        SeasonalSkin.current(on: calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!, calendar: calendar)
    }

    func testHalloweenWindow() {
        XCTAssertNil(season(2026, 10, 23))
        XCTAssertEqual(season(2026, 10, 24), .halloween)
        XCTAssertEqual(season(2026, 10, 31), .halloween)
        XCTAssertEqual(season(2026, 11, 1), .halloween)
        XCTAssertNil(season(2026, 11, 2))
    }

    func testWinterWindow() {
        XCTAssertNil(season(2026, 11, 30))
        XCTAssertEqual(season(2026, 12, 1), .winter)
        XCTAssertEqual(season(2026, 12, 31), .winter)
        XCTAssertEqual(season(2027, 1, 1), .winter)
        XCTAssertNil(season(2027, 1, 2))
    }

    func testLunarNewYearWindow() {
        // 2027: 6 February. Two days before through day 15.
        XCTAssertNil(season(2027, 2, 3))
        XCTAssertEqual(season(2027, 2, 4), .lunarNewYear)
        XCTAssertEqual(season(2027, 2, 20), .lunarNewYear)
        XCTAssertNil(season(2027, 2, 21))
        // 2028 falls in January.
        XCTAssertEqual(season(2028, 1, 26), .lunarNewYear)
    }

    func testMidsummerIsTheFridayBetween19And25June() {
        // 2027: Midsummer Eve is Friday 25 June.
        XCTAssertEqual(calendar.component(.day, from: SeasonalSkin.midsummerEve(year: 2027, calendar: calendar)!), 25)
        XCTAssertNil(season(2027, 6, 23))
        XCTAssertEqual(season(2027, 6, 24), .midsummer)
        XCTAssertEqual(season(2027, 6, 27), .midsummer)
        XCTAssertNil(season(2027, 6, 28))
        // 2026: Friday 19 June.
        XCTAssertEqual(calendar.component(.day, from: SeasonalSkin.midsummerEve(year: 2026, calendar: calendar)!), 19)
    }

    func testOrdinaryDayHasNoSeason() {
        XCTAssertNil(season(2026, 10, 7))
        XCTAssertNil(season(2027, 4, 15))
    }

    func testLunarTableCoversTheNextDecade() {
        for year in 2026...2035 { XCTAssertNotNil(SeasonalSkin.lunarNewYearDates[year], "\(year)") }
    }
}

final class SupportAskTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(firstUseDaysAgo: Double = 30, lastAskedDaysAgo: Double? = nil, pendingDaysAgo: Double? = nil, never: Bool = false) -> SupportAsk.State {
        SupportAsk.State(
            firstUse: now.addingTimeInterval(-firstUseDaysAgo * day),
            lastAsked: lastAskedDaysAgo.map { now.addingTimeInterval(-$0 * day) },
            pendingSince: pendingDaysAgo.map { now.addingTimeInterval(-$0 * day) },
            dismissedForever: never
        )
    }

    func testRaisesAfterTwoWeeksForNonSupporters() {
        XCTAssertTrue(SupportAsk.shouldRaise(after: state(), isSupporter: false, now: now))
        XCTAssertFalse(SupportAsk.shouldRaise(after: state(firstUseDaysAgo: 13), isSupporter: false, now: now))
    }

    func testNeverForSupportersOrAfterDontAskAgain() {
        XCTAssertFalse(SupportAsk.shouldRaise(after: state(), isSupporter: true, now: now))
        XCTAssertFalse(SupportAsk.shouldRaise(after: state(never: true), isSupporter: false, now: now))
    }

    func testAtMostOnceAYear() {
        XCTAssertFalse(SupportAsk.shouldRaise(after: state(firstUseDaysAgo: 800, lastAskedDaysAgo: 200), isSupporter: false, now: now))
        XCTAssertTrue(SupportAsk.shouldRaise(after: state(firstUseDaysAgo: 800, lastAskedDaysAgo: 366), isSupporter: false, now: now))
    }

    func testAPendingAskShowsForAWeekThenCountsAsAsked() {
        XCTAssertTrue(SupportAsk.isShowing(state(pendingDaysAgo: 3), isSupporter: false, now: now))
        XCTAssertFalse(SupportAsk.isShowing(state(pendingDaysAgo: 8), isSupporter: false, now: now))
        let expired = SupportAsk.expiring(state(pendingDaysAgo: 8), now: now)
        XCTAssertNil(expired.pendingSince)
        XCTAssertEqual(expired.lastAsked, now.addingTimeInterval(-8 * day))
    }

    func testBecomingASupporterHidesAPendingAsk() {
        XCTAssertFalse(SupportAsk.isShowing(state(pendingDaysAgo: 1), isSupporter: true, now: now))
    }
}

final class SupporterLicenceTests: XCTestCase {
    func testRequestCarriesOnlyKeyAndOrganization() throws {
        let request = try SupporterLicence.validationRequest(key: "  ABC-123  ", organizationID: "org")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, SupporterLicence.validateURL)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["key": "ABC-123", "organization_id": "org"])
    }

    func testNoStoreNoRequest() {
        XCTAssertThrowsError(try SupporterLicence.validationRequest(key: "ABC", organizationID: ""))
        XCTAssertThrowsError(try SupporterLicence.validationRequest(key: "   ", organizationID: "org"))
    }

    func testOutcomes() {
        let granted = Data(#"{"status":"granted"}"#.utf8)
        XCTAssertEqual(SupporterLicence.outcome(status: 200, body: granted), .valid)
        if case .rejected = SupporterLicence.outcome(status: 200, body: Data(#"{"status":"revoked"}"#.utf8)) {} else { XCTFail() }
        if case .rejected = SupporterLicence.outcome(status: 404, body: nil) {} else { XCTFail() }
        if case .unavailable = SupporterLicence.outcome(status: nil, body: nil) {} else { XCTFail() }
        if case .unavailable = SupporterLicence.outcome(status: 500, body: nil) {} else { XCTFail() }
    }
}
