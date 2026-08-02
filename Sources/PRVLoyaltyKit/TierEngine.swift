import Foundation
import PRVModels

// MARK: - Level up

/// What happened when XP was added and the client crossed at least one tier boundary.
///
/// Produced only for genuine promotions — the type existing at all means "throw the
/// confetti". A single large award can skip tiers (a €30 000 wedding contract takes a
/// Bronze client straight past Silver), so ``crossedTiers`` lists every boundary
/// crossed in order and ``newTier`` is the one the client actually lands on.
public struct LevelUpResult: Hashable, Sendable {
    /// The tier held before the award.
    public let previousTier: LoyaltyTier
    /// The tier held after the award.
    public let newTier: LoyaltyTier
    /// Every tier newly reached, in ascending order, ending with ``newTier``.
    public let crossedTiers: [LoyaltyTier]
    /// XP before the award.
    public let previousXP: Int
    /// XP after the award.
    public let newXP: Int

    /// Creates a level-up result.
    public init(
        previousTier: LoyaltyTier,
        newTier: LoyaltyTier,
        crossedTiers: [LoyaltyTier],
        previousXP: Int,
        newXP: Int
    ) {
        self.previousTier = previousTier
        self.newTier = newTier
        self.crossedTiers = crossedTiers
        self.previousXP = previousXP
        self.newXP = newXP
    }

    /// How many tier boundaries were crossed (at least 1).
    public var tiersGained: Int { crossedTiers.count }

    /// `true` when more than one boundary was crossed in a single award.
    public var isMultiTierJump: Bool { crossedTiers.count > 1 }

    /// `true` when the client landed on the top tier.
    public var reachedTopTier: Bool { newTier.next == nil }
}

// MARK: - Engine

/// Everything the app needs to know about ``LoyaltyTier`` progression.
///
/// `LoyaltyTier` owns the thresholds (Bronze 0, Silver 1 000, Gold 5 000,
/// Diamond 15 000, Black 40 000); this engine owns the *arithmetic* around them —
/// ordering, distance to the next tier, in-tier progress, and promotion detection —
/// so no view ever recomputes a threshold by hand.
///
/// Boundaries are **inclusive at the bottom**: exactly 1 000 XP *is* Silver, and
/// 999 XP is still Bronze. Negative XP is clamped to zero rather than trapping,
/// because a corrupted or partially-synced profile must never crash the wallet.
public struct TierEngine: Sendable {
    /// Creates an engine. Stateless — free to create per view body.
    public init() {}

    // MARK: Ordering

    /// Every tier in ascending order.
    public var allTiers: [LoyaltyTier] { LoyaltyTier.allCases }

    /// The position of `tier` in the ladder, `0` for Bronze up to `4` for Black.
    ///
    /// Use this instead of comparing thresholds when you need ordering — it stays
    /// correct if a future tier is inserted with the same threshold as another.
    public func rank(of tier: LoyaltyTier) -> Int {
        LoyaltyTier.allCases.firstIndex(of: tier) ?? 0
    }

    /// `true` when `lhs` sits strictly above `rhs` in the ladder.
    public func isHigher(_ lhs: LoyaltyTier, than rhs: LoyaltyTier) -> Bool {
        rank(of: lhs) > rank(of: rhs)
    }

    // MARK: Lookup

    /// The tier earned by `xp`. Negative values resolve to Bronze.
    public func tier(for xp: Int) -> LoyaltyTier {
        LoyaltyTier.tier(forXP: max(0, xp))
    }

    /// The tier a profile currently holds.
    public func tier(for profile: LoyaltyProfile) -> LoyaltyTier {
        tier(for: profile.xp)
    }

    /// XP still needed to reach the next tier, or `nil` at the top tier.
    ///
    /// Exactly `0` is never returned: reaching a threshold immediately re-targets the
    /// tier above it, so the wallet's "N XP to go" label always counts down to a real
    /// destination.
    public func xpToNextTier(_ xp: Int) -> Int? {
        let clamped = max(0, xp)
        guard let next = tier(for: clamped).next else { return nil }
        return max(0, next.threshold - clamped)
    }

    /// XP still needed by a profile to reach the next tier, or `nil` at the top.
    public func xpToNextTier(for profile: LoyaltyProfile) -> Int? {
        xpToNextTier(profile.xp)
    }

    /// Progress through the *current* tier, `0...1`. Returns `1` at the top tier.
    ///
    /// This is the value to hand to `PRVProgressRing`.
    public func progressToNextTier(_ xp: Int) -> Double {
        let clamped = max(0, xp)
        let current = tier(for: clamped)
        guard let next = current.next else { return 1 }
        let span = next.threshold - current.threshold
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(clamped - current.threshold) / Double(span)))
    }

    /// The half-open XP range a tier covers, e.g. Silver is `1000..<5000`.
    /// The top tier is unbounded and returns `nil`.
    public func xpRange(for tier: LoyaltyTier) -> Range<Int>? {
        guard let next = tier.next else { return nil }
        return tier.threshold ..< next.threshold
    }

    // MARK: Promotion

    /// Detects whether adding `adding` XP promotes the client.
    ///
    /// - Parameters:
    ///   - current: XP before the award. Negative values are clamped to zero.
    ///   - adding: XP about to be granted. Zero or negative never promotes.
    /// - Returns: A ``LevelUpResult`` when at least one boundary is crossed,
    ///   otherwise `nil`.
    public func willLevelUp(current: Int, adding: Int) -> LevelUpResult? {
        guard adding > 0 else { return nil }
        let previousXP = max(0, current)
        let newXP = LoyaltyMath.saturatingAdd(previousXP, adding)

        let previousTier = tier(for: previousXP)
        let newTier = tier(for: newXP)
        guard isHigher(newTier, than: previousTier) else { return nil }

        let lowerRank = rank(of: previousTier)
        let upperRank = rank(of: newTier)
        let crossed = LoyaltyTier.allCases.filter { candidate in
            let candidateRank = rank(of: candidate)
            return candidateRank > lowerRank && candidateRank <= upperRank
        }

        return LevelUpResult(
            previousTier: previousTier,
            newTier: newTier,
            crossedTiers: crossed,
            previousXP: previousXP,
            newXP: newXP
        )
    }

    /// Detects whether an ``XPAward`` promotes the profile.
    public func willLevelUp(_ profile: LoyaltyProfile, earning award: XPAward) -> LevelUpResult? {
        willLevelUp(current: profile.xp, adding: award.xp)
    }
}
