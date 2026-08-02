import Foundation
import PRVModels

// MARK: - Milestones

/// A streak length worth celebrating, and what reaching it pays.
public struct StreakMilestone: Hashable, Sendable, Identifiable {
    /// The exact streak length that unlocks this milestone.
    public let days: Int
    /// Display name, e.g. "Week of Beauty".
    public let title: String
    /// SF Symbol representing the milestone.
    public let symbolName: String
    /// Bonus spendable points paid once, on the day the milestone is reached.
    public let bonusPoints: Int
    /// Bonus XP paid once, on the day the milestone is reached.
    public let bonusXP: Int

    /// Creates a milestone.
    public init(days: Int, title: String, symbolName: String, bonusPoints: Int, bonusXP: Int) {
        self.days = max(1, days)
        self.title = title
        self.symbolName = symbolName
        self.bonusPoints = max(0, bonusPoints)
        self.bonusXP = max(0, bonusXP)
    }

    /// Milestones are identified by the streak length that unlocks them.
    public var id: Int { days }
}

// MARK: - Outcome

/// What registering a day did to the streak.
public enum StreakOutcome: String, Hashable, Sendable, CaseIterable {
    /// First ever check-in — the streak begins at 1.
    case started
    /// This calendar day was already counted; nothing changed.
    case alreadyCountedToday = "already_counted_today"
    /// The previous calendar day was counted — a clean continuation.
    case continued
    /// One or more days were missed but stayed inside the grace allowance.
    case continuedWithGrace = "continued_with_grace"
    /// Too many days were missed — the streak restarts at 1.
    case reset

    /// `true` when this outcome advanced the streak (and may pay a milestone).
    public var didAdvance: Bool {
        switch self {
        case .started, .continued, .continuedWithGrace: true
        case .alreadyCountedToday, .reset: false
        }
    }
}

/// The full result of registering one day of activity.
public struct StreakResult: Hashable, Sendable {
    /// What happened.
    public let outcome: StreakOutcome
    /// The streak length after registering.
    public let streakDays: Int
    /// The streak length before registering.
    public let previousStreakDays: Int
    /// Start of the calendar day the streak is now anchored to.
    public let lastRewardedDay: Date
    /// The milestone reached on exactly this day, if any.
    public let milestone: StreakMilestone?

    /// Creates a result.
    public init(
        outcome: StreakOutcome,
        streakDays: Int,
        previousStreakDays: Int,
        lastRewardedDay: Date,
        milestone: StreakMilestone?
    ) {
        self.outcome = outcome
        self.streakDays = streakDays
        self.previousStreakDays = previousStreakDays
        self.lastRewardedDay = lastRewardedDay
        self.milestone = milestone
    }

    /// Bonus points paid by a milestone reached today (0 when none).
    public var bonusPoints: Int { milestone?.bonusPoints ?? 0 }
    /// Bonus XP paid by a milestone reached today (0 when none).
    public var bonusXP: Int { milestone?.bonusXP ?? 0 }
    /// `true` when today counted toward the streak.
    public var didCountToday: Bool { outcome.didAdvance }
    /// `true` when the streak was lost and restarted.
    public var didReset: Bool { outcome == .reset }
    /// `true` when the streak survived only because of the grace allowance.
    public var usedGrace: Bool { outcome == .continuedWithGrace }
    /// The milestone bonus expressed as an ``XPAward``.
    public var bonusAward: XPAward {
        guard let milestone else { return .zero }
        return XPAward(xp: milestone.bonusXP, points: milestone.bonusPoints, reason: milestone.title)
    }
}

// MARK: - Engine

/// Decides whether a daily streak continues, survives on grace, or resets.
///
/// ### Rules
///
/// Everything is measured in **calendar days**, never in 24-hour periods, so a client
/// checking in at 23:55 and again at 00:05 has a two-day streak — which is what a
/// human expects. Let `gap` be the number of calendar days between the last counted
/// day and the day being registered:
///
/// | `gap`                    | Outcome                | Streak            |
/// |--------------------------|------------------------|-------------------|
/// | `<= 0`                   | `alreadyCountedToday`  | unchanged         |
/// | `1`                      | `continued`            | `previous + 1`    |
/// | `2 ... 1 + graceDays`    | `continuedWithGrace`   | `previous + 1`    |
/// | `> 1 + graceDays`        | `reset`                | `1`               |
///
/// `graceDays` defaults to **1**: one missed day is forgiven — life happens — but the
/// missed day never counts, so grace protects the streak without inflating it. Set it
/// to `0` for a strict programme.
///
/// A `gap` below zero means the device clock moved backwards. That is treated exactly
/// like "already counted": never double-credit, and never punish a client for a clock.
///
/// Milestones pay **once**, on the exact day the streak length matches, and only when
/// the outcome actually advanced the streak.
///
/// The calendar is injected. Pass `.current` in the app so "a day" is the client's own
/// day, and a fixed UTC calendar (``Calendar/prvLoyalty``) in tests.
public struct StreakEngine: Sendable {
    /// The platform's standard milestone ladder.
    public static let standardMilestones: [StreakMilestone] = [
        StreakMilestone(days: 3, title: "Three-Day Glow", symbolName: "sparkle", bonusPoints: 100, bonusXP: 50),
        StreakMilestone(days: 7, title: "Week of Beauty", symbolName: "flame.fill", bonusPoints: 250, bonusXP: 150),
        StreakMilestone(days: 14, title: "Fortnight Radiance", symbolName: "sparkles", bonusPoints: 500, bonusXP: 300),
        StreakMilestone(days: 30, title: "Monthly Devotee", symbolName: "crown.fill", bonusPoints: 1_200, bonusXP: 750),
        StreakMilestone(days: 60, title: "Season of Glow", symbolName: "star.circle.fill", bonusPoints: 2_500, bonusXP: 1_500),
        StreakMilestone(days: 100, title: "Centurion of Glow", symbolName: "trophy.fill", bonusPoints: 5_000, bonusXP: 3_000),
    ]

