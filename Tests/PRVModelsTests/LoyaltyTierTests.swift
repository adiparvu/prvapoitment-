import Foundation
import PRVModels
import Testing

@Suite("LoyaltyTier")
struct LoyaltyTierTests {
    @Test("Thresholds are inclusive: exactly 1 000 XP is Silver")
    func thresholdsAreInclusive() {
        #expect(LoyaltyTier.tier(forXP: 0) == .bronze)
        #expect(LoyaltyTier.tier(forXP: 1_000) == .silver)
        #expect(LoyaltyTier.tier(forXP: 5_000) == .gold)
        #expect(LoyaltyTier.tier(forXP: 15_000) == .diamond)
        #expect(LoyaltyTier.tier(forXP: 40_000) == .black)
    }

    @Test("One XP short of a threshold stays in the lower tier")
    func oneShortStaysLower() {
        #expect(LoyaltyTier.tier(forXP: 999) == .bronze)
        #expect(LoyaltyTier.tier(forXP: 4_999) == .silver)
        #expect(LoyaltyTier.tier(forXP: 14_999) == .gold)
        #expect(LoyaltyTier.tier(forXP: 39_999) == .diamond)
    }

    @Test("Out-of-range XP resolves safely instead of trapping")
    func outOfRangeXPIsSafe() {
        #expect(LoyaltyTier.tier(forXP: -1) == .bronze)
        #expect(LoyaltyTier.tier(forXP: Int.min) == .bronze)
        #expect(LoyaltyTier.tier(forXP: Int.max) == .black)
    }

    @Test("The tier chain climbs Bronze → Black and then stops")
    func tierChainIsComplete() {
        #expect(LoyaltyTier.bronze.next == .silver)
        #expect(LoyaltyTier.silver.next == .gold)
        #expect(LoyaltyTier.gold.next == .diamond)
        #expect(LoyaltyTier.diamond.next == .black)
        #expect(LoyaltyTier.black.next == nil)
        #expect(LoyaltyTier.allCases == [.bronze, .silver, .gold, .diamond, .black])
    }

    @Test("Thresholds increase strictly along the ladder")
    func thresholdsAreStrictlyIncreasing() {
        let thresholds = LoyaltyTier.allCases.map(\.threshold)

        #expect(thresholds == [0, 1_000, 5_000, 15_000, 40_000])
        #expect(zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 < $1 })
        #expect(LoyaltyTier.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test("A profile derives its tier and in-tier progress from XP alone")
    func profileDerivesTierAndProgress() {
        let profile = LoyaltyProfile(userID: ModelFixtures.clientID, xp: 3_000, referralCode: "PRV-K7M2QX")

        #expect(profile.tier == .silver)
        #expect(profile.progressToNextTier == 0.5)
    }

    @Test("The top tier reports full progress rather than dividing by zero")
    func topTierProgressIsComplete() {
        let top = LoyaltyProfile(userID: ModelFixtures.clientID, xp: 90_000, referralCode: "PRV-K7M2QX")

        #expect(top.tier == .black)
        #expect(top.progressToNextTier == 1)
    }

    @Test("A loyalty profile round-trips through the wire format")
    func profileRoundTrips() throws {
        let original = LoyaltyProfile(
            id: LoyaltyProfile.ID("00000000-0000-0000-000C-000000000001"),
            userID: ModelFixtures.clientID,
            xp: 6_450,
            spendablePoints: 1_240,
            achievements: [Achievement.ID("00000000-0000-0000-000D-000000000001")],
            referralCode: "PRV-K7M2QX",
            referredByCode: "PRV-T4W9BC",
            currentStreakDays: 4,
            lastDailyRewardAt: ModelFixtures.reference
        )
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        #expect(decoded.tier == .gold)

        let keys = try PRVWireJSON.wireKeys(for: original)
        #expect(keys.contains("user_id"))
        #expect(keys.contains("spendable_points"))
        #expect(keys.contains("referred_by_code"))
        #expect(keys.contains("last_daily_reward_at"))
        #expect(keys.contains("xp"))
    }
}
