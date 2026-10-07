import Foundation

/// Seasonal variants of the Dog and Cat mascots — a supporter thank-you, on by default for
/// supporters, with an off switch. Pure date logic, unit-tested; an asset that doesn't exist
/// yet simply means the plain mascot shows.
enum SeasonalSkin: String, CaseIterable {
    case halloween
    case winter
    case lunarNewYear = "lunarnewyear"
    case midsummer

    static let enabledKey = "seasonalMascots"

    /// The season covering `date`, if any. Windows don't overlap.
    static func current(on date: Date, calendar: Calendar = .current) -> SeasonalSkin? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let today = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }

        // Halloween: the week leading up to it, through All Saints' Day.
        if (month == 10 && day >= 24) || (month == 11 && day == 1) { return .halloween }
        // Winter holidays: all of December, plus New Year's Day.
        if month == 12 || (month == 1 && day == 1) { return .winter }

        // Lunar New Year: two days before, through the Lantern Festival (day 15).
        for offset in [0, -1] {
            if let newYear = lunarNewYear(year: year + offset, calendar: calendar),
               let start = calendar.date(byAdding: .day, value: -2, to: newYear),
               let end = calendar.date(byAdding: .day, value: 14, to: newYear),
               today >= start, today <= end {
                return .lunarNewYear
            }
        }

        // Swedish Midsummer: Midsummer Eve is the Friday between 19 and 25 June; the skin
        // runs from the day before through the weekend.
        if month == 6, let eve = midsummerEve(year: year, calendar: calendar),
           let start = calendar.date(byAdding: .day, value: -1, to: eve),
           let end = calendar.date(byAdding: .day, value: 2, to: eve),
           today >= start, today <= end {
            return .midsummer
        }
        return nil
    }

    /// Today's season, worked out once per calendar day. Main actor: views call it per frame.
    @MainActor static func today(now: Date = Date(), calendar: Calendar = .current) -> SeasonalSkin? {
        let day = calendar.startOfDay(for: now)
        if let cached = todayCache, cached.day == day { return cached.season }
        let season = current(on: now, calendar: calendar)
        todayCache = (day, season)
        return season
    }

    @MainActor private static var todayCache: (day: Date, season: SeasonalSkin?)?

    /// Lunar New Year's Day (Gregorian), 2026–2035. Outside the table there's no skin rather
    /// than a guess; extend it before 2036.
    static let lunarNewYearDates: [Int: (month: Int, day: Int)] = [
        2026: (2, 17), 2027: (2, 6), 2028: (1, 26), 2029: (2, 13), 2030: (2, 3),
        2031: (1, 23), 2032: (2, 11), 2033: (1, 31), 2034: (2, 19), 2035: (2, 8),
    ]

    static func lunarNewYear(year: Int, calendar: Calendar) -> Date? {
        guard let date = lunarNewYearDates[year] else { return nil }
        return calendar.date(from: DateComponents(year: year, month: date.month, day: date.day))
    }

    static func midsummerEve(year: Int, calendar: Calendar) -> Date? {
        for day in 19...25 {
            guard let date = calendar.date(from: DateComponents(year: year, month: 6, day: day)) else { continue }
            if calendar.component(.weekday, from: date) == 6 { return date } // Friday
        }
        return nil
    }

    /// Asset name of this season's variant of a base mascot asset, e.g. "Mascot-halloween".
    func assetName(base: String) -> String { "\(base)-\(rawValue)" }
}
