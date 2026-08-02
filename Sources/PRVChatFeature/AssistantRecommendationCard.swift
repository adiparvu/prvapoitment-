import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// The Beauty Assistant's answer rendered as a rich Liquid Glass card:
/// the headline and rationale, the treatments it recommends with real prices
/// and durations, where and with whom to have them done, any package that
/// covers the plan, bookable times, and the maintenance advice that keeps the
/// result alive.
///
/// Every element routes through ``MessageActions`` so the card can live in a
/// conversation transcript or in the assistant thread without knowing about
/// the router.
struct AssistantRecommendationCard: View {
    /// The resolved plan. While `isResolving` is true only the recommendation
    /// itself is populated and the detail sections show skeletons.
    let plan: AssistantPlan
    /// Whether the identifier lookups are still in flight.
    var isResolving: Bool = false
    /// Navigation callbacks raised by the card.
    let actions: MessageActions

    private var recommendation: AssistantRecommendation { plan.recommendation }

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                header

                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text(recommendation.headline)
                        .prvStyle(.title2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(recommendation.rationale)
                        .prvStyle(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isResolving {
                    resolvingSkeleton
                } else {
                    details
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Beauty Assistant recommendation: \(recommendation.headline)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.prv.accentGradient)
                .accessibilityHidden(true)
            Text("Beauty Assistant")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.prv.textSecondary)
                .textCase(.uppercase)
            Spacer(minLength: PRVSpacing.xs)
            if !isResolving, let summary = planSummary {
                Text(summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                    .monospacedDigit()
            }
        }
    }

