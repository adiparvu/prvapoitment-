import Foundation
import PRVBookingKit
import PRVModels
import Testing

@Suite("RecurrenceExpander")
struct RecurrenceExpanderTests {
    private let expander = RecurrenceExpander(calendar: Fixtures.calendar)

    @Test("Weekly recurrence steps seven days at a time and keeps the time of day")
    func weeklyStepsSevenDays() {
        let plan = expander.expand(
            RecurrenceRule(frequency: .weekly, occurrences: 4),
            from: Fixtures.mondayAt(10, 30)
        )

        #expect(plan.occurrences == [
            Fixtures.date(2026, 3, 2, 10, 30),
            Fixtures.date(2026, 3, 9, 10, 30),
            Fixtures.date(2026, 3, 16, 10, 30),
            Fixtures.date(2026, 3, 23, 10, 30),
        ])
        #expect(plan.skipped.isEmpty)
        #expect(!plan.isTruncated)
    }

    @Test("Biweekly recurrence steps fourteen days at a time")
    func biweeklyStepsFourteenDays() {
        let plan = expander.expand(
            RecurrenceRule(frequency: .biweekly, occurrences: 3),
            from: Fixtures.mondayAt(10)
        )

        #expect(plan.occurrences == [
            Fixtures.date(2026, 3, 2, 10),
            Fixtures.date(2026, 3, 16, 10),
            Fixtures.date(2026, 3, 30, 10),
        ])
    }

    @Test("Every-four-weeks recurrence steps twenty-eight days at a time")
    func everyFourWeeksStepsTwentyEightDays() {
        let plan = expander.expand(
            RecurrenceRule(frequency: .every4Weeks, occurrences: 3),
            from: Fixtures.mondayAt(10)
        )

        #expect(plan.occurrences == [
            Fixtures.date(2026, 3, 2, 10),
            Fixtures.date(2026, 3, 30, 10),
            Fixtures.date(2026, 4, 27, 10),
        ])
        #expect(expander.cadenceDays(for: .every4Weeks) == 28)
        #expect(expander.cadenceDays(for: .monthly) == nil)
    }

    @Test("Monthly recurrence clamps 31 January to the end of February")
    func monthlyClampsToShortMonths() {
        let plan = expander.expand(
            RecurrenceRule(frequency: .monthly, occurrences: 2),
            from: Fixtures.date(2026, 1, 31, 11)
        )

        #expect(plan.occurrences == [
            Fixtures.date(2026, 1, 31, 11),
            Fixtures.date(2026, 2, 28, 11),
        ])
    }

    @Test("Monthly recurrence recovers the anchor's day of month after a clamp")
    func monthlyRecoversDayOfMonth() {
        let plan = expander.expand(
            RecurrenceRule(frequency: .monthly, occurrences: 5),
            from: Fixtures.date(2026, 1, 31, 11)
        )

        #expect(plan.occurrences == [
            Fixtures.date(2026, 1, 31, 11),
            Fixtures.date(2026, 2, 28, 11),
            Fixtures.date(2026, 3, 31, 11),
            Fixtures.date(2026, 4, 30, 11),
            Fixtures.date(2026, 5, 31, 11),
        ])
    }

    @Test("Monthly recurrence lands on 29 February in a leap year")
    func monthlyHandlesLeapYear() {
        let plan = expander.expand(
            RecurrenceRule(frequency: .monthly, occurrences: 2),
            from: Fixtures.date(2028, 1, 31, 11)
        )

        #expect(plan.occurrences.last == Fixtures.date(2028, 2, 29, 11))
    }

    @Test("The occurrence count includes the first visit")
    func occurrenceCountIncludesFirstVisit() {
        let plan = expander.expand(RecurrenceRule(frequency: .weekly, occurrences: 1), from: Fixtures.mondayAt(10))

        #expect(plan.count == 1)
        #expect(plan.first == Fixtures.mondayAt(10))
        #expect(plan.last == Fixtures.mondayAt(10))
    }

    @Test("An open-ended rule falls back to the configured default count")
    func openEndedRuleUsesDefaultCount() {
        let plan = expander.expand(RecurrenceRule(frequency: .weekly), from: Fixtures.mondayAt(10))

        #expect(plan.count == 12)
    }

    @Test("The occurrence ceiling caps an over-eager rule")
    func occurrenceCeilingCapsExpansion() {
        let capped = RecurrenceExpander(
            calendar: Fixtures.calendar,
            options: RecurrenceExpander.Options(maximumOccurrences: 6)
        )
        let plan = capped.expand(RecurrenceRule(frequency: .weekly, occurrences: 500), from: Fixtures.mondayAt(10))

        #expect(plan.count == 6)
    }

    @Test("A non-positive occurrence count produces an empty plan")
    func nonPositiveCountProducesEmptyPlan() {
        let plan = expander.expand(RecurrenceRule(frequency: .weekly, occurrences: 0), from: Fixtures.mondayAt(10))

        #expect(plan.isEmpty)
        #expect(plan.skipped.isEmpty)
        #expect(!plan.isTruncated)
    }

    @Test("The conflict hook skips a date without consuming an occurrence")
    func conflictHookSkipsWithoutConsuming() {
        let blocked = Fixtures.date(2026, 3, 9, 10)
        let plan = expander.expand(
            RecurrenceRule(frequency: .weekly, occurrences: 3),
            from: Fixtures.mondayAt(10)
        ) { $0 == blocked }

        #expect(plan.occurrences == [
            Fixtures.date(2026, 3, 2, 10),
            Fixtures.date(2026, 3, 16, 10),
            Fixtures.date(2026, 3, 23, 10),
        ])
        #expect(plan.skipped == [blocked])
        #expect(!plan.isTruncated)
    }

    @Test("The conflict hook can reject the very first occurrence")
    func conflictHookCanRejectTheFirstOccurrence() {
        let plan = expander.expand(
            RecurrenceRule(frequency: .weekly, occurrences: 2),
            from: Fixtures.mondayAt(10)
        ) { $0 == Fixtures.mondayAt(10) }

        #expect(plan.occurrences == [
            Fixtures.date(2026, 3, 9, 10),
            Fixtures.date(2026, 3, 16, 10),
        ])
        #expect(plan.skipped == [Fixtures.mondayAt(10)])
    }

    @Test("A horizon truncates the plan and flags it")
    func horizonTruncatesPlan() {
        let bounded = RecurrenceExpander(
            calendar: Fixtures.calendar,
            options: RecurrenceExpander.Options(horizon: Fixtures.date(2026, 3, 20))
        )
        let plan = bounded.expand(
            RecurrenceRule(frequency: .weekly, occurrences: 10),
            from: Fixtures.mondayAt(10)
        )

        #expect(plan.occurrences == [
            Fixtures.date(2026, 3, 2, 10),
            Fixtures.date(2026, 3, 9, 10),
            Fixtures.date(2026, 3, 16, 10),
        ])
        #expect(plan.isTruncated)
    }

    @Test("A hook that blocks everything exhausts the step budget instead of looping")
    func hostileHookTerminates() {
        let bounded = RecurrenceExpander(
            calendar: Fixtures.calendar,
            options: RecurrenceExpander.Options(maximumSteps: 8)
        )
        let plan = bounded.expand(RecurrenceRule(frequency: .weekly, occurrences: 5), from: Fixtures.mondayAt(10)) { _ in
            true
        }

        #expect(plan.isEmpty)
        #expect(plan.skipped.count == 8)
        #expect(plan.isTruncated)
    }

    @Test("The next occurrence after a date is found without expanding the whole series")
    func nextOccurrenceLooksForward() {
        let rule = RecurrenceRule(frequency: .weekly, occurrences: 10)
        let next = expander.nextOccurrence(
            after: Fixtures.date(2026, 3, 10),
            of: rule,
            anchor: Fixtures.mondayAt(10)
        )

        #expect(next == Fixtures.date(2026, 3, 16, 10))
        #expect(expander.occurrence(atStep: 0, of: rule, anchor: Fixtures.mondayAt(10)) == Fixtures.mondayAt(10))
        #expect(expander.occurrence(atStep: -1, of: rule, anchor: Fixtures.mondayAt(10)) == nil)
    }
}
