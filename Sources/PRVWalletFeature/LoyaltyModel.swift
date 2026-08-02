import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVLoyaltyKit
import PRVModels
import PRVNetworking

/// One way a client can earn, rendered in the "How you earn" breakdown.
///
/// Values are read from ``XPEngine`` rather than typed into the UI, so the screen can
/// never promise a reward the engine does not actually grant.
struct XPSource: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbolName: String
    let xp: Int
    let points: Int

    /// "+235 XP · +185 pts", omitting whichever half is zero.
    var rewardText: String {
        var parts: [String] = []
        if xp > 0 { parts.append("+\(WalletFormatting.points(xp)) XP") }
        if points > 0 { parts.append("+\(WalletFormatting.points(points)) pts") }
        return parts.joined(separator: " · ")
    }
}

/// What the client just won by claiming their daily reward — the payload the
/// celebration animation and toast are built from.
struct DailyClaim: Hashable, Sendable {
    let award: XPAward
    let streakDays: Int
    let milestone: StreakMilestone?
    let levelUp: LevelUpResult?
}

/// Screen model backing `LoyaltyView`.
///
/// Owns the loyalty profile, achievements, and challenges, and drives the daily
/// reward claim. Every derived number — tier, progress, XP to go, streak slack,
/// milestone, referral copy — comes from `PRVLoyaltyKit` engines rather than being
/// recomputed in a view, so the wallet and the backend can never disagree about the
/// rules.
@Observable
@MainActor
final class LoyaltyModel {
    // MARK: Engines

    let tierEngine = TierEngine()
    let xpEngine = XPEngine()
    let referralEngine = ReferralEngine()
    /// Calendar-injected so "today" is the client's own day, not a server day.
    let streakEngine: StreakEngine

    // MARK: State

    private(set) var phase: WalletPhase = .loading
    private(set) var profile: LoyaltyProfile?
    private(set) var achievements: [Achievement] = []
    private(set) var challenges: [LoyaltyChallenge] = []
    /// `true` while the daily reward claim is in flight.
    private(set) var isClaiming = false
    /// `true` when nobody is signed in.
    private(set) var isGuest = false
    /// Increments on every successful claim so the view can replay its celebration.
    private(set) var celebrationToken = 0
    /// The most recent claim, for the celebratory summary.
    private(set) var lastClaim: DailyClaim?
    /// Transient feedback.
    var toast: PRVToast?

    private var hasLoadedOnce = false

    /// Creates the model.
    /// - Parameter calendar: Defines day boundaries for the streak. Defaults to the
    ///   device calendar; tests and previews inject a fixed one.
    init(calendar: Calendar = .current) {
        self.streakEngine = StreakEngine(calendar: calendar)
    }

    // MARK: Derived

    var xp: Int { profile?.xp ?? 0 }
    var points: Int { profile?.spendablePoints ?? 0 }
    var tier: LoyaltyTier { tierEngine.tier(for: xp) }
    var tierStyle: LoyaltyTierStyle { LoyaltyTierStyle.style(for: tier) }
    /// Progress through the current tier, `0...1` — the progress ring's value.
    var tierProgress: Double { tierEngine.progressToNextTier(xp) }
    /// XP still needed for the next tier, or `nil` at the top.
    var xpToNextTier: Int? { tierEngine.xpToNextTier(xp) }
    var nextTier: LoyaltyTier? { tier.next }
    var streakDays: Int { profile?.currentStreakDays ?? 0 }
    var referralCode: String { profile?.referralCode ?? "" }

    /// `true` once today's reward has been claimed — the claim button's disabled state.
    var hasClaimedToday: Bool {
        guard let profile else { return false }
        return streakEngine.hasClaimed(profile: profile, on: .now)
    }

    /// How many more days can be missed before the streak resets, or `nil` when there
    /// is no streak yet.
    var streakSlackRemaining: Int? {
        streakEngine.daysOfSlackRemaining(lastActiveDay: profile?.lastDailyRewardAt, now: .now)
    }

    /// The next streak milestone to chase.
    var nextMilestone: StreakMilestone? { streakEngine.nextMilestone(after: streakDays) }

    /// Progress toward ``nextMilestone``, `0...1`.
    var milestoneProgress: Double { streakEngine.progressToNextMilestone(days: streakDays) }

    /// Achievements the client has already unlocked.
    var unlockedAchievementIDs: Set<Achievement.ID> {
        Set(profile?.achievements ?? [])
    }

    /// Achievements sorted unlocked-first, so progress reads as a trophy shelf.
    var sortedAchievements: [Achievement] {
        let unlocked = unlockedAchievementIDs
        return achievements.sorted { lhs, rhs in
            let lhsUnlocked = unlocked.contains(lhs.id)
            let rhsUnlocked = unlocked.contains(rhs.id)
            if lhsUnlocked != rhsUnlocked { return lhsUnlocked }
            return lhs.title < rhs.title
        }
    }

    /// Challenges still open, soonest deadline first.
    var openChallenges: [LoyaltyChallenge] {
        challenges.sorted { $0.endsAt < $1.endsAt }
    }

