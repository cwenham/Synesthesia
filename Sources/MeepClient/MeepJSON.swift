import Foundation

/// JSON as the daemon writes it. Its dates are .NET's `DateTimeOffset`: ISO 8601 with up to seven digits of
/// fractional seconds and an offset, such as `2026-11-16T16:22:01.325359+00:00`, which Foundation's own ISO 8601
/// parsing doesn't reliably take, so they're read here. A subscription writes them as microseconds since 1970
/// instead, which are read too.
public enum MeepJSON {
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let microseconds = try? container.decode(Int64.self) {
                return Date(microsecondsSince1970: microseconds)
            }
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(text) isn't an ISO 8601 date.")
            }
            return date
        }
        return decoder
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Reads `yyyy-MM-ddTHH:mm:ss[.fffffff](Z|±HH:mm)`.
    public static func parseDate(_ text: String) -> Date? {
        let chars = Array(text.utf8)
        func number(_ start: Int, _ length: Int) -> Int? {
            guard start + length <= chars.count else { return nil }
            var value = 0
            for byte in chars[start..<(start + length)] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard chars.count >= 20,
              let year = number(0, 4), chars[4] == 45, let month = number(5, 2), chars[7] == 45, let day = number(8, 2),
              chars[10] == 84 || chars[10] == 116 || chars[10] == 32,
              let hour = number(11, 2), chars[13] == 58, let minute = number(14, 2), chars[16] == 58, let second = number(17, 2)
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < chars.count, chars[index] == 46 {
            index += 1
            var scale = 0.1
            while index < chars.count, chars[index] >= 48, chars[index] <= 57 {
                fraction += Double(chars[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }

        var offset = 0
        guard index < chars.count else { return nil }
        switch chars[index] {
        case 90, 122: // Z
            index += 1
        case 43, 45: // + or -
            let sign = chars[index] == 43 ? 1 : -1
            guard let hours = number(index + 1, 2) else { return nil }
            var minutesAt = index + 3
            if minutesAt < chars.count, chars[minutesAt] == 58 { minutesAt += 1 }
            guard let minutes = number(minutesAt, 2) else { return nil }
            offset = sign * (hours * 3600 + minutes * 60)
            index = minutesAt + 2
        default:
            return nil
        }
        guard index == chars.count else { return nil }

        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let whole = utc.date(from: components) else { return nil }
        return whole.addingTimeInterval(fraction - Double(offset))
    }

    /// Writes a date as the daemon reads them, in UTC with milliseconds.
    public static func formatDate(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }
}

extension Date {
    /// A time as a subscription writes it: microseconds since 1970 (UTC).
    public init(microsecondsSince1970 microseconds: Int64) {
        self.init(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }
}
