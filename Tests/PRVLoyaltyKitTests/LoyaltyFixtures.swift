import Foundation
import PRVLoyaltyKit
import PRVModels

/// Deterministic loyalty fixtures.
///
/// Every date in these tests comes from here. The reference week is **Monday
/// 2 March 2026**, matching the booking suite so the two kits tell one story. All
/// arithmetic runs through a fixed UTC Gregorian calendar, so streak results never
/// depend on the machine's region, locale, or daylight-saving rules — and `Date.now`
/// never appears in an assertion.
enum LoyaltyFixtures {
    // MARK: Calendar & dates

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    /// Monday 2 March 2026, midnight.
    static var monday: Date { date(2026, 3, 2) }
    /// Tuesday 3 March 2026, midnight.
    static var tuesday: Date { date(2026, 3, 3) }
    /// Wednesday 4 March 2026, midnight.
    static var wednesday: Date { date(2026, 3, 4) }
    /// Thursday 5 March 2026, midnight.
    static var thursday: Date { date(2026, 3, 5) }
    /// Friday 6 March 2026, midnight.
    static var friday: Date { date(2026, 3, 6) }

    static func mondayAt(_ hour: Int, _ minute: Int = 0) -> Date { date(2026, 3, 2, hour, minute) }
    static func tuesdayAt(_ hour: Int, _ minute: Int = 0) -> Date { date(2026, 3, 3, hour, minute) }

    // MARK: Money

    /// Exact decimal money, built from a string so no binary floating-point
    /// approximation ever reaches an assertion.
    static func money(_ literal: String, _ currency: Currency = .eur) -> Money {
        Money(Decimal(string: literal) ?? 0, currency)
    }

    // MARK: Identifiers

    static let referrerID = User.ID("00000000-0000-0000-0000-0000000000A1")
    static let refereeID = User.ID("00000000-0000-0000-0000-0000000000A2")

    // MARK: Profiles

    /// A loyalty profile with explicit, fully specified state.
    static func profile(
        userID: User.ID = referrerID,
        xp: Int = 0,
        points: Int = 0,
        referralCode: String = "PRV-K7M2QX",
        referredByCode: String? = nil,
        streakDays: Int = 0,
        lastDailyRewardAt: Date? = nil
    ) -> LoyaltyProfile {
        LoyaltyProfile(
            userID: userID,
            xp: xp,
            spendablePoints: points,
            referralCode: referralCode,
            referredByCode: referredByCode,
            currentStreakDays: streakDays,
            lastDailyRewardAt: lastDailyRewardAt
        )
    }

    /// A challenge whose progress can be set precisely.
    static func challenge(
        title: String = "Monthly Ritual",
        target: Int = 3,
        progress: Int = 3,
        pointsReward: Int = 500
    ) -> LoyaltyChallenge {
        LoyaltyChallenge(
            title: title,
            details: "Visit 3 times this month",
            symbolName: "flame.fill",
            targetCount: target,
            progressCount: progress,
            pointsReward: pointsReward,
            endsAt: date(2026, 3, 31)
        )
    }
}
