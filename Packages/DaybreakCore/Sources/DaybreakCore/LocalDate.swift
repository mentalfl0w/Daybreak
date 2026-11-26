import Foundation

/// A calendar date as reported by a wallpaper source for a specific market.
///
/// `LocalDate` deliberately has no time zone and is never derived from
/// `Date()` by default. Matching, calendar state and recap calculations use
/// these source-local dates so a device time-zone change cannot move an image
/// or story to another day.
public struct LocalDate: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year),
              (1...12).contains(month),
              (1...LocalDate.daysInMonth(year: year, month: month)).contains(day)
        else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Converts an absolute instant to a calendar date in an explicitly
    /// supplied market time zone.
    ///
    /// There is intentionally no overload that reads the device time zone.
    /// A provider must name the market zone it used to interpret a publisher
    /// timestamp, and the resulting `LocalDate` is then independent of later
    /// device time-zone changes.
    public init?(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    /// Parses exactly `YYYY-MM-DD` with ASCII digits and no time or zone suffix.
    public init?(iso8601: String) {
        let bytes = Array(iso8601.utf8)
        guard bytes.count == 10,
              bytes[4] == 45, // '-'
              bytes[7] == 45  // '-'
        else {
            return nil
        }
        guard let year = LocalDate.decimalValue(bytes[0..<4]),
              let month = LocalDate.decimalValue(bytes[5..<7]),
              let day = LocalDate.decimalValue(bytes[8..<10])
        else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    public var iso8601: String {
        "\(LocalDate.padded(year, width: 4))-\(LocalDate.padded(month, width: 2))-\(LocalDate.padded(day, width: 2))"
    }

    public var description: String { iso8601 }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    public var dayNumber: Int {
        var adjustedYear = year
        adjustedYear -= month <= 2 ? 1 : 0
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    public static func fromDayNumber(_ dayNumber: Int) -> LocalDate? {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return LocalDate(year: year + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    public func adding(days: Int) -> LocalDate? {
        let (number, overflow) = dayNumber.addingReportingOverflow(days)
        guard !overflow else { return nil }
        return LocalDate.fromDayNumber(number)
    }

    public var nextDay: LocalDate? { adding(days: 1) }
    public var previousDay: LocalDate? { adding(days: -1) }

    /// Signed day distance; `2026-12-31` to `2027-01-01` is `1`.
    public func days(until other: LocalDate) -> Int {
        other.dayNumber - dayNumber
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = LocalDate(iso8601: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a valid YYYY-MM-DD date, got \(rawValue)"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso8601)
    }

    private static func decimalValue(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in bytes {
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

/// An inclusive range of source-local calendar dates.
public struct LocalDateRange: Hashable, Sendable {
    public let start: LocalDate
    public let end: LocalDate

    public init?(start: LocalDate, end: LocalDate) {
        guard start <= end else { return nil }
        self.start = start
        self.end = end
    }

    public func contains(_ date: LocalDate) -> Bool {
        date >= start && date <= end
    }

    /// Inclusive day count.
    public var dayCount: Int {
        start.days(until: end) + 1
    }
}
