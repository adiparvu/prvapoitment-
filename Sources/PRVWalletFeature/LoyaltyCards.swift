import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVLoyaltyKit
import PRVModels
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tier hero

/// The loyalty hero: a progress ring to the next tier wrapped in tier-specific
/// styling — rose-gold for Bronze, cool metal for Silver, gold for Gold, orchid for
/// Diamond, and a lacquered treatment with a gold ring for Black.
///
/// The glow behind the ring is disabled under Reduce Transparency, and every colour
/// is composed from design-system tokens so the treatment follows Dark Mode.
struct LoyaltyTierHero: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let tier: LoyaltyTier
    let style: LoyaltyTierStyle
    let xp: Int
    let progress: Double
    let xpToNextTier: Int?
    let nextTier: LoyaltyTier?
    let points: Int

    var body: some View {
        VStack(spacing: PRVSpacing.md) {
            ring

            VStack(spacing: PRVSpacing.xxs) {
                Text("\(tier.displayName) Member")
                    .prvStyle(.title2)
                Text(style.tagline)
                    .prvStyle(.footnote)
                    .multilineTextAlignment(.center)
            }

            Text(progressCaption)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.textSecondary)
                .multilineTextAlignment(.center)

            pointsPill
        }
        .frame(maxWidth: .infinity)
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(tier.displayName) member, \(WalletFormatting.points(xp)) XP. \(progressCaption). "
                + "\(WalletFormatting.points(points)) points to spend."
        )
        .accessibilityIdentifier("loyalty.tierHero")
    }

    private var ring: some View {
        PRVProgressRing(progress: progress, lineWidth: 9, size: 136, tint: style.ringTint) {
            VStack(spacing: 2) {
                Image(systemName: style.symbolName)
                    .font(.title2)
                    .foregroundStyle(style.ringTint)
                    .accessibilityHidden(true)
                Text("\(WalletFormatting.points(xp))")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("XP")
                    .prvStyle(.caption)
            }
        }
        .background {
            Circle()
                .fill(style.gradient)
                .opacity(reduceTransparency ? 0 : 0.26)
                .blur(radius: 32)
                .padding(-PRVSpacing.sm)
                .accessibilityHidden(true)
        }
    }

    private var pointsPill: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.bold))
            Text("\(WalletFormatting.points(points)) points to spend")
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.prv.gold)
        .padding(.vertical, PRVSpacing.xs)
        .padding(.horizontal, PRVSpacing.md)
        .background(Color.prv.gold.opacity(0.14), in: Capsule())
        .accessibilityHidden(true)
    }

    private var progressCaption: String {
        guard let nextTier, let xpToNextTier else {
            return "You've reached the top tier — everything is unlocked"
        }
        return "\(WalletFormatting.points(xpToNextTier)) XP to \(nextTier.displayName)"
    }
}

// MARK: - Daily reward

/// The daily reward card: one tap, a celebratory haptic, and a spring scale pulse.
/// Disables itself for the rest of the calendar day once claimed.
struct DailyRewardCard: View {
    let hasClaimed: Bool
    let isClaiming: Bool
    let streakDays: Int
    let celebrationToken: Int
    let lastClaim: DailyClaim?
    let action: () -> Void

