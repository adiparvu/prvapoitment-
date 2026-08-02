import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

/// Shared, deterministic display formatting for the booking feature.
/// Pure functions only — no state, no side effects.
enum BookingFormatting {
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

    /// Localized short time, e.g. `"2:30 PM"`.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Weekday + day + month, e.g. `"Thu 14 Aug"`.
    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Full date and time for summaries, e.g. `"Thursday, 14 August at 2:30 PM"`.
    static func dateAndTime(_ date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return "\(day) at \(time(date))"
    }

    /// A human countdown to a future date, e.g. `"in 3 days"`, `"in 2 h 10 min"`,
    /// `"starting now"`. Past dates return `nil`.
    static func countdown(to date: Date, from now: Date = .now) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "starting now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "in \(hours) h" : "in \(hours) h \(remainder) min"
        }
        let days = hours / 24
        return days == 1 ? "in 1 day" : "in \(days) days"
    }

    /// Relative date for past visits, e.g. `"2 weeks ago"`.
    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// One-decimal rating string, e.g. `4.95` → `"4.9"`.
    static func rating(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// Human summary of a recurrence rule, e.g. `"Every 4 weeks · 6 visits"`.
    static func recurrence(_ rule: RecurrenceRule) -> String {
        let cadence = frequency(rule.frequency)
        guard let occurrences = rule.occurrences else { return "\(cadence) · until cancelled" }
        return "\(cadence) · \(occurrences) visits"
    }

    /// Display name for a recurrence frequency.
    static func frequency(_ frequency: RecurrenceRule.Frequency) -> String {
        switch frequency {
        case .weekly: "Every week"
        case .biweekly: "Every 2 weeks"
        case .every4Weeks: "Every 4 weeks"
        case .monthly: "Every month"
        }
    }

    /// Short cancellation-policy sentence shown in the review step.
    static func cancellationPolicy(_ policies: SalonPolicies) -> String {
        if policies.freeCancellationHours <= 0 {
            return "This salon does not offer free cancellation. A \(policies.lateCancellationFeePercent)% fee applies to any cancellation."
        }
        let window = policies.freeCancellationHours == 24
            ? "24 hours"
            : "\(policies.freeCancellationHours) hours"
        if policies.lateCancellationFeePercent <= 0 {
            return "Free cancellation any time up to \(window) before your visit."
        }
        return "Free cancellation up to \(window) before your visit. After that a \(policies.lateCancellationFeePercent)% fee applies, and no-shows are charged \(policies.noShowFeePercent)%."
    }

    /// Human label for a coupon's discount.
    static func discount(_ discount: Coupon.Discount) -> String {
        switch discount {
        case .percent(let value): "\(value)% off"
        case .fixed(let money): "\(money.formatted) off"
        }
    }

    /// Maps transport errors to warm, actionable copy — never raw codes.
    /// `subject` names what failed, e.g. `"This salon"`.
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
        case .conflict(let message):
            return message.isBlank
                ? "That time was just taken. Please pick another slot."
                : message
        case .unauthorized, .forbidden, .server, .decoding:
            return "Our servers are momentarily busy. Please try again shortly."
        }
    }
}

/// The part of the day a slot falls in. Slot grids are grouped by these so a
/// long list of times stays scannable.
enum SlotPeriod: Int, CaseIterable, Hashable, Sendable, Identifiable {
    case morning
    case afternoon
    case evening

    var id: Int { rawValue }

    /// Section title.
    var title: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        }
    }

    /// SF Symbol illustrating the period.
    var symbolName: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        }
    }

    /// Classifies a slot start time by local hour.
    static func of(_ date: Date, calendar: Calendar = .current) -> SlotPeriod {
        switch calendar.component(.hour, from: date) {
        case ..<12: .morning
        case 12..<17: .afternoon
        default: .evening
        }
    }
}

/// A period section of a slot grid.
struct SlotSection: Identifiable, Hashable, Sendable {
    var period: SlotPeriod
    var slots: [TimeSlot]
    var id: Int { period.rawValue }
}

extension Array where Element == TimeSlot {
    /// Groups slots into Morning / Afternoon / Evening sections, chronologically
    /// within each section. Empty periods are omitted.
    func groupedByPeriod(calendar: Calendar = .current) -> [SlotSection] {
        let buckets = Dictionary(grouping: self) { SlotPeriod.of($0.start, calendar: calendar) }
        return SlotPeriod.allCases.compactMap { period in
            guard let slots = buckets[period], !slots.isEmpty else { return nil }
            return SlotSection(period: period, slots: slots.sorted { $0.start < $1.start })
        }
    }

    /// The best-scoring slots for the salon's calendar — the "Recommended"
    /// row. Ties break toward the earlier time so the row stays stable.
    func topRecommended(_ limit: Int = 3) -> [TimeSlot] {
        sorted {
            $0.optimizationScore == $1.optimizationScore
                ? $0.start < $1.start
                : $0.optimizationScore > $1.optimizationScore
        }
        .prefix(limit)
        .map { $0 }
    }
}
