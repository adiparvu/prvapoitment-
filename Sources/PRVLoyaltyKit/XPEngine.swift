import Foundation
import PRVModels

// MARK: - Events

/// Something a client did that the loyalty programme rewards.
///
/// Events are the *only* input to ``XPEngine``. Nothing else — no repository, no
/// clock, no user record — influences an award, which is what makes the reward
/// ledger auditable: replaying a client's event history always reproduces their
/// exact XP and point balance.
public enum LoyaltyEvent: Hashable, Sendable {
    /// A visit that finished and was paid for. `spend` is the amount actually
    /// charged for the visit (after discounts, including add-ons).
    case completedAppointment(spend: Money)
    /// A published review of a salon or professional.
    case review
    /// A referred friend completed their first appointment.
    case referralConverted
    /// The daily check-in ("open the app once a day").
    case dailyOpen
    /// A time-boxed ``LoyaltyChallenge`` reached its target.
    case challengeCompleted
    /// A membership subscription was started.
    case membershipPurchased
}

// MARK: - Award

/// The XP and spendable points one or more ``LoyaltyEvent``s are worth.
///
/// XP is the permanent progression currency — it only ever goes up and drives
/// ``LoyaltyTier``. Points are the *spendable* currency — they are redeemed against
/// services and go down again. Keeping both in a single award means a UI can show
/// "+235 XP · +185 points" from one value.
public struct XPAward: Hashable, Sendable {
    /// Permanent progression XP granted.
    public let xp: Int
    /// Spendable reward points granted.
    public let points: Int
    /// Human-readable explanation, suitable for a wallet ledger row.
    /// Aggregated awards join their reasons with " · ".
    public let reason: String

    /// Creates an award. Negative inputs are clamped to zero — the loyalty ledger
    /// is append-only and never punishes.
    public init(xp: Int, points: Int, reason: String) {
        self.xp = max(0, xp)
        self.points = max(0, points)
        self.reason = reason
    }

    /// The neutral element: no XP, no points, no reason.
    public static let zero = XPAward(xp: 0, points: 0, reason: "")

    /// `true` when the award grants nothing.
    public var isEmpty: Bool { xp == 0 && points == 0 }

    /// Combines two awards, summing both currencies and joining the reasons.
    public static func + (lhs: XPAward, rhs: XPAward) -> XPAward {
        let reasons = [lhs.reason, rhs.reason].filter { !$0.isEmpty }
        return XPAward(
            xp: LoyaltyMath.saturatingAdd(lhs.xp, rhs.xp),
            points: LoyaltyMath.saturatingAdd(lhs.points, rhs.points),
            reason: reasons.joined(separator: " · ")
        )
    }
}

// MARK: - Engine

/// Turns ``LoyaltyEvent``s into ``XPAward``s.
///
/// ### Reward rules (``Rules/standard``)
///
/// | Event                    | XP                                   | Points                     |
/// |--------------------------|--------------------------------------|----------------------------|
/// | `completedAppointment`   | 1 per whole unit spent **+ 50** bonus | 1 per whole unit spent    |
/// | `review`                 | 75                                   | 50                         |
/// | `referralConverted`      | 500                                  | 500                        |
/// | `dailyOpen`              | 10                                   | 5                          |
/// | `challengeCompleted`     | 150                                  | 0 — see below              |
/// | `membershipPurchased`    | 400                                  | 200                        |
///
/// Two deliberate design choices:
///
/// - **Spend is floored to whole currency units.** A €185.60 balayage earns 185 XP,
///   never 185.6. Fractions of a unit, negative amounts (refunds), and amounts above
///   `100_000_000` contribute nothing, so the engine can never produce a nonsense or
///   overflowing balance from hostile input.
/// - **Challenge *points* are not decided here.** Every ``LoyaltyChallenge`` carries
///   its own `pointsReward`, which is what the salon promised the client; the engine
///   only adds the flat completion XP. Use ``award(forCompleting:)`` to get both in a
///   single award.
///
/// The engine is currency-agnostic: it reads `Money.amount` and ignores
/// `Money.currency`, because a salon's loyalty scale is defined in its own currency.
public struct XPEngine: Sendable {
    /// The tunable reward table. Salons on bespoke contracts get their own instance;
    /// everyone else uses ``standard``.
    public struct Rules: Hashable, Sendable {
        /// XP granted per whole currency unit spent.
        public var xpPerCurrencyUnit: Int
        /// Spendable points granted per whole currency unit spent.
        public var pointsPerCurrencyUnit: Int
        /// Flat XP for showing up and completing a visit, regardless of spend.
        public var appointmentVisitBonusXP: Int
        /// XP for publishing a review.
        public var reviewXP: Int
        /// Points for publishing a review.
        public var reviewPoints: Int
        /// XP when a referred friend completes their first appointment.
        public var referralXP: Int
        /// Points when a referred friend completes their first appointment.
        public var referralPoints: Int
        /// XP for the daily check-in.
        public var dailyOpenXP: Int
        /// Points for the daily check-in.
        public var dailyOpenPoints: Int
        /// Flat XP for completing a challenge (points come from the challenge).
        public var challengeXP: Int
        /// XP for starting a membership.
        public var membershipXP: Int
        /// Points for starting a membership.
        public var membershipPoints: Int

