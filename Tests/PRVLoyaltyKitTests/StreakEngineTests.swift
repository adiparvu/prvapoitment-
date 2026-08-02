import Foundation
import PRVLoyaltyKit
import PRVModels
import Testing

@Suite("StreakEngine")
struct StreakEngineTests {
    private let engine = StreakEngine(calendar: LoyaltyFixtures.calendar)
    private let strict = StreakEngine(calendar: LoyaltyFixtures.calendar, graceDays: 0)

    // MARK: Starting

    @Test("The first ever check-in starts the streak at one")
    func firstCheckInStartsTheStreak() {
        let result = engine.register(day: LoyaltyFixtures.mondayAt(9), lastActiveDay: nil, currentStreakDays: 0)

        #expect(result.outcome == .started)
        #expect(result.streakDays == 1)
        #expect(result.previousStreakDays == 0)
        #expect(result.lastRewardedDay == LoyaltyFixtures.monday)
        #expect(result.didCountToday)
        #expect(result.milestone == nil)
    }

    // MARK: Continuation

    @Test("Checking in the next calendar day continues the streak")
    func consecutiveDaysContinueTheStreak() {
        let result = engine.register(
            day: LoyaltyFixtures.tuesdayAt(8),
            lastActiveDay: LoyaltyFixtures.mondayAt(23, 55),
            currentStreakDays: 4
        )

        #expect(result.outcome == .continued)
        #expect(result.streakDays == 5)
        #expect(!result.usedGrace)
        #expect(result.lastRewardedDay == LoyaltyFixtures.tuesday)
    }

    @Test("Days are calendar days, not 24-hour periods")
    func fiveMinutesAcrossMidnightCounts() {
        // 23:55 Monday → 00:05 Tuesday is ten minutes, but two calendar days.
        let result = engine.register(
            day: LoyaltyFixtures.tuesdayAt(0, 5),
            lastActiveDay: LoyaltyFixtures.mondayAt(23, 55),
            currentStreakDays: 1
        )

        #expect(result.outcome == .continued)
        #expect(result.streakDays == 2)
    }

    @Test("A second check-in on the same day never double-counts")
    func sameDayIsNotCountedTwice() {
        let result = engine.register(
            day: LoyaltyFixtures.mondayAt(21),
            lastActiveDay: LoyaltyFixtures.mondayAt(7),
            currentStreakDays: 6
        )

        #expect(result.outcome == .alreadyCountedToday)
        #expect(result.streakDays == 6)
        #expect(!result.didCountToday)
        #expect(result.milestone == nil)
        #expect(result.bonusPoints == 0)
        #expect(result.lastRewardedDay == LoyaltyFixtures.monday)
    }

    @Test("A backwards device clock is treated as already counted, never as a reset")
    func backwardsClockDoesNotBreakTheStreak() {
        let result = engine.register(
            day: LoyaltyFixtures.mondayAt(10),
            lastActiveDay: LoyaltyFixtures.thursday,
            currentStreakDays: 9
        )

        #expect(result.outcome == .alreadyCountedToday)
        #expect(result.streakDays == 9)
        #expect(result.lastRewardedDay == LoyaltyFixtures.thursday)
    }

    // MARK: Grace

    @Test("One missed day is forgiven by the default grace allowance")
    func oneMissedDayUsesGrace() {
        let result = engine.register(
            day: LoyaltyFixtures.wednesday,
            lastActiveDay: LoyaltyFixtures.monday,
            currentStreakDays: 4
        )

        #expect(result.outcome == .continuedWithGrace)
        #expect(result.usedGrace)
        #expect(result.didCountToday)
        // Grace protects the streak; it never credits the missed day.
        #expect(result.streakDays == 5)
    }

    @Test("Two missed days exhaust grace and reset the streak")
    func twoMissedDaysResetTheStreak() {
        let result = engine.register(
            day: LoyaltyFixtures.thursday,
            lastActiveDay: LoyaltyFixtures.monday,
            currentStreakDays: 12
        )

        #expect(result.outcome == .reset)
        #expect(result.didReset)
        #expect(result.streakDays == 1)
        #expect(result.previousStreakDays == 12)
        #expect(result.milestone == nil)
    }

    @Test("A strict programme resets the moment a day is missed")
    func strictEngineHasNoGrace() {
        let continued = strict.register(
            day: LoyaltyFixtures.tuesday,
            lastActiveDay: LoyaltyFixtures.monday,
            currentStreakDays: 3
        )
        #expect(continued.outcome == .continued)
        #expect(continued.streakDays == 4)

        let reset = strict.register(
            day: LoyaltyFixtures.wednesday,
            lastActiveDay: LoyaltyFixtures.monday,
            currentStreakDays: 3
        )
        #expect(reset.outcome == .reset)
        #expect(reset.streakDays == 1)
    }

