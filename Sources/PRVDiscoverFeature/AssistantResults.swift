import SwiftUI
import PRVModels
import PRVDesignSystem

/// The "Ask AI" affordance shown under the search field once the query
/// reads like a sentence. Tapping routes the text to the Beauty Assistant.
struct AskAssistantRow: View {
    let queryText: String
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.impact()
            action()
        } label: {
            PRVGlassCard(radius: PRVRadius.md, padding: PRVSpacing.sm) {
                HStack(spacing: PRVSpacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.body)
                        .foregroundStyle(Color.prv.accentGradient)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask your Beauty Assistant")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                        Text("Get a plan for “\(queryText)”")
                            .prvStyle(.caption)
                            .lineLimit(1)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.prv.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask your Beauty Assistant about \(queryText)")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Shimmering placeholder shown while the assistant is thinking.
struct AssistantThinkingRow: View {
    var body: some View {
        PRVGlassCard(radius: PRVRadius.md, padding: PRVSpacing.sm) {
            HStack(spacing: PRVSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.body)
                    .foregroundStyle(Color.prv.accentGradient)
                    .accessibilityHidden(true)
                Text("Planning your look…")
                    .prvStyle(.subheadline)
                    .prvShimmer()
                Spacer(minLength: PRVSpacing.xs)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityLabel("Beauty Assistant is thinking")
    }
}

/// Quiet error surface for a failed assistant request, with retry.
struct AssistantErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        PRVGlassCard(radius: PRVRadius.md, padding: PRVSpacing.sm) {
            HStack(spacing: PRVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(Color.prv.warning)
                    .accessibilityHidden(true)
                Text(message)
                    .prvStyle(.footnote)
                Spacer(minLength: PRVSpacing.xs)
                Button {
                    PRVHaptics.tap()
                    retry()
                } label: {
                    Text("Retry")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                }
                .accessibilityLabel("Retry asking the assistant")
            }
        }
    }
}

/// Inline rendering of a resolved `AssistantRecommendation`: headline,
/// rationale, then tappable service, salon, and professional cards, plus
/// optional maintenance advice.
struct AssistantResultsCard: View {
    let resolved: ResolvedRecommendation
    let onOpenService: (SalonService) -> Void
    let onOpenSalon: (Salon) -> Void
    let onOpenProfessional: (Professional) -> Void
    let onDismiss: () -> Void

    private var recommendation: AssistantRecommendation { resolved.recommendation }

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                header

                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text(recommendation.headline)
                        .prvStyle(.title2)
                    Text(recommendation.rationale)
                        .prvStyle(.subheadline)
                }

                if !resolved.services.isEmpty {
                    section("Recommended services") {
                        ForEach(resolved.services) { service in
                            serviceRow(service)
                        }
                    }
                }

                if !resolved.salons.isEmpty {
                    section("Where to go") {
                        ForEach(resolved.salons) { salon in
                            salonRow(salon)
                        }
                    }
                }

                if !resolved.professionals.isEmpty {
                    section("Who to book") {
                        ForEach(resolved.professionals) { professional in
                            professionalRow(professional)
                        }
                    }
                }

                if let advice = recommendation.maintenanceAdvice {
                    HStack(alignment: .top, spacing: PRVSpacing.xs) {
                        Image(systemName: "leaf.fill")
                            .font(.caption)
                            .foregroundStyle(Color.prv.success)
                            .accessibilityHidden(true)
                        Text(advice)
                            .prvStyle(.footnote)
                    }
                    .padding(PRVSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.prv.success.opacity(0.08), in: PRVRadius.shape(PRVRadius.md))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: "sparkles")
                .font(.body)
                .foregroundStyle(Color.prv.accentGradient)
                .accessibilityHidden(true)
            Text("Beauty Assistant")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.prv.textSecondary)
                .textCase(.uppercase)
            Spacer(minLength: PRVSpacing.xs)
            Button {
                PRVHaptics.tap()
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.prv.textSecondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss assistant answer")
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.prv.textSecondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func serviceRow(_ service: SalonService) -> some View {
        Button {
            PRVHaptics.tap()
            onOpenService(service)
        } label: {
            PRVListRow(
                title: service.name,
                subtitle: "\(service.durationMinutes) min · \(service.category.displayName)"
            ) {
                PRVListRowIcon(systemImage: service.category.symbolName)
            } trailing: {
                PRVPriceLabel(service.price.formatted, isFrom: service.isStartingPrice)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(service.name), \(service.price.formatted)")
    }

    private func salonRow(_ salon: Salon) -> some View {
        Button {
            PRVHaptics.tap()
            onOpenSalon(salon)
        } label: {
            PRVListRow(
                title: salon.name,
                subtitle: salon.address.city
            ) {
                PRVAsyncImage(url: salon.heroImageURL)
                    .frame(width: 44, height: 44)
                    .clipShape(PRVRadius.shape(PRVRadius.sm))
            } trailing: {
                HStack(spacing: PRVSpacing.xxs) {
                    PRVRatingStars(rating: salon.rating, maximum: 1)
                    Text(salon.rating.formatted(.number.precision(.fractionLength(1))))
                        .prvStyle(.caption)
                    PRVListRowChevron()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(salon.name), in \(salon.address.city)")
    }

    private func professionalRow(_ professional: Professional) -> some View {
        Button {
            PRVHaptics.tap()
            onOpenProfessional(professional)
        } label: {
            PRVListRow(
                title: professional.displayName,
                subtitle: professional.title
            ) {
                PRVAvatar(
                    name: professional.displayName,
                    imageURL: professional.photoURL,
                    size: .medium
                )
            } trailing: {
                PRVListRowChevron()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(professional.displayName), \(professional.title)")
    }
}

#Preview("Assistant Results") {
    ScrollView {
        VStack(spacing: PRVSpacing.md) {
            AskAssistantRow(queryText: "I need bridal hair for June") {}
            AssistantThinkingRow()
            AssistantResultsCard(
                resolved: ResolvedRecommendation(
                    recommendation: AssistantRecommendation(
                        headline: "Your bridal countdown plan",
                        rationale: "A trial now, gloss the week of, and the Bridal Radiance package for the day itself.",
                        maintenanceAdvice: "Book a gloss refresh 5 days before the ceremony."
                    ),
                    services: [PreviewData.serviceBalayage],
                    salons: [PreviewData.salonLumiere],
                    professionals: [PreviewData.stylistAmelie]
                ),
                onOpenService: { _ in },
                onOpenSalon: { _ in },
                onOpenProfessional: { _ in },
                onDismiss: {}
            )
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}