    /// "3 h 30 min · from €260.00" — the plan at a glance.
    private var planSummary: String? {
        guard !plan.services.isEmpty else { return nil }
        var parts: [String] = [ChatFormat.serviceDuration(minutes: plan.totalDurationMinutes)]
        if let total = plan.totalPrice {
            parts.append(plan.isEstimatedTotal ? "from \(total.formatted)" : total.formatted)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Detail sections

    @ViewBuilder
    private var details: some View {
        if !plan.services.isEmpty {
            section("Recommended treatments") {
                VStack(spacing: PRVSpacing.xs) {
                    ForEach(plan.services) { service in
                        serviceRow(service)
                    }
                }
            }
        }

        if !plan.salons.isEmpty {
            section("Where to go") {
                horizontalRail {
                    ForEach(plan.salons) { salon in
                        SalonMiniCard(salon: salon) {
                            actions.openSalon(salon.id)
                        }
                    }
                }
            }
        }

        if !plan.professionals.isEmpty {
            section("Who to book") {
                horizontalRail {
                    ForEach(plan.professionals) { professional in
                        ProfessionalMiniCard(professional: professional) {
                            actions.openProfessional(professional.id)
                        }
                    }
                }
            }
        }

        if !plan.packages.isEmpty {
            section("Bundled and saved") {
                VStack(spacing: PRVSpacing.xs) {
                    ForEach(plan.packages) { package in
                        PackageMiniCard(package: package) {
                            actions.openPackages(package.salonID)
                        }
                    }
                }
            }
        }

        if !plan.slots.isEmpty, let salonID = plan.primarySalonID {
            section("Suggested times") {
                horizontalRail(spacing: PRVSpacing.xs) {
                    ForEach(plan.slots) { slot in
                        PRVTimeSlotPill(label: slotLabel(slot)) {
                            actions.book(salonID, plan.bookableServiceIDs)
                        }
                    }
                }
            }
        }

        if let advice = recommendation.maintenanceAdvice, !advice.isBlank {
            maintenanceFootnote(advice)
        }

        if let salonID = plan.primarySalonID, !plan.bookableServiceIDs.isEmpty {
            Button {
                PRVHaptics.impact()
                actions.book(salonID, plan.bookableServiceIDs)
            } label: {
                Text("Book this plan")
            }
            .buttonStyle(.prvPrimary)
            .accessibilityHint("Opens the booking flow with these treatments selected")
        }
    }

    private func serviceRow(_ service: SalonService) -> some View {
        PRVListRow(
            title: service.name,
            subtitle: "\(ChatFormat.serviceDuration(minutes: service.durationMinutes)) · \(service.category.displayName)"
        ) {
            PRVListRowIcon(systemImage: service.category.symbolName)
        } trailing: {
            PRVPriceLabel(service.price.formatted, isFrom: service.isStartingPrice)
        }
        .accessibilityLabel("\(service.name), \(ChatFormat.serviceDuration(minutes: service.durationMinutes)), \(service.price.formatted)")
    }

    private func maintenanceFootnote(_ advice: String) -> some View {
        HStack(alignment: .top, spacing: PRVSpacing.xs) {
            Image(systemName: "leaf.fill")
                .font(.caption)
                .foregroundStyle(Color.prv.success)
                .accessibilityHidden(true)
            Text(advice)
                .prvStyle(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PRVSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.prv.success.opacity(0.08), in: PRVRadius.shape(PRVRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Maintenance advice: \(advice)")
    }

    // MARK: - Building blocks

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.prv.textSecondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A rail that scrolls sideways without clipping the card's padding.
    private func horizontalRail(
        spacing: CGFloat = PRVSpacing.sm,
        @ViewBuilder content: () -> some View
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// "Thu 10:30" — slots can span several days, so the weekday matters.
    private func slotLabel(_ slot: TimeSlot) -> String {
        slot.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var resolvingSkeleton: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSkeleton(width: 130, height: 11)
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: PRVSpacing.sm) {
                    PRVSkeleton(width: 36, height: 36, radius: PRVRadius.sm)
                    VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                        PRVSkeleton(width: 150, height: 14)
                        PRVSkeleton(width: 90, height: 11)
                    }
                    Spacer(minLength: PRVSpacing.xs)
                    PRVSkeleton(width: 54, height: 15)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Mini cards

/// A compact salon card used inside assistant recommendations.
struct SalonMiniCard: View {
    let salon: Salon
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                PRVAsyncImage(url: salon.heroImageURL)
                    .frame(width: 168, height: 96)
                    .clipShape(PRVRadius.shape(PRVRadius.md))

                VStack(alignment: .leading, spacing: 2) {
                    Text(salon.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: PRVSpacing.xxs) {
                        PRVRatingStars(rating: salon.rating, maximum: 1)
                        Text(salon.rating.formatted(.number.precision(.fractionLength(1))))
                            .prvStyle(.caption)
                        Text("·")
                            .prvStyle(.caption)
                        Text(salon.address.city)
                            .prvStyle(.caption)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 168, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(salon.name), \(salon.address.city), rated \(salon.rating.formatted(.number.precision(.fractionLength(1))))")
        .accessibilityHint("Opens the salon profile")
        .accessibilityAddTraits(.isButton)
    }
}

/// A compact professional card used inside assistant recommendations.
struct ProfessionalMiniCard: View {
    let professional: Professional
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            VStack(spacing: PRVSpacing.xs) {
                PRVAvatar(
                    name: professional.displayName,
                    imageURL: professional.photoURL,
                    size: .large
                )

                VStack(spacing: 2) {
                    Text(professional.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)
                    Text(professional.title)
                        .prvStyle(.caption)
                        .lineLimit(1)
                }
            }
            .frame(width: 116)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(professional.displayName), \(professional.title)")
        .accessibilityHint("Opens the professional's profile")
        .accessibilityAddTraits(.isButton)
    }
}

/// A package the assistant folded into the plan, with its saving surfaced.
struct PackageMiniCard: View {
    let package: ServicePackage
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            PRVListRow(
                title: package.name,
                subtitle: package.details.isBlank ? nil : package.details
            ) {
                PRVListRowIcon(systemImage: "gift.fill", tint: Color.prv.gold)
            } trailing: {
                VStack(alignment: .trailing, spacing: 2) {
                    PRVPriceLabel(
                        package.packagePrice.formatted,
                        originalPrice: package.regularPrice.formatted
                    )
                    if !package.savings.isZero {
                        PRVBadge("Save \(package.savings.formatted)", tint: Color.prv.success)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(package.name), \(package.packagePrice.formatted), saving \(package.savings.formatted)")
        .accessibilityHint("Opens packages")
    }
}

// MARK: - Thinking state

/// The assistant's "thinking" surface: a shimmering glass card that mirrors
/// the shape of the answer to come. Deliberately no spinner — the plan is
/// composing itself, not loading.
struct AssistantThinkingCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the assistant is working on, echoed back to the user.
    let prompt: String

    @State private var isGlowing = false

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.md) {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.prv.accentGradient)
                        .scaleEffect(isGlowing ? 1.12 : 0.94)
                        .opacity(isGlowing ? 1 : 0.65)
                        .animation(breathing, value: isGlowing)
                        .accessibilityHidden(true)

                    Text("Composing your plan")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.prv.textSecondary)
                        .textCase(.uppercase)
                }

                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    PRVSkeleton(width: 210, height: 20)
                    PRVSkeleton(height: 13)
                    PRVSkeleton(width: 240, height: 13)
                }

                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    PRVSkeleton(width: 120, height: 11)
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: PRVSpacing.sm) {
                            PRVSkeleton(width: 36, height: 36, radius: PRVRadius.sm)
                            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                                PRVSkeleton(width: 140, height: 13)
                                PRVSkeleton(width: 80, height: 10)
                            }
                            Spacer(minLength: PRVSpacing.xs)
                            PRVSkeleton(width: 52, height: 14)
                        }
                    }
                }
            }
        }
        .overlay {
            PRVRadius.shape(PRVRadius.xl)
                .strokeBorder(Color.prv.accentGradient.opacity(isGlowing ? 0.5 : 0.18), lineWidth: 1)
                .animation(breathing, value: isGlowing)
        }
        .onAppear { isGlowing = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your assistant is composing a plan for “\(prompt)”")
    }

    private var breathing: Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
    }
}

// MARK: - Previews

#Preview("Recommendation Card") {
    ScrollView {
        AssistantRecommendationCard(
            plan: AssistantPlan(
                recommendation: AssistantRecommendation(
                    headline: "Your bridal countdown plan",
                    rationale: "Two weeks out is perfect: a trial now, gloss and shape the week of, and the Bridal Radiance package covers your wedding-day look end to end.",
                    maintenanceAdvice: "Book a gloss refresh 5 days before the ceremony."
                ),
                services: [PreviewData.serviceBalayage, PreviewData.serviceCutBlowDry],
                salons: [PreviewData.salonLumiere, PreviewData.salonVelvet],
                professionals: [PreviewData.stylistAmelie, PreviewData.artistNoor],
                packages: [PreviewData.weddingPackage],
                slots: [
                    TimeSlot(start: Date.now.addingTimeInterval(86_400), end: Date.now.addingTimeInterval(95_400)),
                    TimeSlot(start: Date.now.addingTimeInterval(180_000), end: Date.now.addingTimeInterval(189_000)),
                ]
            ),
            actions: MessageActions()
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}

#Preview("Thinking — Dark") {
    AssistantThinkingCard(prompt: "I have a wedding in two weeks")
        .padding(PRVSpacing.md)
        .frame(maxHeight: .infinity)
        .background(Color.prv.canvas)
        .preferredColorScheme(.dark)
}
