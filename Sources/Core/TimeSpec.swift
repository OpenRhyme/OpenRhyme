import Foundation

public struct TimeSpecError: Error, Equatable, Sendable {
    public let input: String
}

/// Parses the `<time>` grammar shared by the CLI and the MCP server (spec §9):
/// relative durations (`30s`, `30m`, `2h`, `1d`, decimals allowed) meaning "that long ago",
/// unix seconds, ISO-8601 with a zone, or local date/time without a zone.
public enum TimeSpec {
    public static func parse(
        _ text: String, now: Date = Date(), timeZone: TimeZone = .current
    ) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TimeSpecError(input: text) }

        if let relative = parseRelative(trimmed) {
            return now.timeIntervalSince1970 - relative
        }
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }), let seconds = Double(trimmed) {
            return seconds
        }
        if let date = parseISO8601(trimmed) {
            return date.timeIntervalSince1970
        }
        if let date = parseLocal(trimmed, timeZone: timeZone) {
            return date.timeIntervalSince1970
        }
        throw TimeSpecError(input: text)
    }

    private static func parseRelative(_ text: String) -> Double? {
        guard let unit = text.last else { return nil }
        let multiplier: Double
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default: return nil
        }
        let digits = text.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber || $0 == "." }),
            let amount = Double(digits)
        else { return nil }
        return amount * multiplier
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func parseLocal(_ text: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
