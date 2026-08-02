import Foundation
import PRVModels

// The primitives every loyalty engine in this kit is built from. Everything here is
// pure value semantics with an explicitly injected `Calendar` and an explicitly
// injected seed — no `Date.now`, no `SystemRandomNumberGenerator`, no global state —
// so XP, tiers, streaks, and referral codes are byte-for-byte reproducible on device,
// in previews, and on CI.

// MARK: - Calendar

extension Calendar {
    /// The calendar the loyalty engines fall back to when the caller injects nothing.
    ///
    /// Deliberately pinned to the Gregorian calendar in UTC with the POSIX locale so
    /// streak arithmetic is reproducible across devices, regions, and test runs.
    ///
    /// Production call sites should inject the calendar that matches the *client's*
    /// wall clock (usually `.current`), because "a day" in a daily-streak feature is
    /// the day the client experiences, not a server day.
    public static let prvLoyalty: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Whole calendar days from the day containing `start` to the day containing `end`.
    ///
    /// Both instants are normalized to their start of day first, so the result counts
    /// *calendar* days rather than 24-hour periods: 23:59 today to 00:01 tomorrow is
    /// one day, and daylight-saving transitions never produce an off-by-one.
    /// The result is negative when `end` precedes `start`.
    func wholeDays(from start: Date, to end: Date) -> Int {
        let fromDay = startOfDay(for: start)
        let toDay = startOfDay(for: end)
        return dateComponents([.day], from: fromDay, to: toDay).day ?? 0
    }
}

// MARK: - Deterministic randomness

/// A seeded, portable pseudo-random generator (SplitMix64).
///
/// The loyalty kit never touches `SystemRandomNumberGenerator` internally: referral
/// codes are generated from an explicit seed so a given seed always yields the same
/// code sequence on every platform and in every test run. Callers that genuinely want
/// unpredictable output pass `SystemRandomNumberGenerator` to
/// ``ReferralEngine/makeCode(using:)``.
///
/// SplitMix64 is chosen for being tiny, allocation-free, and free of the bad low-bit
/// behaviour of naive linear congruential generators — good enough for code minting,
/// and never used for anything security-sensitive.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    /// Creates a generator for the given seed. Equal seeds produce equal sequences.
    public init(seed: UInt64) {
        self.state = seed
    }

    /// Returns the next 64 bits of the sequence.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Money → whole units

enum LoyaltyMath {
    /// The largest spend the XP engine will count, guarding the `Decimal → Int`
    /// conversion against absurd or hostile inputs.
    static let maximumCountableUnits = 100_000_000

    /// Whole currency units in `money`, floored, clamped to `0...maximumCountableUnits`.
    ///
    /// Loyalty never rewards fractions of a unit and never rewards refunds, so a
    /// negative or fractional amount contributes only its floored positive part.
    static func wholeUnits(of money: Money) -> Int {
        guard money.amount > 0 else { return 0 }
        let capped = min(money.amount, Decimal(maximumCountableUnits))
        var value = capped
        var floored = Decimal()
        NSDecimalRound(&floored, &value, 0, .down)
        return NSDecimalNumber(decimal: floored).intValue
    }

    /// Adds two counts, saturating at `Int.max` instead of trapping.
    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? (rhs > 0 ? Int.max : Int.min) : sum
    }

    /// Multiplies two counts, saturating at `Int.max` instead of trapping.
    static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }
}
