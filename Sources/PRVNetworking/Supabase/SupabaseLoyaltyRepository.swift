import Foundation
import PRVFoundation
import PRVModels

/// The live ``LoyaltyRepository``, backed by the `loyalty_profiles`,
/// `loyalty_achievements`, `achievements`, and `loyalty_challenges` tables.
///
/// XP, points, and the daily streak are not writable from a device. `0002_rls.sql`
/// gives `loyalty_profiles` a `SELECT` and an `INSERT` policy and deliberately no
/// `UPDATE` policy at all, so every balance that goes up does so inside a
/// `security definer` function. ``claimDailyReward(userID:)`` is therefore a call
/// to one rather than a read-modify-write: a client that could decide for itself
/// whether a day had passed could decide it every second.
///
/// The tier is never read from the database. `LoyaltyTier.tier(forXP:)` derives it
/// from the XP returned here, so client and server cannot drift apart on where a
/// tier begins.
public struct SupabaseLoyaltyRepository: LoyaltyRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows any list endpoint returns.
    private static let listLimit = 100

    /// The profile projection: the row plus the badges it has unlocked.
    private static let profileColumns = "*,loyalty_achievements(achievement_id,unlocked_at)"

    /// The function that settles a daily claim. See ``claimDailyReward(userID:)``.
    private static let claimDailyRewardFunction = "claim_daily_reward"

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Reads

    /// The user's loyalty profile, creating it on first read.
    ///
    /// A profile is normally minted by the sign-up trigger, so the insert below
    /// is the fallback for an account that predates it. Two devices racing the
    /// same first read collide on the `user_id` unique index; the loser reads
    /// back the row the winner wrote rather than failing a screen over it.
    public func profile(userID: User.ID) async throws -> LoyaltyProfile {
        if let existing = try await storedProfile(userID: userID) {
            return Self.makeProfile(existing)
        }

        let payload = LoyaltyProfileInsert(
            userID: userID.rawValue,
            referralCode: Self.referralCode(for: userID)
        )
        do {
            let row: LoyaltyProfileRow = try await client.insert(
                into: "loyalty_profiles",
                values: payload,
                returning: Self.profileColumns
            )
            return Self.makeProfile(row)
        } catch let error as APIError {
            guard case .conflict = error else { throw error }
            guard let existing = try await storedProfile(userID: userID) else { throw error }
            return Self.makeProfile(existing)
        }
    }

    /// The platform-wide achievement catalogue, oldest first.
    ///
    /// No `is_active` filter is sent: `achievements_select_public` already limits
    /// this to active badges, so a retired one stops appearing without the client
    /// having to know the rule.
    public func allAchievements() async throws -> [Achievement] {
        let request = PostgRESTQuery("achievements")
            .order("created_at")
            .limited(to: Self.listLimit)
        let rows: [AchievementRow] = try await client.select(request)
        return rows.map(Self.makeAchievement)
    }

    /// The challenges offered to this user, oldest first.
    ///
    /// No user filter is sent either. `loyalty_challenges_select_own` returns a
    /// row when `user_id is null` — a challenge offered to everyone — or when it
    /// matches the caller, which is exactly the right set; a client-side filter
    /// could only ever disagree with it.
    public func challenges(userID: User.ID) async throws -> [LoyaltyChallenge] {
        let request = PostgRESTQuery("loyalty_challenges")
            .order("created_at")
            .limited(to: Self.listLimit)
        let rows: [LoyaltyChallengeRow] = try await client.select(request)
        return try rows.map(Self.makeChallenge)
    }

    // MARK: - Writes

    /// Claims today's reward and returns the profile the server settled on.
    ///
    /// The whole transaction — the "already claimed today?" test against the
    /// database clock, the streak increment, the XP and points award, and the
    /// ledger entry — happens inside `claim_daily_reward`. That is the only place
    /// the guard can hold. `award_loyalty_xp` grants unconditionally and is
    /// `grant execute … to service_role`, so it is not, and must not become, the
    /// thing a device calls; `claim_daily_reward` is its authorized wrapper and
    /// delegates to it.
    ///
    /// Claiming twice in one day is not an error: the function returns the
    /// unchanged profile, exactly as the in-memory backend does.
    public func claimDailyReward(userID: User.ID) async throws -> LoyaltyProfile {
        let settled: LoyaltyProfileRow = try await client.rpc(
            Self.claimDailyRewardFunction,
            params: ClaimDailyRewardParams(pUser: userID.rawValue)
        )
        let unlocked = try await unlockedAchievements(profileID: settled.id)
        return Self.makeProfile(settled, achievements: unlocked)
    }

    // MARK: - Helpers

    /// The stored profile for a user, or `nil` when there is not one yet.
    private func storedProfile(userID: User.ID) async throws -> LoyaltyProfileRow? {
        let request = PostgRESTQuery("loyalty_profiles")
            .selecting(Self.profileColumns)
            .filter(.equals("user_id", userID.rawValue))
            .limited(to: 1)
        let rows: [LoyaltyProfileRow] = try await client.select(request)
        return rows.first
    }

    /// The badges unlocked on a profile, in the order they were earned.
    ///
    /// Read separately only after ``claimDailyReward(userID:)``, whose result is
    /// the settled row rather than a `select` that could carry an embed.
    private func unlockedAchievements(profileID: UUID) async throws -> [Achievement.ID] {
        let request = PostgRESTQuery("loyalty_achievements")
            .selecting("achievement_id,unlocked_at")
            .filter(.equals("loyalty_profile_id", profileID))
            .order("unlocked_at")
            .limited(to: Self.listLimit)
        let rows: [LoyaltyAchievementRow] = try await client.select(request)
        return rows.map { Achievement.ID($0.achievementID) }
    }

    /// The referral code minted for a brand-new profile.
    ///
    /// Matches `InMemoryBackend` byte for byte, so a code shown in demo mode and
    /// one shown against production have the same shape.
    private static func referralCode(for userID: User.ID) -> String {
        "PRV-\(userID.description.prefix(6))"
    }

    // MARK: - Row mapping

    /// Builds a profile, taking its badges from the embed unless the caller read
    /// them separately.
    private static func makeProfile(
        _ row: LoyaltyProfileRow,
        achievements: [Achievement.ID]? = nil
    ) -> LoyaltyProfile {
        let embedded = (row.loyaltyAchievements?.values ?? [])
            .sorted { earlier, later in
                let earlierDate = SupabaseTimestamp.optionalDate(from: earlier.unlockedAt) ?? .distantPast
                let laterDate = SupabaseTimestamp.optionalDate(from: later.unlockedAt) ?? .distantPast
                return earlierDate < laterDate
            }
            .map { Achievement.ID($0.achievementID) }
        let unlocked = achievements ?? embedded
        return LoyaltyProfile(
            id: LoyaltyProfile.ID(row.id),
            userID: User.ID(row.userID),
            xp: row.xp,
            spendablePoints: row.spendablePoints,
            achievements: unlocked,
            referralCode: row.referralCode,
            referredByCode: row.referredByCode,
            currentStreakDays: row.currentStreakDays,
            lastDailyRewardAt: SupabaseTimestamp.optionalDate(from: row.lastDailyRewardAt)
        )
    }

    private static func makeAchievement(_ row: AchievementRow) -> Achievement {
        Achievement(
            id: Achievement.ID(row.id),
            title: row.title,
            details: row.details,
            symbolName: row.symbolName,
            xpReward: row.xpReward,
            pointsReward: row.pointsReward
        )
    }

    private static func makeChallenge(_ row: LoyaltyChallengeRow) throws -> LoyaltyChallenge {
        LoyaltyChallenge(
            id: LoyaltyChallenge.ID(row.id),
            title: row.title,
            details: row.details,
            symbolName: row.symbolName,
            targetCount: row.targetCount,
            progressCount: row.progressCount,
            pointsReward: row.pointsReward,
            endsAt: try SupabaseTimestamp.date(from: row.endsAt)
        )
    }
}

