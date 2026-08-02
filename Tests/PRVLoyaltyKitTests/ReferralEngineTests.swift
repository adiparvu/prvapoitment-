import Foundation
import PRVLoyaltyKit
import PRVModels
import Testing

@Suite("ReferralEngine")
struct ReferralEngineTests {
    private let engine = ReferralEngine()

    // MARK: Alphabet

    @Test("The alphabet is 32 unambiguous characters with no O, 0, I, or 1")
    func alphabetExcludesConfusableCharacters() {
        let alphabet = ReferralEngine.alphabet

        #expect(alphabet.count == 32)
        #expect(Set(alphabet).count == 32)
        #expect(!alphabet.contains("O"))
        #expect(!alphabet.contains("0"))
        #expect(!alphabet.contains("I"))
        #expect(!alphabet.contains("1"))
        #expect(alphabet.allSatisfy { $0.isUppercase || $0.isNumber })
    }

    // MARK: Minting

    @Test("A minted code is PRV- followed by six alphabet characters")
    func mintedCodesMatchTheFormat() {
        let code = engine.makeCode(seed: 42)

        #expect(code.count == ReferralEngine.codeLength)
        #expect(code.count == 10)
        #expect(code.hasPrefix("PRV-"))
        #expect(engine.isValidCode(code))

        let body = code.dropFirst(4)
        #expect(body.count == 6)
        #expect(body.allSatisfy { ReferralEngine.alphabet.contains($0) })
    }

    @Test("Minting is deterministic: equal seeds mint equal codes")
    func mintingIsSeedDeterministic() {
        #expect(engine.makeCode(seed: 2_026) == engine.makeCode(seed: 2_026))
        #expect(engine.makeCode(seed: 1) != engine.makeCode(seed: 2))
    }

    @Test("A large batch mints unique, well-formed codes (collision sampling)")
    func batchMintingAvoidsCollisions() {
        let codes = engine.makeCodes(count: 5_000, seed: 7)

        #expect(codes.count == 5_000)
        #expect(Set(codes).count == 5_000)
        #expect(codes.allSatisfy { engine.isValidCode($0) })
        // Reproducible: the same seed replays the same batch, byte for byte.
        #expect(engine.makeCodes(count: 5_000, seed: 7) == codes)
    }

    @Test("Batch minting handles degenerate counts")
    func batchMintingHandlesDegenerateCounts() {
        #expect(engine.makeCodes(count: 0, seed: 1).isEmpty)
        #expect(engine.makeCodes(count: -3, seed: 1).isEmpty)
        #expect(engine.makeCodes(count: 1, seed: 1).count == 1)
    }

    @Test("Any generator can mint, including an unseeded system one")
    func mintingAcceptsAnyGenerator() {
        var generator = SystemRandomNumberGenerator()
        let code = engine.makeCode(using: &generator)

        #expect(engine.isValidCode(code))
    }

    // MARK: Validation & normalization

    @Test("Validation rejects anything that is not exactly the canonical format")
    func validationIsStrict() {
        #expect(engine.isValidCode("PRV-K7M2QX"))
        #expect(!engine.isValidCode("prv-k7m2qx"))       // wrong case
        #expect(!engine.isValidCode("PRV-K7M2Q"))        // too short
        #expect(!engine.isValidCode("PRV-K7M2QXX"))      // too long
        #expect(!engine.isValidCode("PRVK7M2QX"))        // missing separator
        #expect(!engine.isValidCode("PRV-K7M2QO"))       // O is not in the alphabet
        #expect(!engine.isValidCode("PRV-K7M2Q0"))       // 0 is not in the alphabet
        #expect(!engine.isValidCode("PRV-K7M2QI"))       // I is not in the alphabet
        #expect(!engine.isValidCode("PRV-K7M2Q1"))       // 1 is not in the alphabet
        #expect(!engine.isValidCode(""))
    }

    @Test("Normalization cleans real-world input into canonical form")
    func normalizationCleansInput() {
        #expect(engine.normalized(" prv-k7m2qx ") == "PRV-K7M2QX")
        #expect(engine.normalized("PRVK7M2QX") == "PRV-K7M2QX")
        #expect(engine.normalized("k7m2qx") == "PRV-K7M2QX")
        #expect(engine.normalized("prv k7m2qx") == "PRV-K7M2QX")
        #expect(engine.isValidCode(engine.normalized("k7 m2 qx")))
    }

