import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

/// Shared, deterministic display formatting for the salon-profile feature.
/// Pure helpers only — no state, no side effects.
enum ProfileFormatting {
    /// Formats a duration in minutes as a compact human string,
    /// e.g. `90` → `"1 h 30 min"`, `45` → `"45 min"`, `120` → `"2 h"`.
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        switch (hours, remainder) {
        case (0, _): return "\(remainder) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(remainder) min"
        }
    }

    /// Formats minutes-from-midnight (`OpeningHours.Interval` values) as a
    /// localized short time, e.g. `540` → `"9:00 AM"`.
    static func timeOfDay(_ minutesFromMidnight: Int) -> String {
        let base = Calendar.current.startOfDay(for: .now)
        return base.adding(minutes: minutesFromMidnight)
            .formatted(date: .omitted, time: .shortened)
    }

    /// Localized weekday name for a `Calendar.component(.weekday)` value
    /// (1 = Sunday … 7 = Saturday).
    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard (1...symbols.count).contains(weekday) else { return "" }
        return symbols[weekday - 1]
    }

    /// Display order for opening-hours rows: Monday first, Sunday last.
    static let orderedWeekdays: [Int] = [2, 3, 4, 5, 6, 7, 1]

    /// Localized language name for an ISO code, e.g. `"fr"` → `"French"`.
    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    /// Relative date for review timestamps, e.g. "2 weeks ago".
    static func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// One-decimal rating string, e.g. `4.95` → `"4.9"`.
    static func rating(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// Maps transport errors to warm, actionable copy — never raw codes.
    /// `subject` names what failed to load, e.g. `"This salon"`.
    static func friendlyError(_ error: any Error, subject: String) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Please try again."
        }
        switch apiError {
        case .offline, .network:
            return "You appear to be offline. Check your connection and try again."
        case .notFound:
            return "\(subject) is no longer available."
        case .rateLimited:
            return "Too many requests. Take a breath and try again in a moment."
        case .unauthorized, .forbidden, .conflict, .server, .decoding:
            return "Our servers are momentarily busy. Please try again shortly."
        }
    }
}