    /// The reward table, rendered straight from ``XPEngine``.
    ///
    /// The per-unit row is labelled in euros, the platform's primary currency; the
    /// engine itself is currency-agnostic and applies the same rate in every market.
    var xpSources: [XPSource] {
        let rules = xpEngine.rules
        let visit = xpEngine.award(for: .completedAppointment(spend: .zero()))
        let review = xpEngine.award(for: .review)
        let referral = xpEngine.award(for: .referralConverted)
        let daily = xpEngine.award(for: .dailyOpen)
        let challenge = xpEngine.award(for: .challengeCompleted)
        let membership = xpEngine.award(for: .membershipPurchased)

        return [
            XPSource(
                id: "spend",
                title: "Every \(Currency.eur.symbol)1 you spend",
                detail: "Counted when the visit is complete",
                symbolName: "creditcard.fill",
                xp: rules.xpPerCurrencyUnit,
                points: rules.pointsPerCurrencyUnit
            ),
            XPSource(
                id: "visit",
                title: "Completing an appointment",
                detail: "A flat bonus for showing up",
                symbolName: "checkmark.seal.fill",
                xp: visit.xp,
                points: visit.points
            ),
            XPSource(
                id: "review",
                title: "Writing a review",
                detail: "After a completed visit",
                symbolName: "star.bubble.fill",
                xp: review.xp,
                points: review.points
            ),
            XPSource(
                id: "referral",
                title: "A friend's first appointment",
                detail: "Paid when they sit in the chair",
                symbolName: "person.2.fill",
                xp: referral.xp,
                points: referral.points
            ),
            XPSource(
                id: "daily",
                title: "Daily check-in",
                detail: "Once a day, streak included",
                symbolName: "flame.fill",
                xp: daily.xp,
                points: daily.points
            ),
            XPSource(
                id: "challenge",
                title: "Finishing a challenge",
                detail: "Plus whatever the challenge itself pays",
                symbolName: "target",
                xp: challenge.xp,
                points: challenge.points
            ),
            XPSource(
                id: "membership",
                title: "Joining a membership",
                detail: "Once per subscription",
                symbolName: "crown.fill",
                xp: membership.xp,
                points: membership.points
            ),
        ]
    }

    /// The share sheet's message for the referral code.
    var referralShareText: String {
        guard !referralCode.isEmpty else { return "Join me on PRV Beauty." }
        return "Join me on PRV Beauty and use my code \(referralCode) — we both get rewarded when you book your first appointment."
    }

    /// One-line explanation of the referral programme, straight from the engine.
    var referralExplanation: String { referralEngine.rewardExplanation() }

    // MARK: Loading

    /// Loads the profile, achievement catalogue, and challenges concurrently.
    /// Safe to call repeatedly.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            isGuest = true
            profile = nil
            achievements = []
            challenges = []
            hasLoadedOnce = false
            phase = .loaded
            return
        }

        isGuest = false
        if !hasLoadedOnce { phase = .loading }

        async let profileTask = deps.loyalty.profile(userID: user.id)
        async let achievementsTask = deps.loyalty.allAchievements()
        async let challengesTask = deps.loyalty.challenges(userID: user.id)

        do {
            profile = try await profileTask
            // The catalogue and challenges are decoration around the balance: if they
            // fail, the tier hero still tells the client where they stand.
            achievements = (try? await achievementsTask) ?? []
            challenges = (try? await challengesTask) ?? []
            phase = .loaded
            hasLoadedOnce = true
        } catch {
            let message = WalletFormatting.friendlyError(error, subject: "Your loyalty status")
            if hasLoadedOnce {
                toast = .warning(message)
                phase = .loaded
            } else {
                phase = .failed(message)
            }
        }
    }

    // MARK: Daily reward

    /// Claims today's reward, records what was won, and fires the celebration.
    ///
    /// Guarded twice — once on ``isClaiming`` and once on ``hasClaimedToday`` — so a
    /// double tap can never double-claim, and the repository remains the source of
    /// truth for the new balance.
    func claimDailyReward(for user: User, using deps: PRVDependencies) async {
        guard !isClaiming, !hasClaimedToday else { return }
        isClaiming = true
        defer { isClaiming = false }

        let previous = profile
        do {
            let updated = try await deps.loyalty.claimDailyReward(userID: user.id)
            let gainedXP = max(0, updated.xp - (previous?.xp ?? updated.xp))
            let gainedPoints = max(0, updated.spendablePoints - (previous?.spendablePoints ?? updated.spendablePoints))
            let levelUp = previous.flatMap { tierEngine.willLevelUp(current: $0.xp, adding: gainedXP) }

            profile = updated
            let claim = DailyClaim(
                award: XPAward(xp: gainedXP, points: gainedPoints, reason: "Daily check-in"),
                streakDays: updated.currentStreakDays,
                milestone: streakEngine.milestone(for: updated.currentStreakDays),
                levelUp: levelUp
            )
            lastClaim = claim
            celebrationToken += 1

            PRVHaptics.success()
            toast = .success(Self.celebrationMessage(for: claim))
        } catch {
            PRVHaptics.error()
            toast = .error(WalletFormatting.friendlyError(error, subject: "Your daily reward"))
        }
    }

    /// The toast copy for a claim: a level-up outranks a milestone, which outranks
    /// the plain points line.
    nonisolated static func celebrationMessage(for claim: DailyClaim) -> String {
        if let levelUp = claim.levelUp {
            return "Welcome to \(levelUp.newTier.displayName)!"
        }
        if let milestone = claim.milestone {
            return "\(milestone.title) — +\(WalletFormatting.points(milestone.bonusPoints)) bonus points"
        }
        if claim.award.points > 0 {
            return "+\(WalletFormatting.points(claim.award.points)) points · Day \(claim.streakDays)"
        }
        return "Day \(claim.streakDays) of your streak"
    }
}