    @Test("Normalization never guesses at confusable characters")
    func normalizationDoesNotMapConfusableCharacters() {
        // A misread stays a misread — and therefore an explicit validation failure —
        // instead of silently crediting the wrong account.
        #expect(engine.normalized("K7M2Q0") == "PRV-K7M2Q0")
        #expect(!engine.isValidCode(engine.normalized("K7M2Q0")))
    }

    // MARK: Evaluation

    private func referrer(code: String = "PRV-K7M2QX") -> LoyaltyProfile {
        LoyaltyFixtures.profile(userID: LoyaltyFixtures.referrerID, referralCode: code)
    }

    private func referee(usedCode: String?) -> LoyaltyProfile {
        LoyaltyFixtures.profile(
            userID: LoyaltyFixtures.refereeID,
            referralCode: "PRV-T4W9BC",
            referredByCode: usedCode
        )
    }

    @Test("A converted referral pays both sides")
    func convertedReferralPaysBothSides() throws {
        let outcome = engine.evaluate(
            referrer: referrer(),
            referee: referee(usedCode: "PRV-K7M2QX"),
            refereeCompletedFirstAppointment: true
        )

        let reward = try #require(outcome.reward)
        #expect(outcome.isRewarded)
        #expect(reward.referrerCredit == Money(15))
        #expect(reward.referrerPoints == 500)
        #expect(reward.refereeCredit == Money(10))
        #expect(reward.refereePoints == 250)
        #expect(reward.referrerAward.xp == 500)
        #expect(reward.refereeAward.points == 250)
    }

    @Test("The payout waits for a completed first appointment, not a sign-up")
    func rewardIsGatedOnConversion() {
        let outcome = engine.evaluate(
            referrer: referrer(),
            referee: referee(usedCode: "prv k7m2qx"),
            refereeCompletedFirstAppointment: false
        )

        #expect(outcome == .pending)
        #expect(!outcome.isRewarded)
        #expect(outcome.reward == nil)
    }

    @Test("Self-referral is rejected before anything else")
    func selfReferralIsRejected() {
        let profile = LoyaltyFixtures.profile(
            userID: LoyaltyFixtures.referrerID,
            referralCode: "PRV-K7M2QX",
            referredByCode: "PRV-K7M2QX"
        )
        let outcome = engine.evaluate(
            referrer: profile,
            referee: profile,
            refereeCompletedFirstAppointment: true
        )

        #expect(outcome == .rejected(.selfReferral))
    }

    @Test("A malformed referrer code and a mismatched code are distinct rejections")
    func rejectionsAreSpecific() {
        let malformed = engine.evaluate(
            referrer: referrer(code: "SOFIA-GLOW"),
            referee: referee(usedCode: "SOFIA-GLOW"),
            refereeCompletedFirstAppointment: true
        )
        #expect(malformed == .rejected(.malformedReferrerCode))

        let mismatch = engine.evaluate(
            referrer: referrer(),
            referee: referee(usedCode: "PRV-ZZZZZZ"),
            refereeCompletedFirstAppointment: true
        )
        #expect(mismatch == .rejected(.codeMismatch))

        let noCode = engine.evaluate(
            referrer: referrer(),
            referee: referee(usedCode: nil),
            refereeCompletedFirstAppointment: true
        )
        #expect(noCode == .rejected(.codeMismatch))
    }

    @Test("A bespoke reward table flows through to the payout")
    func customRewardRulesFlowThrough() {
        let generous = ReferralEngine(
            rules: ReferralRewardRules(
                referrerCredit: Money(50),
                referrerPoints: 1_000,
                referrerXP: 1_000,
                refereeCredit: Money(25),
                refereePoints: 500,
                refereeXP: 250
            )
        )
        let reward = generous.reward()

        #expect(reward.referrerCredit == Money(50))
        #expect(reward.refereePoints == 500)
        #expect(!generous.rewardExplanation().isEmpty)
    }
}