    @State private var isPulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            HStack(spacing: PRVSpacing.md) {
                Image(systemName: hasClaimed ? "checkmark.seal.fill" : "gift.fill")
                    .font(.title2)
                    .foregroundStyle(hasClaimed ? Color.prv.success : Color.prv.textOnAccent)
                    .frame(width: 52, height: 52)
                    .background {
                        if hasClaimed {
                            Circle().fill(Color.prv.success.opacity(0.14))
                        } else {
                            Circle().fill(Color.prv.accentGradient)
                        }
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text(hasClaimed ? "Claimed today" : "Your daily reward")
                        .prvStyle(.headline)
                    Text(subtitle)
                        .prvStyle(.footnote)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            Button {
                PRVHaptics.tap()
                action()
            } label: {
                if isClaiming {
                    ProgressView()
                        .tint(Color.prv.textOnAccent)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(hasClaimed ? "Come back tomorrow" : "Claim today's reward")
                }
            }
            .buttonStyle(.prvPrimary)
            .disabled(hasClaimed || isClaiming)
            .accessibilityLabel(hasClaimed ? "Already claimed today" : "Claim today's reward")
            .accessibilityHint(hasClaimed ? "Available again tomorrow" : "Adds points and extends your streak")
            .accessibilityIdentifier("loyalty.claimDaily")
        }
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
        .scaleEffect(isPulsing ? 1.03 : 1)
        .prvAnimation(PRVMotion.spring, value: isPulsing)
        .onChange(of: celebrationToken) { _, newValue in
            guard newValue > 0 else { return }
            isPulsing = true
            Task {
                try? await Task.sleep(for: .milliseconds(280))
                isPulsing = false
            }
        }
    }

    private var subtitle: String {
        if let lastClaim, hasClaimed {
            if let milestone = lastClaim.milestone {
                return "\(milestone.title) — +\(WalletFormatting.points(milestone.bonusPoints)) bonus points"
            }
            if lastClaim.award.points > 0 {
                return "+\(WalletFormatting.points(lastClaim.award.points)) points · day \(lastClaim.streakDays) of your streak"
            }
        }
        if hasClaimed {
            return "Day \(streakDays) of your streak. See you tomorrow."
        }
        return "Check in every day to keep your streak — and your bonuses — alive."
    }
}

// MARK: - Streak

/// The streak flame row: a lit pip for each of the last seven days, the current
/// count, and how much grace is left before the streak resets.
struct StreakFlameRow: View {
    let streakDays: Int
    let slackRemaining: Int?
    let nextMilestone: StreakMilestone?
    let milestoneProgress: Double

    private let pipCount = 7

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            HStack(spacing: PRVSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(streakDays)-day streak")
                        .prvStyle(.headline)
                    Text(slackCaption)
                        .prvStyle(.caption)
                        .lineLimit(2)
                }

                Spacer(minLength: PRVSpacing.xs)

                HStack(spacing: PRVSpacing.xxs) {
                    ForEach(0 ..< pipCount, id: \.self) { index in
                        Image(systemName: isLit(index) ? "flame.fill" : "flame")
                            .font(.footnote)
                            .foregroundStyle(isLit(index) ? Color.prv.warning : Color.prv.separator)
                    }
                }
                .accessibilityHidden(true)
            }

            if let nextMilestone {
                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    ProgressBar(progress: milestoneProgress)
                    Text("\(max(0, nextMilestone.days - streakDays)) days to \(nextMilestone.title) · +\(WalletFormatting.points(nextMilestone.bonusPoints)) points")
                        .prvStyle(.caption)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(streakDays) day streak. \(slackCaption)")
    }

    private func isLit(_ index: Int) -> Bool {
        index < min(streakDays, pipCount)
    }

    private var slackCaption: String {
        guard streakDays > 0, let slackRemaining else {
            return "Claim your daily reward to start a streak"
        }
        switch slackRemaining {
        case 0: return "Claim today or your streak resets"
        case 1: return "One day of grace left"
        default: return "\(slackRemaining) days of grace left"
        }
    }
}

// MARK: - Challenges

/// A time-boxed challenge with its progress bar, reward, and deadline countdown.
struct ChallengeRow: View {
    let challenge: LoyaltyChallenge

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            HStack(spacing: PRVSpacing.sm) {
                Image(systemName: challenge.symbolName)
                    .font(.body)
                    .foregroundStyle(challenge.isCompleted ? Color.prv.success : Color.prv.accent)
                    .frame(width: 38, height: 38)
                    .background(
                        (challenge.isCompleted ? Color.prv.success : Color.prv.accent).opacity(0.12),
                        in: Circle()
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(challenge.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)
                    Text(challenge.details)
                        .prvStyle(.caption)
                        .lineLimit(2)
                }

                Spacer(minLength: PRVSpacing.xs)

                PRVBadge(
                    "+\(WalletFormatting.points(challenge.pointsReward))",
                    tint: challenge.isCompleted ? Color.prv.success : Color.prv.gold
                )
            }

