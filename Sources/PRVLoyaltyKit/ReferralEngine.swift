import Foundation
import PRVModels

// MARK: - Rewards

/// What a converted referral pays out, to both sides.
///
/// Double-sided by design: the referrer gets paid for the introduction, the referee
/// gets a reason to accept it. Both halves are ``Money`` store credit plus loyalty
/// points, never a discount on a specific service, so the salon keeps full price on
/// the books and the platform carries the incentive.
public struct ReferralRewardRules: Hashable, Sendable {
    /// Store credit granted to the referrer on conversion.
    public var referrerCredit: Money
    /// Spendable points granted to the referrer on conversion.
    public var referrerPoints: Int
    /// XP granted to the referrer on conversion.
    public var referrerXP: Int
    /// Store credit granted to the new client on conversion.
    public var refereeCredit: Money
    /// Spendable points granted to the new client on conversion.
    public var refereePoints: Int
    /// XP granted to the new client on conversion.
    public var refereeXP: Int

    /// Creates a reward table. Every parameter defaults to the platform standard.
    public init(
        referrerCredit: Money = Money(15),
        referrerPoints: Int = 500,
        referrerXP: Int = 500,
        refereeCredit: Money = Money(10),
        refereePoints: Int = 250,
        refereeXP: Int = 100
    ) {
        self.referrerCredit = referrerCredit
        self.referrerPoints = max(0, referrerPoints)
        self.referrerXP = max(0, referrerXP)
        self.refereeCredit = refereeCredit
        self.refereePoints = max(0, refereePoints)
        self.refereeXP = max(0, refereeXP)
    }

    /// The platform-wide referral reward table.
    public static let standard = ReferralRewardRules()
}

/// The concrete payout for one converted referral.
public struct ReferralReward: Hashable, Sendable {
    /// Store credit for the referrer.
    public let referrerCredit: Money
    /// Points for the referrer.
    public let referrerPoints: Int
    /// XP for the referrer.
    public let referrerXP: Int
    /// Store credit for the new client.
    public let refereeCredit: Money
    /// Points for the new client.
    public let refereePoints: Int
    /// XP for the new client.
    public let refereeXP: Int

    /// Creates a payout.
    public init(
        referrerCredit: Money,
        referrerPoints: Int,
        referrerXP: Int,
        refereeCredit: Money,
        refereePoints: Int,
        refereeXP: Int
    ) {
        self.referrerCredit = referrerCredit
        self.referrerPoints = referrerPoints
        self.referrerXP = referrerXP
        self.refereeCredit = refereeCredit
        self.refereePoints = refereePoints
        self.refereeXP = refereeXP
    }

    /// The referrer's half expressed as an ``XPAward``, ready for
    /// ``XPEngine/apply(_:to:)``.
    public var referrerAward: XPAward {
        XPAward(xp: referrerXP, points: referrerPoints, reason: "Referral converted")
    }

    /// The new client's half expressed as an ``XPAward``.
    public var refereeAward: XPAward {
        XPAward(xp: refereeXP, points: refereePoints, reason: "Welcome bonus")
    }
}

// MARK: - Outcome

/// Why a referral pairing cannot be paid out.
public enum ReferralRejection: String, Hashable, Sendable, CaseIterable, Error {
    /// The referrer's code is not a well-formed `PRV-XXXXXX` code.
    case malformedReferrerCode = "malformed_referrer_code"
    /// The new client did not sign up with this referrer's code.
    case codeMismatch = "code_mismatch"
    /// Both profiles belong to the same person.
    case selfReferral = "self_referral"
}

/// The result of evaluating a referral pairing.
public enum ReferralOutcome: Hashable, Sendable {
    /// Valid and converted — pay both sides.
    case rewarded(ReferralReward)
    /// Valid pairing, but the new client has not completed a first appointment yet.
    case pending
    /// Not payable, with the reason.
    case rejected(ReferralRejection)

    /// The payout when the referral converted, otherwise `nil`.
    public var reward: ReferralReward? {
        if case .rewarded(let reward) = self { return reward }
        return nil
    }