        /// Creates a reward table. Every parameter defaults to the platform standard.
        public init(
            xpPerCurrencyUnit: Int = 1,
            pointsPerCurrencyUnit: Int = 1,
            appointmentVisitBonusXP: Int = 50,
            reviewXP: Int = 75,
            reviewPoints: Int = 50,
            referralXP: Int = 500,
            referralPoints: Int = 500,
            dailyOpenXP: Int = 10,
            dailyOpenPoints: Int = 5,
            challengeXP: Int = 150,
            membershipXP: Int = 400,
            membershipPoints: Int = 200
        ) {
            self.xpPerCurrencyUnit = max(0, xpPerCurrencyUnit)
            self.pointsPerCurrencyUnit = max(0, pointsPerCurrencyUnit)
            self.appointmentVisitBonusXP = max(0, appointmentVisitBonusXP)
            self.reviewXP = max(0, reviewXP)
            self.reviewPoints = max(0, reviewPoints)
            self.referralXP = max(0, referralXP)
            self.referralPoints = max(0, referralPoints)
            self.dailyOpenXP = max(0, dailyOpenXP)
            self.dailyOpenPoints = max(0, dailyOpenPoints)
            self.challengeXP = max(0, challengeXP)
            self.membershipXP = max(0, membershipXP)
            self.membershipPoints = max(0, membershipPoints)
        }

        /// The platform-wide reward table documented on ``XPEngine``.
        public static let standard = Rules()
    }

    /// The reward table this engine applies.
    public let rules: Rules

    /// Creates an engine. Defaults to the platform-standard reward table.
    public init(rules: Rules = .standard) {
        self.rules = rules
    }

    // MARK: Awards

    /// The award for a single event.
    ///
    /// - Parameters:
    ///   - event: What the client did.
    ///   - pointsMultiplier: Multiplies the *points* half of the award only — XP is
    ///     never multiplied, so promotions can never distort tier progression. Used
    ///     for `PrepaymentPolicy.rewardPointsMultiplier` (double points for prepaid
    ///     visits) and double-point weekends. Values below 1 are treated as 1.
    /// - Returns: The XP and points earned.
    public func award(for event: LoyaltyEvent, pointsMultiplier: Int = 1) -> XPAward {
        let multiplier = max(1, pointsMultiplier)

        switch event {
        case .completedAppointment(let spend):
            let units = LoyaltyMath.wholeUnits(of: spend)
            let spendXP = LoyaltyMath.saturatingMultiply(units, rules.xpPerCurrencyUnit)
            let spendPoints = LoyaltyMath.saturatingMultiply(units, rules.pointsPerCurrencyUnit)
            return XPAward(
                xp: LoyaltyMath.saturatingAdd(spendXP, rules.appointmentVisitBonusXP),
                points: LoyaltyMath.saturatingMultiply(spendPoints, multiplier),
                reason: "Completed appointment"
            )

        case .review:
            return XPAward(
                xp: rules.reviewXP,
                points: LoyaltyMath.saturatingMultiply(rules.reviewPoints, multiplier),
                reason: "Review published"
            )

        case .referralConverted:
            return XPAward(
                xp: rules.referralXP,
                points: LoyaltyMath.saturatingMultiply(rules.referralPoints, multiplier),
                reason: "Referral converted"
            )

        case .dailyOpen:
            return XPAward(
                xp: rules.dailyOpenXP,
                points: LoyaltyMath.saturatingMultiply(rules.dailyOpenPoints, multiplier),
                reason: "Daily check-in"
            )

        case .challengeCompleted:
            return XPAward(xp: rules.challengeXP, points: 0, reason: "Challenge completed")

        case .membershipPurchased:
            return XPAward(
                xp: rules.membershipXP,
                points: LoyaltyMath.saturatingMultiply(rules.membershipPoints, multiplier),
                reason: "Membership purchased"
            )
        }
    }

    /// The combined award for a batch of events — the shape a nightly reconciliation
    /// job or an optimistic client-side ledger replay needs.
    public func award(for events: [LoyaltyEvent], pointsMultiplier: Int = 1) -> XPAward {
        events.reduce(XPAward.zero) { total, event in
            total + award(for: event, pointsMultiplier: pointsMultiplier)
        }
    }

    /// The award for completing a specific challenge: the flat completion XP from
    /// ``Rules/challengeXP`` plus the points the challenge itself promised.
    ///
    /// Returns ``XPAward/zero`` when the challenge has not actually reached its
    /// target, so a caller can hand any challenge to the engine without pre-checking.
    public func award(forCompleting challenge: LoyaltyChallenge) -> XPAward {
        guard challenge.isCompleted else { return .zero }
        let base = award(for: .challengeCompleted)
        return XPAward(
            xp: base.xp,
            points: max(0, challenge.pointsReward),
            reason: challenge.title
        )
    }

    // MARK: Applying

    /// Returns a copy of `profile` with the award credited.
    ///
    /// Pure: the caller decides when — and whether — to persist the result.
    public func apply(_ award: XPAward, to profile: LoyaltyProfile) -> LoyaltyProfile {
        var updated = profile
        updated.xp = LoyaltyMath.saturatingAdd(max(0, profile.xp), award.xp)
        updated.spendablePoints = LoyaltyMath.saturatingAdd(max(0, profile.spendablePoints), award.points)
        return updated
    }

    /// Spends points from a profile, refusing overdrafts.
    ///
    /// - Returns: The updated profile, or `nil` when the balance is insufficient.
    ///   XP is never touched — spending points must not cost a client their tier.
    public func redeem(points: Int, from profile: LoyaltyProfile) -> LoyaltyProfile? {
        guard points > 0 else { return profile }
        guard profile.spendablePoints >= points else { return nil }
        var updated = profile
        updated.spendablePoints -= points
        return updated
    }
}
