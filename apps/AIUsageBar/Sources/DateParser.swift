import Foundation

enum DateParser {
    private static let internetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let posixFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = fractionalFormatter.date(from: value) { return date }
        if let date = internetFormatter.date(from: value) { return date }
        let normalized = value.replacingOccurrences(of: "Z", with: "+00:00")
        for formatter in posixFormatters {
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }
}

enum TimeText {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(Int(value.rounded()))%"
    }

    static func compactDuration(_ secondsValue: TimeInterval, hideMinutesIfDays: Bool = false) -> String {
        let seconds = max(0, Int(secondsValue))
        if seconds < 60 { return "<1m" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 || days > 0 { parts.append("\(hours)h") }
        if !(hideMinutesIfDays && days > 0) { parts.append("\(minutes)m") }
        return parts.joined()
    }

    static func compactSingleUnitDuration(_ secondsValue: TimeInterval) -> String {
        let seconds = max(0, Int(secondsValue))
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    static func compactSingleUnitReset(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return compactSingleUnitDuration(date.timeIntervalSinceNow)
    }

    static func relativeReset(_ date: Date?, hideMinutesIfDays: Bool = false) -> String {
        guard let date else { return "n/a" }
        return compactDuration(date.timeIntervalSinceNow, hideMinutesIfDays: hideMinutesIfDays)
    }

    static func relativeAge(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 20 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
