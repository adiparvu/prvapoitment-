import Foundation
import PRVLoyaltyKit
import PRVModels
import Testing

@Suite("XPEngine")
struct XPEngineTests {
    private let engine = XPEngine()

    // MARK: Spend-driven awards

    @Test("Spend earns 1 XP per whole unit plus the flat visit bonus")
    func appointmentAwardsSpendPlusVisitBonus() {
        let award = engine.award(for: .completedAppointment(spend: Money(185)))

        #expect(award.xp == 235)
        #expect(award.points == 185)
        #expect(award.reason == "Completed appointment")
    }

    @Test("Fractions of a currency unit are floored, never rounded up")
    func spendIsFloored() {
        let award = engine.award(for: .completedAppointment(spend: LoyaltyFixtures.money("185.99")))

        #expect(award.xp == 235)
        #expect(award.points == 185)
    }

    @Test("A zero or refunded visit still earns the visit bonus but no spend points")
    func nonPositiveSpendEarnsOnlyTheVisitBonus() {
        let free = engine.award(for: .completedAppointment(spend: Money(0)))
        let refunded = engine.award(for: .completedAppointment(spend: Money(-120)))

        #expect(free.xp == 50)
        #expect(free.points == 0)
        #expect(refunded.xp == 50)
        #expect(refunded.points == 0)
    }

    @Test("Currency is ignored — the loyalty scale is defined in the salon's own units")
    func awardIsCurrencyAgnostic() {
        let euros = engine.award(for: .completedAppointment(spend: Money(75, .eur)))
        let pounds = engine.award(for: .completedAppointment(spend: Money(75, .gbp)))

        #expect(euros == pounds)
    }

    // MARK: Flat awards

    @Test("Publishing a review pays 75 XP and 50 points")
    func reviewPaysItsRate() {
        let award = engine.award(for: .review)

        #expect(award.xp == 75)
        #expect(award.points == 50)
        #expect(award.reason == "Review published")
    }

    @Test("The remaining flat events pay the documented rates")
    func flatEventsPayTheirDocumentedRates() {
        let referral = engine.award(for: .referralConverted)
        #expect(referral.xp == 500)
        #expect(referral.points == 500)

        let daily = engine.award(for: .dailyOpen)
        #expect(daily.xp == 10)
        #expect(daily.points == 5)

        // Challenge points belong to the challenge, not the engine.
        let challenge = engine.award(for: .challengeCompleted)
        #expect(challenge.xp == 150)
        #expect(challenge.points == 0)

        let membership = engine.award(for: .membershipPurchased)
        #expect(membership.xp == 400)
        #expect(membership.points == 200)
    }

    // MARK: Multipliers

    @Test("A points multiplier doubles points but never distorts tier progression")
    func pointsMultiplierLeavesXPUntouched() {
        let single = engine.award(for: .completedAppointment(spend: Money(100)))
        let doubled = engine.award(for: .completedAppointment(spend: Money(100)), pointsMultiplier: 2)

        #expect(single.points == 100)
        #expect(doubled.points == 200)
        #expect(doubled.xp == single.xp)
    }

    @Test("Multipliers below 1 are treated as 1 rather than erasing the reward")
    func multiplierIsClampedToOne() {
        let zeroed = engine.award(for: .review, pointsMultiplier: 0)
        let negative = engine.award(for: .review, pointsMultiplier: -5)

        #expect(zeroed.points == 50)
        #expect(negative.points == 50)
    }

    // MARK: Aggregation

    @Test("A batch of events aggregates both currencies and joins the reasons")
    func batchAwardsAggregate() {
        let award = engine.award(for: [
            .completedAppointment(spend: Money(100)),
            .review,
            .dailyOpen,
        ])

        #expect(award.xp == 150 + 75 + 10)
        #expect(award.points == 100 + 50 + 5)
        #expect(award.reason == "Completed appointment · Review published · Daily check-in")
    }

    @Test("The empty batch is the neutral award")
    func emptyBatchIsZero() {
        let award = engine.award(for: [])

        #expect(award == XPAward.zero)
        #expect(award.isEmpty)
        #expect(award.reason.isEmpty)
    }

    // MARK: Challenges

    @Test("Completing a challenge pays flat XP plus the challenge's own points")
    func challengeCombinesFlatXPWithItsOwnPoints() {
        let award = engine.award(forCompleting: LoyaltyFixtures.challenge(pointsReward: 500))

        #expect(award.xp == 150)
        #expect(award.points == 500)
        #expect(award.reason == "Monthly Ritual")
    }

    @Test("A challenge short of its target pays nothing")
    func unfinishedChallengePaysNothing() {
        let award = engine.award(forCompleting: LoyaltyFixtures.challenge(target: 3, progress: 2))

        #expect(award == XPAward.zero)
    }

    // MARK: Applying

    @Test("Applying an award credits a copy and leaves the original untouched")
    func applyIsPure() {
        let profile = LoyaltyFixtures.profile(xp: 900, points: 40)
        let updated = engine.apply(engine.award(for: .review), to: profile)

        #expect(updated.xp == 975)
        #expect(updated.spendablePoints == 90)
        #expect(profile.xp == 900)
        #expect(profile.spendablePoints == 40)
        #expect(updated.id == profile.id)
    }

    @Test("Redeeming points never touches XP and refuses overdrafts")
    func redeemRefusesOverdrafts() {
        let profile = LoyaltyFixtures.profile(xp: 6_450, points: 300)

        let spent = engine.redeem(points: 250, from: profile)
        #expect(spent?.spendablePoints == 50)
        #expect(spent?.xp == 6_450)

        #expect(engine.redeem(points: 301, from: profile) == nil)
        #expect(engine.redeem(points: 300, from: profile)?.spendablePoints == 0)
    }

    // MARK: Custom rules

    @Test("A bespoke reward table replaces the standard rates")
    func customRulesOverrideTheStandardTable() {
        let generous = XPEngine(
            rules: XPEngine.Rules(
                xpPerCurrencyUnit: 2,
                pointsPerCurrencyUnit: 3,
                appointmentVisitBonusXP: 0
            )
        )
        let award = generous.award(for: .completedAppointment(spend: Money(50)))

        #expect(award.xp == 100)
        #expect(award.points == 150)
    }
}