    /// `true` when both sides should be credited.
    public var isRewarded: Bool { reward != nil }
}

// MARK: - Engine

/// Mints and validates referral codes, and decides what a converted referral pays.
///
/// ### Code format
///
/// `PRV-XXXXXX` — a fixed brand prefix, a hyphen, then six characters drawn from a
/// deliberately **unambiguous 32-character alphabet**:
///
/// ```
/// ABCDEFGHJKLMNPQRSTUVWXYZ23456789
/// ```
///
/// `I`, `O`, `0`, and `1` are all excluded. The usual trick is to *map* confusable
/// characters on input (`O → 0`), but that only moves the ambiguity: a client reading
/// a code aloud still can't tell which was meant. Excluding all four members of both
/// confusable pairs means a misread is a validation error the client can see and fix,
/// never a silent credit to the wrong account. Six characters over 32 symbols gives
/// 32⁶ ≈ 1.07 billion codes.
///
/// ### Determinism
///
/// Codes are minted from an explicit seed (``makeCode(seed:)``) or an explicit
/// generator (``makeCode(using:)``). The engine never reaches for the system RNG on
/// its own, so tests, previews, and migration scripts are reproducible. Production
/// mints pass `SystemRandomNumberGenerator` — and, because collisions are possible in
/// any random scheme, the persistence layer must still enforce a uniqueness
/// constraint; ``makeCodes(count:seed:)`` guarantees uniqueness only within its batch.
public struct ReferralEngine: Sendable {
    /// The unambiguous code alphabet — no `I`, `O`, `0`, or `1`.
    public static let alphabet: [Character] = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    /// The brand prefix every referral code carries.
    public static let codePrefix = "PRV"
    /// The separator between the prefix and the body.
    public static let codeSeparator: Character = "-"
    /// How many alphabet characters follow the separator.
    public static let codeBodyLength = 6
    /// Total character count of a well-formed code, e.g. `"PRV-K7M2QX"`.
    public static let codeLength = codePrefix.count + 1 + codeBodyLength

    /// The reward table this engine applies.
    public let rules: ReferralRewardRules

    /// Creates an engine. Defaults to the platform-standard reward table.
    public init(rules: ReferralRewardRules = .standard) {
        self.rules = rules
    }

    // MARK: Minting

