import Foundation
import PRVModels

/// The result of expanding a `RecurrenceRule` into concrete dates.
public struct RecurrencePlan: Hashable, Sendable {
    /// The accepted occurrences, chronologically. Includes the first visit.
    public var occurrences: [Date]
    /// Cadence dates rejected by the conflict hook, chronologically.
    public var skipped: [Date]
    /// `true` when expansion stopped before producing the requested number of
    /// occurrences — because of the horizon or the step budget.
    public var isTruncated: Bool

    /// Creates a plan.
    public init(occurrences: [Date] = [], skipped: [Date] = [], isTruncated: Bool = false) {
        self.occurrences = occurrences
        self.skipped = skipped
        self.isTruncated = isTruncated
    }

    /// Number of accepted occurrences.
    public var count: Int { occurrences.count }
    /// `true` when nothing could be scheduled at all.
    public var isEmpty: Bool { occurrences.isEmpty }
    /// The first accepted occurrence.
    public var first: Date? { occurrences.first }
    /// The last accepted occurrence.
    public var last: Date? { occurrences.last }
}

/// Expands a `RecurrenceRule` into the dates a standing appointment will land on.
///
/// Every occurrence is computed from the **anchor**, never from the previous
/// occurrence, so the series cannot drift. That is what makes month-end behave the
/// way clients expect: a 31 January booking repeating monthly lands on 28 February
/// (29 in a leap year) and then returns to 31 March, rather than collapsing to the
/// 28th forever.
///
/// The conflict hook lets callers reject a date — a salon holiday, a professional's
/// leave, an existing booking. Rejected dates are reported in
/// ``RecurrencePlan/skipped`` and do **not** consume an occurrence, so "book me ten
/// sessions" still yields ten.
public struct RecurrenceExpander: Sendable {
    /// Limits applied to expansion.
    public struct Options: Hashable, Sendable {
        /// Occurrences generated when the rule is open-ended (`occurrences == nil`).
        public var defaultOccurrences: Int
        /// Ceiling on accepted occurrences, whatever the rule asks for.
        public var maximumOccurrences: Int
        /// Ceiling on cadence steps examined, so a hostile conflict hook cannot
        /// spin forever.
        public var maximumSteps: Int
        /// Occurrences after this date are dropped and the plan marked truncated.
        public var horizon: Date?

        /// Creates an options set.
        public init(
            defaultOccurrences: Int = 12,
            maximumOccurrences: Int = 104,
            maximumSteps: Int = 520,
            horizon: Date? = nil
        ) {
            self.defaultOccurrences = max(0, defaultOccurrences)
            self.maximumOccurrences = max(0, maximumOccurrences)
            self.maximumSteps = max(1, maximumSteps)
            self.horizon = horizon
        }
    }

    /// The calendar all cadence maths runs through.
    public let calendar: Calendar
    /// Expansion limits.
    public let options: Options

    /// Creates an expander.
    public init(calendar: Calendar = .prvBooking, options: Options = Options()) {
        self.calendar = calendar
        self.options = options
    }

    /// Expands `rule` starting at `firstOccurrence`.
    ///
    /// - Parameters:
    ///   - rule: cadence and occurrence count. `occurrences` counts the first visit.
    ///   - firstOccurrence: the anchor date and time. Time of day is preserved for
    ///     every occurrence, including across daylight-saving transitions.
    ///   - isBlocked: conflict hook. Return `true` to skip a cadence date without
    ///     consuming an occurrence.
    public func expand(
        _ rule: RecurrenceRule,
        from firstOccurrence: Date,
        isBlocked: (Date) -> Bool = { _ in false }
    ) -> RecurrencePlan {
        let requested = rule.occurrences ?? options.defaultOccurrences
        let target = min(max(requested, 0), options.maximumOccurrences)
        guard target > 0 else { return RecurrencePlan() }

        var occurrences: [Date] = []
        var skipped: [Date] = []
        var isTruncated = false
        var step = 0

        while occurrences.count < target {
            guard step < options.maximumSteps else {
                isTruncated = true
                break
            }
            guard let candidate = occurrence(atStep: step, of: rule, anchor: firstOccurrence) else {
                isTruncated = true
                break
            }
            step += 1

            if let horizon = options.horizon, candidate > horizon {
                isTruncated = true
                break
            }
            if isBlocked(candidate) {
                skipped.append(candidate)
                continue
            }
            occurrences.append(candidate)
        }

        return RecurrencePlan(occurrences: occurrences, skipped: skipped, isTruncated: isTruncated)
    }

    /// The date `step` cadence intervals after `anchor` (`step == 0` is the anchor).
    ///
    /// Monthly steps clamp to the last day of a short month — 31 January + 1 month is
    /// 28 (or 29) February — while later steps recover the anchor's day of month
    /// because every step is measured from the anchor.
    public func occurrence(atStep step: Int, of rule: RecurrenceRule, anchor: Date) -> Date? {
        guard step >= 0 else { return nil }
        guard step > 0 else { return anchor }
        switch rule.frequency {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7 * step, to: anchor)
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14 * step, to: anchor)
        case .every4Weeks:
            return calendar.date(byAdding: .day, value: 28 * step, to: anchor)
        case .monthly:
            return calendar.date(byAdding: .month, value: step, to: anchor)
        }
    }

    /// The next cadence date strictly after `date`, or `nil` if the step budget runs out.
    public func nextOccurrence(after date: Date, of rule: RecurrenceRule, anchor: Date) -> Date? {
        var step = 0
        while step < options.maximumSteps {
            guard let candidate = occurrence(atStep: step, of: rule, anchor: anchor) else { return nil }
            if candidate > date { return candidate }
            step += 1
        }
        return nil
    }

    /// Whole days between consecutive occurrences of a fixed-interval cadence.
    /// Returns `nil` for `.monthly`, whose spacing varies by month.
    public func cadenceDays(for frequency: RecurrenceRule.Frequency) -> Int? {
        switch frequency {
        case .weekly: return 7
        case .biweekly: return 14
        case .every4Weeks: return 28
        case .monthly: return nil
        }
    }
}
