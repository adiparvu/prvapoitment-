import SwiftUI
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// The Reviews section: rating histogram summary, the write-a-review entry
/// point, individual review cards with likes / reports / owner responses,
/// and membership + gift-card promo cards routing to their features.
struct ReviewsSectionView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    let model: SalonProfileModel
    let salon: Salon

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            if model.visibleReviews.isEmpty {
                PRVEmptyState(
                    systemImage: "star.bubble",
                    title: "No reviews yet",
                    message: "Be the first to share your experience at \(salon.name).",
                    actionTitle: session.can(.review) ? "Write a Review" : nil
                ) {
                    model.isWritingReview = true
                }
            } else {
                summaryCard
                writeReviewButton

                ForEach(model.visibleReviews) { review in
                    ReviewCard(
                        review: review,
                        responderName: salon.name,
                        onToggleLike: {
                            Task { await model.toggleLike(on: review, using: deps) }
                        },
                        onReport: {
                            model.report(review)
                        }
                    )
                }
            }

            promoCards
        }
    }

    // MARK: - Summary

    /// Aggregate rating with a 5→1 star histogram.
    private var summaryCard: some View {
        PRVGlassCard {
            HStack(alignment: .center, spacing: PRVSpacing.lg) {
                VStack(spacing: PRVSpacing.xxs) {
                    Text(ProfileFormatting.rating(salon.rating))
                        .prvStyle(.display)
                    PRVRatingStars(rating: salon.rating)
                    Text("\(salon.reviewCount) reviews")
                        .prvStyle(.footnote)
                }

                VStack(spacing: PRVSpacing.xxs) {
                    ForEach([5, 4, 3, 2, 1], id: \.self) { stars in
                        histogramRow(stars: stars)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summaryAccessibilityLabel)
    }

    private func histogramRow(stars: Int) -> some View {
        HStack(spacing: PRVSpacing.xs) {
            Text("\(stars)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.prv.textSecondary)
            Image(systemName: "star.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.prv.gold)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.prv.surface)
                    Capsule()
                        .fill(Color.prv.accentGradient)
                        .frame(width: proxy.size.width * model.reviewFraction(stars: stars))
                }
            }
            .frame(height: 6)

            Text("\(model.reviewCount(stars: stars))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.prv.textSecondary)
                .frame(minWidth: 20, alignment: .trailing)
        }
    }

    private var summaryAccessibilityLabel: String {
        var label = "Rated \(ProfileFormatting.rating(salon.rating)) out of 5, from \(salon.reviewCount) reviews."
        for stars in stride(from: 5, through: 1, by: -1) {
            label += " \(model.reviewCount(stars: stars)) with \(stars) stars."
        }
        return label
    }

    // MARK: - Write a review

    @ViewBuilder
    private var writeReviewButton: some View {
        if session.can(.review) {
            Button {
                PRVHaptics.tap()
                model.isWritingReview = true
            } label: {
                Label("Write a Review", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.prvGlass)
            .accessibilityHint("Opens the review form")
        } else {
            Text("Sign in to share your own experience.")
                .prvStyle(.footnote)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Promos

    /// Cross-sell cards for memberships and gift cards, routed through the
    /// shared router so this feature stays decoupled.
    private var promoCards: some View {
        VStack(spacing: PRVSpacing.sm) {
            PromoCard(
                systemImage: "crown.fill",
                iconTint: Color.prv.gold,
                title: "Become a member",
                message: "Save on every visit with \(salon.name) memberships."
            ) {
                router.push(.memberships(salonID: salon.id))
            }

            PromoCard(
                systemImage: "giftcard.fill",
                iconTint: Color.prv.accent,
                title: "Give the gift of glow",
                message: "Send a PRV gift card for any treatment or amount."
            ) {
                router.push(.giftCards)
            }
        }
    }
}

/// A compact cross-sell card with icon, copy, and a chevron affordance.
struct PromoCard: View {
    let systemImage: String
    let iconTint: Color
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVGlassCard {
                HStack(spacing: PRVSpacing.sm) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(iconTint)
                        .frame(width: 44, height: 44)
                        .background(iconTint.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .prvStyle(.headline)
                        Text(message)
                            .prvStyle(.subheadline)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    PRVListRowChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(message)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Loads the in-memory backend before showing the section on its own.
private struct ReviewsSectionPreview: View {
    @Environment(\.prvDependencies) private var deps
    @State private var model = SalonProfileModel(salonID: PreviewData.salonLumiere.id)

    var body: some View {
        ScrollView {
            if model.phase == .loaded {
                ReviewsSectionView(model: model, salon: PreviewData.salonLumiere)
                    .padding(PRVSpacing.md)
            }
        }
        .background(Color.prv.canvas)
        .task { await model.load(using: deps) }
    }
}

#Preview("Reviews Section") {
    ReviewsSectionPreview()
        .environment(UserSession.previewClient)
        .environment(AppRouter())
}