// MARK: - Rows

extension SupabaseLoyaltyRepository {
    /// A `loyalty_profiles` row plus its embedded badges.
    ///
    /// The same shape decodes the `claim_daily_reward` result, which returns the
    /// settled row as `jsonb` and therefore carries no embed.
    fileprivate struct LoyaltyProfileRow: Decodable, Sendable {
        let id: UUID
        let userID: UUID
        let xp: Int
        let spendablePoints: Int
        let referralCode: String
        let referredByCode: String?
        let currentStreakDays: Int
        let lastDailyRewardAt: String?
        let loyaltyAchievements: SupabaseEmbedded<LoyaltyAchievementRow>?
    }

    /// A `loyalty_achievements` join row.
    fileprivate struct LoyaltyAchievementRow: Decodable, Sendable {
        let achievementID: UUID
        let unlockedAt: String
    }

    /// An `achievements` row.
    fileprivate struct AchievementRow: Decodable, Sendable {
        let id: UUID
        let title: String
        let details: String
        let symbolName: String
        let xpReward: Int
        let pointsReward: Int
    }

    /// A `loyalty_challenges` row.
    fileprivate struct LoyaltyChallengeRow: Decodable, Sendable {
        let id: UUID
        let title: String
        let details: String
        let symbolName: String
        let targetCount: Int
        let progressCount: Int
        let pointsReward: Int
        let endsAt: String
    }
}

// MARK: - Payloads

extension SupabaseLoyaltyRepository {
    /// A new `loyalty_profiles` row. Balances start at their column defaults —
    /// there is no path by which a device proposes its own XP.
    fileprivate struct LoyaltyProfileInsert: Encodable, Sendable {
        let userID: UUID
        let referralCode: String
    }

    /// Arguments for `claim_daily_reward(p_user uuid)`.
    fileprivate struct ClaimDailyRewardParams: Encodable, Sendable {
        let pUser: UUID
    }
}