            ProgressBar(progress: challenge.progress)

            HStack {
                Text("\(challenge.progressCount) of \(challenge.targetCount)")
                    .prvStyle(.caption)
                Spacer()
                TimelineView(.periodic(from: .now, by: 3_600)) { context in
                    Text(WalletFormatting.endsIn(challenge.endsAt, now: context.date))
                        .prvStyle(.caption)
                }
            }
        }
        .padding(.vertical, PRVSpacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        "\(challenge.title). \(challenge.details). "
            + "\(challenge.progressCount) of \(challenge.targetCount) complete. "
            + "Rewards \(WalletFormatting.points(challenge.pointsReward)) points. "
            + WalletFormatting.endsIn(challenge.endsAt, now: .now)
    }
}

/// A slim capsule progress bar in the brand gradient.
struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.prv.separator.opacity(0.35))
                Capsule()
                    .fill(Color.prv.accentGradient)
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
        }
        .frame(height: 6)
        .prvAnimation(PRVMotion.gentle, value: progress)
        .accessibilityHidden(true)
    }
}

// MARK: - Achievements

/// One tile in the achievements grid. Locked tiles keep their shape so the shelf
/// reads as a set to complete, but drop their colour and gain a lock.
struct AchievementTile: View {
    let achievement: Achievement
    let isUnlocked: Bool

    var body: some View {
        VStack(spacing: PRVSpacing.xs) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: achievement.symbolName)
                    .font(.title2)
                    .foregroundStyle(isUnlocked ? AnyShapeStyle(Color.prv.accentGradient) : AnyShapeStyle(Color.prv.textSecondary))
                    .frame(width: 56, height: 56)
                    .background(
                        (isUnlocked ? Color.prv.accent : Color.prv.textSecondary).opacity(0.12),
                        in: Circle()
                    )

                if !isUnlocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.prv.textSecondary)
                        .padding(4)
                        .background(Color.prv.surfaceElevated, in: Circle())
                }
            }
            .accessibilityHidden(true)

            Text(achievement.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isUnlocked ? Color.prv.textPrimary : Color.prv.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .opacity(isUnlocked ? 1 : 0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isUnlocked
                ? "\(achievement.title), unlocked. \(achievement.details)"
                : "\(achievement.title), locked. \(achievement.details)"
        )
    }
}

// MARK: - Referral

