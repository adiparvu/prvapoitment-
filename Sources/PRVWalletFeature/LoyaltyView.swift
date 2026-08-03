import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVLoyaltyKit
import PRVModels
import PRVNetworking

/// The loyalty programme: where the client stands, what they earned, and what is
/// worth chasing next.
///
/// A tier hero with a progress ring and tier-specific styling leads into the daily
/// reward (one tap, celebratory haptic, spring pulse, disabled once claimed today),
/// the streak flame row with its grace countdown, open challenges with live
/// deadlines, the achievements shelf, a transparent "how you earn" breakdown driven
/// by `XPEngine`, and the referral card.
///
/// Every rule shown here — thresholds, XP rates, streak grace, referral rewards —
/// is read from `PRVLoyaltyKit`, never re-typed into the UI.
public struct LoyaltyView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = LoyaltyModel()

    /// Creates the loyalty screen. All dependencies come from the environment; the
    /// initializer stays empty by contract.
    public init() {}

    public var body: some View {
        ScrollView {
            Group {
                switch model.phase {
                case .loading:
                    LoyaltySkeleton()
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    content
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Rewards")
        .navigationBarTitleDisplayMode(.inline)
        // Tier hero, streak, challenges, achievements — a long celebratory
        // scroll that reads better without a bar hovering over it.
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) { await refresh() }
        .prvToast($model.toast)
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if model.isGuest {
            PRVEmptyState(
                systemImage: "sparkles",
                title: "Start earning",
                message: "Sign in to collect XP on every visit, unlock tiers, and invite friends for credit.",
                actionTitle: "Explore Salons"
            ) {
                PRVHaptics.tap()
                router.selectedTab = .discover
            }
            .padding(.top, PRVSpacing.xxl)
        } else {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                LoyaltyTierHero(
                    tier: model.tier,
                    style: model.tierStyle,
                    xp: model.xp,
                    progress: model.tierProgress,
                    xpToNextTier: model.xpToNextTier,
                    nextTier: model.nextTier,
                    points: model.points
                )

                DailyRewardCard(
                    hasClaimed: model.hasClaimedToday,
                    isClaiming: model.isClaiming,
                    streakDays: model.streakDays,
                    celebrationToken: model.celebrationToken,
                    lastClaim: model.lastClaim
                ) {
                    claim()
                }

                StreakFlameRow(
                    streakDays: model.streakDays,
                    slackRemaining: model.streakSlackRemaining,
                    nextMilestone: model.nextMilestone,
                    milestoneProgress: model.milestoneProgress
                )

                challengesSection
                achievementsSection
                breakdownSection

                ReferralCard(
                    code: model.referralCode,
                    shareText: model.referralShareText,
                    explanation: model.referralExplanation
                ) {
                    model.toast = .success("Code copied")
                }
            }
        }
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "exclamationmark.icloud",
            title: "Rewards unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    // MARK: - Challenges

    @ViewBuilder
    private var challengesSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Challenges", subtitle: "Limited-time bonuses")

            if model.openChallenges.isEmpty {
                PRVEmptyState(
                    systemImage: "target",
                    title: "No challenges right now",
                    message: "New challenges appear every month — keep booking to be first in line."
                )
                .padding(.vertical, PRVSpacing.md)
            } else {
                VStack(spacing: PRVSpacing.sm) {
                    ForEach(model.openChallenges) { challenge in
                        ChallengeRow(challenge: challenge)
                        if challenge.id != model.openChallenges.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }
                }
                .prvGlassCard()
            }
        }
    }

    // MARK: - Achievements

    @ViewBuilder
    private var achievementsSection: some View {
        if !model.achievements.isEmpty {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader(
                    "Achievements",
                    subtitle: "\(model.unlockedAchievementIDs.count) of \(model.achievements.count) unlocked"
                )

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: PRVSpacing.sm), count: 3),
                    spacing: PRVSpacing.md
                ) {
                    ForEach(model.sortedAchievements) { achievement in
                        AchievementTile(
                            achievement: achievement,
                            isUnlocked: model.unlockedAchievementIDs.contains(achievement.id)
                        )
                    }
                }
                .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
            }
        }
    }

    // MARK: - Breakdown

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("How You Earn", subtitle: "XP builds your tier, points are yours to spend")
            XPBreakdownCard(sources: model.xpSources)
        }
    }

    // MARK: - Actions

    private func claim() {
        guard let user = session.currentUser else { return }
        let deps = deps
        Task { await model.claimDailyReward(for: user, using: deps) }
    }

    private func reload() {
        let user = session.currentUser
        let deps = deps
        Task { await model.load(for: user, using: deps) }
    }

    /// MainActor-isolated refresh entry point for pull-to-refresh.
    private func refresh() async {
        await model.load(for: session.currentUser, using: deps)
    }
}

// MARK: - Previews

#Preview("Loyalty — Client") {
    NavigationStack {
        LoyaltyView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
}

#Preview("Loyalty — Dark") {
    NavigationStack {
        LoyaltyView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
    .preferredColorScheme(.dark)
}

#Preview("Loyalty — Guest") {
    NavigationStack {
        LoyaltyView()
    }
    .environment(UserSession())
    .environment(AppRouter(selectedTab: .wallet))
}
