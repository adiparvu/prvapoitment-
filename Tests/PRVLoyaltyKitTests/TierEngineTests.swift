import Foundation
import PRVLoyaltyKit
import PRVModels
import Testing

@Suite("TierEngine")
struct TierEngineTests {
    private let engine = TierEngine()

    // MARK: Boundaries

    @Test("Each threshold is inclusive at the bottom")
    func thresholdsAreInclusive() {
        #expect(engine.tier(for: 0) == .bronze)
        #expect(engine.tier(for: 1_000) == .silver)
        #expect(engine.tier(for: 5_000) == .gold)
        #expect(engine.tier(for: 15_000) == .diamond)
        #expect(engine.tier(for: 40_000) == .black)
    }

    @Test("One XP below a threshold is still the lower tier")
    func oneBelowThresholdStaysLower() {
        #expect(engine.tier(for: 999) == .bronze)
        #expect(engine.tier(for: 4_999) == .silver)
        #expect(engine.tier(for: 14_999) == .gold)
        #expect(engine.tier(for: 39_999) == .diamond)
    }

    @Test("Absurd XP is safe: negatives clamp to Bronze, huge values cap at Black")
    func extremeXPIsClamped() {
        #expect(engine.tier(for: -1) == .bronze)
        #expect(engine.tier(for: Int.min) == .bronze)
        #expect(engine.tier(for: Int.max) == .black)
    }

    // MARK: Distance & progress

    @Test("Distance to the next tier counts down to a real destination")
    func xpToNextTierCountsDown() {
        #expect(engine.xpToNextTier(0) == 1_000)
        #expect(engine.xpToNextTier(999) == 1)
        // Landing exactly on Silver immediately re-targets Gold.
        #expect(engine.xpToNextTier(1_000) == 4_000)
        #expect(engine.xpToNextTier(14_999) == 1)
        #expect(engine.xpToNextTier(15_000) == 25_000)
    }

    @Test("The top tier has nowhere left to go")
    func topTierHasNoNextTier() {
        #expect(engine.xpToNextTier(40_000) == nil)
        #expect(engine.xpToNextTier(1_000_000) == nil)
        #expect(engine.progressToNextTier(40_000) == 1)
        #expect(engine.xpRange(for: .black) == nil)
    }

    @Test("In-tier progress runs 0…1 between the surrounding thresholds")
    func progressIsMeasuredWithinTheCurrentTier() {
        #expect(engine.progressToNextTier(1_000) == 0)
        #expect(engine.progressToNextTier(3_000) == 0.5)
        #expect(engine.progressToNextTier(4_999) < 1)
        #expect(engine.progressToNextTier(-500) == 0)
    }

    @Test("Tier ranges are half-open and tile the ladder without gaps")
    func xpRangesTileTheLadder() {
        #expect(engine.xpRange(for: .bronze) == 0 ..< 1_000)
        #expect(engine.xpRange(for: .silver) == 1_000 ..< 5_000)
        #expect(engine.xpRange(for: .gold) == 5_000 ..< 15_000)
        #expect(engine.xpRange(for: .diamond) == 15_000 ..< 40_000)
    }

    // MARK: Ordering

    @Test("Rank orders the ladder from Bronze to Black")
    func rankOrdersTheLadder() {
        #expect(engine.rank(of: .bronze) == 0)
        #expect(engine.rank(of: .black) == 4)
        #expect(engine.isHigher(.gold, than: .silver))
        #expect(!engine.isHigher(.gold, than: .gold))
        #expect(!engine.isHigher(.silver, than: .diamond))
        #expect(engine.allTiers == [.bronze, .silver, .gold, .diamond, .black])
    }

    // MARK: Level up

    @Test("Staying inside a tier is not a level up")
    func noLevelUpWithinATier() {
        #expect(engine.willLevelUp(current: 100, adding: 200) == nil)
        #expect(engine.willLevelUp(current: 5_000, adding: 4_000) == nil)
    }

    @Test("Crossing a threshold exactly is a level up")
    func crossingAThresholdExactlyLevelsUp() throws {
        let result = try #require(engine.willLevelUp(current: 900, adding: 100))

        #expect(result.previousTier == .bronze)
        #expect(result.newTier == .silver)
        #expect(result.crossedTiers == [.silver])
        #expect(result.tiersGained == 1)
        #expect(result.previousXP == 900)
        #expect(result.newXP == 1_000)
        #expect(!result.isMultiTierJump)
        #expect(!result.reachedTopTier)
    }

    @Test("One enormous award can skip tiers, and every crossing is reported")
    func multiTierJumpsListEveryCrossing() throws {
        let result = try #require(engine.willLevelUp(current: 500, adding: 39_500))

        #expect(result.previousTier == .bronze)
        #expect(result.newTier == .black)
        #expect(result.crossedTiers == [.silver, .gold, .diamond, .black])
        #expect(result.tiersGained == 4)
        #expect(result.isMultiTierJump)
        #expect(result.reachedTopTier)
    }

    @Test("Zero or negative XP never promotes")
    func nonPositiveAwardsNeverPromote() {
        #expect(engine.willLevelUp(current: 999, adding: 0) == nil)
        #expect(engine.willLevelUp(current: 999, adding: -5_000) == nil)
    }

    @Test("An overflowing award saturates onto the top tier instead of trapping")
    func hugeAwardsSaturate() throws {
        let result = try #require(engine.willLevelUp(current: 39_000, adding: Int.max))

        #expect(result.previousTier == .diamond)
        #expect(result.newTier == .black)
        #expect(result.newXP == Int.max)
    }

    @Test("Level up can be checked straight from a profile and an award")
    func levelUpReadsProfilesAndAwards() throws {
        let profile = LoyaltyFixtures.profile(xp: 4_900)
        let award = XPAward(xp: 235, points: 185, reason: "Completed appointment")

        let result = try #require(engine.willLevelUp(profile, earning: award))
        #expect(result.newTier == .gold)
        #expect(engine.tier(for: profile) == .silver)
        #expect(engine.xpToNextTier(for: profile) == 100)
    }
}