    /// Mints a code using the given generator.
    ///
    /// Pass `SystemRandomNumberGenerator` in production and ``SeededGenerator`` in
    /// tests, previews, and backfills.
    public func makeCode<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        var body = ""
        body.reserveCapacity(Self.codeBodyLength)
        for _ in 0 ..< Self.codeBodyLength {
            let index = Int.random(in: 0 ..< Self.alphabet.count, using: &generator)
            body.append(Self.alphabet[index])
        }
        return "\(Self.codePrefix)\(Self.codeSeparator)\(body)"
    }

    /// Mints the code for a given seed. Equal seeds always produce equal codes.
    public func makeCode(seed: UInt64) -> String {
        var generator = SeededGenerator(seed: seed)
        return makeCode(using: &generator)
    }

    /// Mints `count` codes that are unique *within the returned batch*.
    ///
    /// The generator is advanced once per attempt and duplicates are discarded, so the
    /// result is deterministic for a given `seed` and `count`. A bounded attempt
    /// budget keeps the call finite even if a caller asks for more codes than the
    /// alphabet can comfortably supply.
    public func makeCodes(count: Int, seed: UInt64) -> [String] {
        guard count > 0 else { return [] }
        var generator = SeededGenerator(seed: seed)
        var seen = Set<String>()
        var codes: [String] = []
        codes.reserveCapacity(count)

        var attemptsRemaining = LoyaltyMath.saturatingAdd(
            LoyaltyMath.saturatingMultiply(count, 64),
            1_024
        )
        while codes.count < count, attemptsRemaining > 0 {
            attemptsRemaining -= 1
            let code = makeCode(using: &generator)
            if seen.insert(code).inserted {
                codes.append(code)
            }
        }
        return codes
    }

    // MARK: Validation

    /// Cleans user input into canonical form before validation.
    ///
    /// Uppercases, strips whitespace and hyphens, and re-applies the `PRV-` prefix.
    /// A bare six-character body (`"k7m2qx"`) is accepted as shorthand and becomes
    /// `"PRV-K7M2QX"`. Nothing is character-mapped: see the type documentation for
    /// why confusable characters are rejected rather than guessed.
    public func normalized(_ raw: String) -> String {
        let compact = String(raw.uppercased().filter { $0.isLetter || $0.isNumber })

        if compact.hasPrefix(Self.codePrefix), compact.count > Self.codePrefix.count {
            let body = compact.dropFirst(Self.codePrefix.count)
            return "\(Self.codePrefix)\(Self.codeSeparator)\(body)"
        }
        if compact.count == Self.codeBodyLength {
            return "\(Self.codePrefix)\(Self.codeSeparator)\(compact)"
        }
        return compact
    }

    /// `true` when `code` is exactly `PRV-` followed by six alphabet characters.
    ///
    /// Strict on purpose — call ``normalized(_:)`` first when the string came from a
    /// text field or a pasted link.
    public func isValidCode(_ code: String) -> Bool {
        guard code.count == Self.codeLength else { return false }
        guard code.hasPrefix("\(Self.codePrefix)\(Self.codeSeparator)") else { return false }
        let body = code.dropFirst(Self.codePrefix.count + 1)
        guard body.count == Self.codeBodyLength else { return false }
        let allowed = Set(Self.alphabet)
        return body.allSatisfy { allowed.contains($0) }
    }

    // MARK: Evaluation

    /// The payout a converted referral produces.
    public func reward() -> ReferralReward {
        ReferralReward(
            referrerCredit: rules.referrerCredit,
            referrerPoints: rules.referrerPoints,
            referrerXP: rules.referrerXP,
            refereeCredit: rules.refereeCredit,
            refereePoints: rules.refereePoints,
            refereeXP: rules.refereeXP
        )
    }

    /// Evaluates a referral pairing.
    ///
    /// Resolution order, first match wins:
    /// 1. Same person on both sides → ``ReferralRejection/selfReferral``.
    /// 2. Referrer's own code is malformed → ``ReferralRejection/malformedReferrerCode``.
    /// 3. The new client signed up with a different (or no) code →
    ///    ``ReferralRejection/codeMismatch``.
    /// 4. First appointment not completed yet → ``ReferralOutcome/pending``.
    /// 5. Otherwise → ``ReferralOutcome/rewarded(_:)``.
    ///
    /// Payout is deliberately gated on a *completed* appointment rather than sign-up,
    /// which is what makes the programme fraud-resistant: creating accounts costs
    /// nothing, but sitting in the chair does not.
    ///
    /// - Parameters:
    ///   - referrer: The existing client who shared their code.
    ///   - referee: The new client who signed up.
    ///   - refereeCompletedFirstAppointment: Whether the new client has completed a
    ///     paid appointment.
    public func evaluate(
        referrer: LoyaltyProfile,
        referee: LoyaltyProfile,
        refereeCompletedFirstAppointment: Bool
    ) -> ReferralOutcome {
        guard referrer.userID != referee.userID else { return .rejected(.selfReferral) }

        let referrerCode = normalized(referrer.referralCode)
        guard isValidCode(referrerCode) else { return .rejected(.malformedReferrerCode) }

        guard let used = referee.referredByCode.map({ normalized($0) }), used == referrerCode else {
            return .rejected(.codeMismatch)
        }

        guard refereeCompletedFirstAppointment else { return .pending }
        return .rewarded(reward())
    }

    /// A one-line, human-readable explanation of the programme, for the referral card.
    ///
    /// Uses `Money.formatted`, so the copy follows the reader's locale.
    public func rewardExplanation() -> String {
        "You get \(rules.referrerCredit.formatted) credit and \(rules.referrerPoints.formatted()) points "
            + "when a friend completes their first appointment. They start with "
            + "\(rules.refereeCredit.formatted) credit and \(rules.refereePoints.formatted()) points."
    }
}