    /// The calendar that defines "a day".
    public let calendar: Calendar
    /// How many consecutive missed days the streak survives. `0` = strict.
    public let graceDays: Int
    /// Milestone ladder, ascending by ``StreakMilestone/days``.
    public let milestones: [StreakMilestone]

    /// Creates an engine.
    /// - Parameters:
    ///   - calendar: Defines day boundaries. Inject `.current` in the app.
    ///   - graceDays: Missed days forgiven. Defaults to 1; negative values clamp to 0.
    ///   - milestones: Milestone ladder; sorted ascending on the way in.
    public init(
        calendar: Calendar = .prvLoyalty,
        graceDays: Int = 1,
        milestones: [StreakMilestone] = StreakEngine.standardMilestones
    ) {
        self.calendar = calendar
        self.graceDays = max(0, graceDays)
        self.milestones = milestones.sorted { $0.days < $1.days }
    }

    // MARK: Registering a day

    /// Registers activity on `day` against a raw streak state.
    ///
    /// - Parameters:
    ///   - day: The instant of the check-in; normalized to its start of day.
    ///   - lastActiveDay: The last instant that counted, or `nil` if never.
    ///   - currentStreakDays: The streak length before this check-in.
    /// - Returns: The new streak state and any milestone reached.
    public func register(day: Date, lastActiveDay: Date?, currentStreakDays: Int) -> StreakResult {
        let today = calendar.startOfDay(for: day)
        let previousStreak = max(0, currentStreakDays)

        guard let lastActiveDay else {
            return result(outcome: .started, streak: 1, previous: previousStreak, anchor: today)
        }

        let lastDay = calendar.startOfDay(for: lastActiveDay)
        let gap = calendar.wholeDays(from: lastDay, to: today)

        if gap <= 0 {
            // Already counted today, or the clock moved backwards. Keep the anchor on
            // the recorded day so a backwards clock can never rewind the streak.
            return result(
                outcome: .alreadyCountedToday,
                streak: max(1, previousStreak),
                previous: previousStreak,
                anchor: lastDay
            )
        }

        // An existing anchor means the previous day was earned, so a streak of 0 with
        // an anchor is an inconsistent record: treat it as 1 rather than losing a day.
        let continuedStreak = LoyaltyMath.saturatingAdd(max(1, previousStreak), 1)

        if gap == 1 {
            return result(outcome: .continued, streak: continuedStreak, previous: previousStreak, anchor: today)
        }
        if gap <= 1 + graceDays {
            return result(
                outcome: .continuedWithGrace,
                streak: continuedStreak,
                previous: previousStreak,
                anchor: today
            )
        }
        return result(outcome: .reset, streak: 1, previous: previousStreak, anchor: today)
    }

    /// Registers activity on `day` against a stored ``LoyaltyProfile``.
    public func register(day: Date, profile: LoyaltyProfile) -> StreakResult {
        register(
            day: day,
            lastActiveDay: profile.lastDailyRewardAt,
            currentStreakDays: profile.currentStreakDays
        )
    }

    /// Returns a copy of `profile` with the streak result and any milestone bonus
    /// applied. Pure — the caller decides when to persist.
    public func apply(_ result: StreakResult, to profile: LoyaltyProfile) -> LoyaltyProfile {
        var updated = profile
        updated.currentStreakDays = result.streakDays
        updated.lastDailyRewardAt = result.lastRewardedDay
        updated.xp = LoyaltyMath.saturatingAdd(max(0, profile.xp), result.bonusXP)
        updated.spendablePoints = LoyaltyMath.saturatingAdd(max(0, profile.spendablePoints), result.bonusPoints)
        return updated
    }

    // MARK: Queries

    /// `true` when the profile already claimed on the calendar day containing `now`.
    public func hasClaimed(profile: LoyaltyProfile, on now: Date) -> Bool {
        guard let last = profile.lastDailyRewardAt else { return false }
        return calendar.isDate(last, inSameDayAs: now)
    }

    /// How many more days the client can miss before the streak resets.
    ///
    /// `0` means the streak is lost at the next check-in. Returns `nil` when there is
    /// no streak to lose.
    public func daysOfSlackRemaining(lastActiveDay: Date?, now: Date) -> Int? {
        guard let lastActiveDay else { return nil }
        let gap = calendar.wholeDays(from: lastActiveDay, to: now)
        return max(0, (1 + graceDays) - max(0, gap))
    }

    /// The milestone unlocked by exactly `days`, if any.
    public func milestone(for days: Int) -> StreakMilestone? {
        milestones.first { $0.days == days }
    }

    /// The next milestone strictly above `days`, if any.
    public func nextMilestone(after days: Int) -> StreakMilestone? {
        milestones.first { $0.days > days }
    }

    /// Progress `0...1` from the previous milestone to the next one.
    /// Returns `1` once the final milestone is reached.
    public func progressToNextMilestone(days: Int) -> Double {
        let current = max(0, days)
        guard let next = nextMilestone(after: current) else { return 1 }
        let previous = milestones.last { $0.days <= current }?.days ?? 0
        let span = next.days - previous
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(current - previous) / Double(span)))
    }

    // MARK: Private

    private func result(
        outcome: StreakOutcome,
        streak: Int,
        previous: Int,
        anchor: Date
    ) -> StreakResult {
        StreakResult(
            outcome: outcome,
            streakDays: streak,
            previousStreakDays: previous,
            lastRewardedDay: anchor,
            milestone: outcome.didAdvance ? milestone(for: streak) : nil
        )
    }
}