/// The referral card: the client's code, a copy button, a share sheet, and a plain
/// explanation of what both sides get.
struct ReferralCard: View {
    let code: String
    let shareText: String
    let explanation: String
    let onCopied: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.md) {
            HStack(spacing: PRVSpacing.sm) {
                Image(systemName: "person.2.badge.gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(Color.prv.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text("Invite a friend")
                        .prvStyle(.headline)
                    Text(explanation)
                        .prvStyle(.footnote)
                }
            }

            HStack(spacing: PRVSpacing.sm) {
                Text(code.isEmpty ? "—" : code)
                    .font(.system(.body, design: .monospaced, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, PRVSpacing.sm)
                    .padding(.horizontal, PRVSpacing.md)
                    .background(Color.prv.surfaceElevated, in: PRVRadius.shape(PRVRadius.md))
                    .accessibilityLabel("Your referral code, \(spelledOutCode)")

                Button {
                    copyCode()
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(code.isEmpty)
                .accessibilityLabel("Copy referral code")
            }

            ShareLink(item: shareText) {
                Label("Share your code", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prvGlass)
            .disabled(code.isEmpty)
            .accessibilityLabel("Share your referral code")
        }
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
    }

    /// Reads the code one character at a time so VoiceOver doesn't turn "PRV-K7M2QX"
    /// into an unpronounceable word.
    private var spelledOutCode: String {
        code.map { String($0) }.joined(separator: " ")
    }

    private func copyCode() {
        guard !code.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #endif
        PRVHaptics.success()
        onCopied()
    }
}

// MARK: - XP breakdown

/// "How you earn" — the reward table rendered straight from `XPEngine`.
struct XPBreakdownCard: View {
    let sources: [XPSource]

    var body: some View {
        VStack(spacing: PRVSpacing.xs) {
            ForEach(sources) { source in
                HStack(spacing: PRVSpacing.sm) {
                    Image(systemName: source.symbolName)
                        .font(.footnote)
                        .foregroundStyle(Color.prv.accent)
                        .frame(width: 32, height: 32)
                        .background(Color.prv.accent.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.prv.textPrimary)
                            .lineLimit(1)
                        Text(source.detail)
                            .prvStyle(.caption)
                            .lineLimit(1)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    Text(source.rewardText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.prv.gold)
                        .monospacedDigit()
                }
                .padding(.vertical, PRVSpacing.xxs)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(source.title), \(source.detail), \(source.rewardText)")

                if source.id != sources.last?.id {
                    Divider().overlay(Color.prv.separator.opacity(0.5))
                }
            }
        }
        .prvGlassCard()
    }
}

// MARK: - Skeleton

/// The loyalty screen's loading state.
struct LoyaltySkeleton: View {
    var body: some View {
        VStack(spacing: PRVSpacing.xl) {
            VStack(spacing: PRVSpacing.md) {
                PRVSkeleton(width: 136, height: 136, radius: 68)
                PRVSkeleton(width: 180, height: 20)
                PRVSkeleton(width: 140, height: 13)
            }
            .frame(maxWidth: .infinity)
            .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)

            PRVSkeleton(height: 132, radius: PRVRadius.xl)
            PRVSkeleton(height: 88, radius: PRVRadius.lg)

            HStack(spacing: PRVSpacing.md) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    VStack(spacing: PRVSpacing.xs) {
                        PRVSkeleton(width: 56, height: 56, radius: 28)
                        PRVSkeleton(width: 62, height: 11)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Loyalty — Cards") {
    ScrollView {
        VStack(spacing: PRVSpacing.lg) {
            LoyaltyTierHero(
                tier: .gold,
                style: LoyaltyTierStyle.style(for: .gold),
                xp: 6_450,
                progress: 0.145,
                xpToNextTier: 8_550,
                nextTier: .diamond,
                points: 1_240
            )

            DailyRewardCard(
                hasClaimed: false,
                isClaiming: false,
                streakDays: 4,
                celebrationToken: 0,
                lastClaim: nil
            ) {}

            StreakFlameRow(
                streakDays: 4,
                slackRemaining: 2,
                nextMilestone: StreakEngine.standardMilestones[1],
                milestoneProgress: 0.25
            )

            ChallengeRow(
                challenge: LoyaltyChallenge(
                    title: "Monthly Ritual",
                    details: "Visit 3 times this month",
                    symbolName: "flame.fill",
                    targetCount: 3,
                    progressCount: 1,
                    pointsReward: 500,
                    endsAt: Date.now.addingTimeInterval(60 * 60 * 24 * 21)
                )
            )
            .prvGlassCard()

            ReferralCard(
                code: "PRV-K7M2QX",
                shareText: "Join me on PRV Beauty.",
                explanation: ReferralEngine().rewardExplanation()
            ) {}
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}

#Preview("Loyalty — Black tier") {
    LoyaltyTierHero(
        tier: .black,
        style: LoyaltyTierStyle.style(for: .black),
        xp: 52_000,
        progress: 1,
        xpToNextTier: nil,
        nextTier: nil,
        points: 12_400
    )
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