    @Test("Remaining slack counts down and bottoms out at zero")
    func slackCountsDown() {
        #expect(engine.daysOfSlackRemaining(lastActiveDay: nil, now: LoyaltyFixtures.monday) == nil)
        #expect(engine.daysOfSlackRemaining(lastActiveDay: LoyaltyFixtures.monday, now: LoyaltyFixtures.monday) == 2)
        #expect(engine.daysOfSlackRemaining(lastActiveDay: LoyaltyFixtures.monday, now: LoyaltyFixtures.tuesday) == 1)
        #expect(engine.daysOfSlackRemaining(lastActiveDay: LoyaltyFixtures.monday, now: LoyaltyFixtures.wednesday) == 0)
        #expect(engine.daysOfSlackRemaining(lastActiveDay: LoyaltyFixtures.monday, now: LoyaltyFixtures.friday) == 0)
        #expect(strict.daysOfSlackRemaining(lastActiveDay: LoyaltyFixtures.monday, now: LoyaltyFixtures.monday) == 1)
    }

    // MARK: Milestones

    @Test("Reaching exactly seven days pays the Week of Beauty bonus once")
    func milestonePaysOnTheExactDay() throws {
        let onTarget = engine.register(
            day: LoyaltyFixtures.tuesday,
            lastActiveDay: LoyaltyFixtures.monday,
            currentStreakDays: 6
        )
        let milestone = try #require(onTarget.milestone)

        #expect(onTarget.streakDays == 7)
        #expect(milestone.days == 7)
        #expect(milestone.title == "Week of Beauty")
        #expect(onTarget.bonusPoints == 250)
        #expect(onTarget.bonusXP == 150)
        #expect(onTarget.bonusAward.points == 250)

        // Day eight is not a milestone.
        let dayAfter = engine.register(
            day: LoyaltyFixtures.wednesday,
            lastActiveDay: LoyaltyFixtures.tuesday,
            currentStreakDays: 7
        )
        #expect(dayAfter.streakDays == 8)
        #expect(dayAfter.milestone == nil)
        #expect(dayAfter.bonusPoints == 0)
    }

    @Test("Milestone lookup and progress walk the ladder")
    func milestoneLadderIsQueryable() {
        #expect(engine.milestone(for: 3)?.title == "Three-Day Glow")
        #expect(engine.milestone(for: 4) == nil)
        #expect(engine.nextMilestone(after: 0)?.days == 3)
        #expect(engine.nextMilestone(after: 7)?.days == 14)
        #expect(engine.nextMilestone(after: 100) == nil)
        #expect(engine.progressToNextMilestone(days: 0) == 0)
        #expect(engine.progressToNextMilestone(days: 5) == 0.5)
        #expect(engine.progressToNextMilestone(days: 100) == 1)
    }

    // MARK: Profiles

    @Test("Registering and applying updates the profile end to end")
    func applyUpdatesTheProfile() {
        let profile = LoyaltyFixtures.profile(
            xp: 1_000,
            points: 200,
            streakDays: 6,
            lastDailyRewardAt: LoyaltyFixtures.mondayAt(20)
        )
        let result = engine.register(day: LoyaltyFixtures.tuesdayAt(9), profile: profile)
        let updated = engine.apply(result, to: profile)

        #expect(result.outcome == .continued)
        #expect(updated.currentStreakDays == 7)
        #expect(updated.lastDailyRewardAt == LoyaltyFixtures.tuesday)
        #expect(updated.xp == 1_150)
        #expect(updated.spendablePoints == 450)
        // The original is untouched.
        #expect(profile.currentStreakDays == 6)
        #expect(profile.xp == 1_000)
    }

    @Test("Claiming is detected per calendar day, not per timestamp")
    func hasClaimedIsPerCalendarDay() {
        let claimed = LoyaltyFixtures.profile(lastDailyRewardAt: LoyaltyFixtures.mondayAt(6))

        #expect(engine.hasClaimed(profile: claimed, on: LoyaltyFixtures.mondayAt(23, 59)))
        #expect(!engine.hasClaimed(profile: claimed, on: LoyaltyFixtures.tuesdayAt(0, 1)))
        #expect(!engine.hasClaimed(profile: LoyaltyFixtures.profile(), on: LoyaltyFixtures.monday))
    }

    @Test("An inconsistent record — an anchor with a zero streak — recovers cleanly")
    func inconsistentRecordsRecover() {
        let result = engine.register(
            day: LoyaltyFixtures.tuesday,
            lastActiveDay: LoyaltyFixtures.monday,
            currentStreakDays: 0
        )

        #expect(result.outcome == .continued)
        #expect(result.streakDays == 2)
    }
}
