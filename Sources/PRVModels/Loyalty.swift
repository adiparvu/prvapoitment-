import Foundation

public enum LoyaltyTier: String, Codable, Hashable, Sendable, CaseIterable {
    case bronze
    case silver
    case gold
    case diamond
    case black

    public var displayName: String {
        switch self {
        case .bronze: "Bronze"
        case .silver: "Silver"
        case .gold: "Gold"
        case .diamond: "Diamond"
        case .black: "Black"
        }
    }

    /// XP required to reach this tier.
    public var threshold: Int {
        switch self {
        case .bronze: 0
        case .silver: 1_000
        case .gold: 5_000
        case .diamond: 15_000
        case .black: 40_000
        }
    }

    public var next: LoyaltyTier? {
        switch self {
        case .bronze: .silver
        case .silver: .gold
        case .gold: .diamond
        case .diamond: .black
        case .black: nil
        }
    }

    public static func tier(forXP xp: Int) -> LoyaltyTier {
        allCases.last { xp >= $0.threshold } ?? .bronze
    }
}

public struct LoyaltyProfile: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<LoyaltyProfile>

    public var id: ID
    public var userID: User.ID
    public var xp: Int
    public var spendablePoints: Int
    public var achievements: [Achievement.ID]
    public var referralCode: String
    public var referredByCode: String?
    public var currentStreakDays: Int
    public var lastDailyRewardAt: Date?

    public init(
        id: ID = ID(),
        userID: User.ID,
        xp: Int = 0,
        spendablePoints: Int = 0,
        achievements: [Achievement.ID] = [],
        referralCode: String,
        referredByCode: String? = nil,
        currentStreakDays: Int = 0,
        lastDailyRewardAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.xp = xp
        self.spendablePoints = spendablePoints
        self.achievements = achievements
        self.referralCode = referralCode
        self.referredByCode = referredByCode
        self.currentStreakDays = currentStreakDays
        self.lastDailyRewardAt = lastDailyRewardAt
    }

    public var tier: LoyaltyTier { .tier(forXP: xp) }

    /// Progress toward the next tier, 0…1. Returns 1 at the top tier.
    public var progressToNextTier: Double {
        guard let next = tier.next else { return 1 }
        let base = tier.threshold
        let span = next.threshold - base
        guard span > 0 else { return 1 }
        return min(1, Double(xp - base) / Double(span))
    }
}

public struct Achievement: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Achievement>

    public var id: ID
    public var title: String
    public var details: String
    public var symbolName: String
    public var xpReward: Int
    public var pointsReward: Int

    public init(
        id: ID = ID(),
        title: String,
        details: String,
        symbolName: String,
        xpReward: Int = 0,
        pointsReward: Int = 0
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.symbolName = symbolName
        self.xpReward = xpReward
        self.pointsReward = pointsReward
    }
}

/// A time-boxed loyalty challenge ("3 visits this month → 500 points").
public struct LoyaltyChallenge: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<LoyaltyChallenge>

    public var id: ID
    public var title: String
    public var details: String
    public var symbolName: String
    public var targetCount: Int
    public var progressCount: Int
    public var pointsReward: Int
    public var endsAt: Date

    public init(
        id: ID = ID(),
        title: String,
        details: String,
        symbolName: String,
        targetCount: Int,
        progressCount: Int = 0,
        pointsReward: Int,
        endsAt: Date
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.symbolName = symbolName
        self.targetCount = targetCount
        self.progressCount = progressCount
        self.pointsReward = pointsReward
        self.endsAt = endsAt
    }

    public var isCompleted: Bool { progressCount >= targetCount }
    public var progress: Double {
        targetCount > 0 ? min(1, Double(progressCount) / Double(targetCount)) : 0
    }
}
