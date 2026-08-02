import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The full story of one membership plan, and the one place a client can
/// actually commit to it.
///
/// Joining is deliberately two taps away from the grid: the card opens this
/// sheet, and only the bottom bar here charges anything. On success the sheet
/// swaps to a celebration rather than dismissing — the moment someone joins a
/// membership is the moment to make them feel it.
struct PlanDetailSheet: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// The plan being considered.
    let plan: MembershipPlan
    /// Salon behind the plan, when known.
    var salonName: String?
    /// Shared screen model — owns the subscribe call and the celebration.
    let model: MembershipsModel

    private var style: MembershipTierStyle { MembershipTierStyle.style(for: plan.tier) }

    /// The celebration belongs to *this* plan (a stale one from another sheet
    /// must never hijack the screen).
    private var celebration: MembershipsModel.Celebration? {
        guard let celebration = model.celebration, celebration.plan.id == plan.id else { return nil }
        return celebration
    }

    private var isAlreadySubscribed: Bool {
        model.subscribedPlanIDs.contains(plan.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let celebration {
                    MembershipCelebrationView(celebration: celebration) { finish() }
                } else {
                    detail
                }
            }
            .background(Color.prv.canvas)
            .navigationTitle(celebration == nil ? plan.name : "Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(celebration == nil ? "Close" : "Done") { finish() }
                        .accessibilityLabel(celebration == nil ? "Close plan details" : "Done")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .prvAnimation(PRVMotion.gentle, value: celebration?.id)
        .onDisappear {
            // Dragging the sheet away is just as final as tapping Done.
            model.dismissCelebration()
        }
    }

    // MARK: - Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                hero
                if !plan.details.isBlank {
                    Text(plan.details)
                        .prvStyle(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                benefitsSection
                finePrint
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .prvBottomBar { subscribeBar }
    }

    private var hero: some View {
        GradientHeaderCard(gradient: style.gradient) {
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                GradientMedallion(
                    systemName: style.symbolName,
                    gradient: .membershipScrim,
                    size: 52,
                    symbolColor: style.onGradient
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(style.title) Membership")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(style.onGradient)
                    Text(salonName ?? style.tagline)
                        .font(.caption)
                        .foregroundStyle(style.onGradient.opacity(0.85))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
        } content: {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text(plan.name)
                    .prvStyle(.title2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xxs) {
                    PRVPriceLabel(plan.price.formatted, emphasis: .prominent)
                    Text("/ \(MembershipsFormatting.cycleUnit(plan.cycle))")
                        .prvStyle(.subheadline)
                }

                if plan.cycle.months > 1 {
                    Text("\(MembershipsFormatting.monthlyEquivalent(plan.price, cycle: plan.cycle).formatted) a month, billed \(plan.cycle.displayName.lowercased())")
                        .prvStyle(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var benefitsSection: some View {
        if plan.benefits.isEmpty {
            // A plan with no published benefits is unusual but legal — say so
            // plainly rather than rendering an empty card.
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                Image(systemName: "sparkles")
                    .font(.body)
                    .foregroundStyle(style.accentTint)
                    .accessibilityHidden(true)
                Text("This salon hasn't published the benefits for this plan yet — reception will walk you through them.")
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .prvGlassCard()
        } else {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader(
                    "What's included",
                    subtitle: "Every \(MembershipsFormatting.cycleUnit(plan.cycle)), for as long as you're a member"
                )

                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    ForEach(plan.benefits) { benefit in
                        MembershipBenefitRow(benefit: benefit, tint: style.accentTint)
                        if benefit.id != plan.benefits.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }
                }
                .prvGlassCard()
            }
        }
    }

    private var finePrint: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Good to know")

            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                DetailFactRow(
                    systemImage: "creditcard.fill",
                    title: "Billed \(plan.cycle.displayName.lowercased()), renews automatically",
                    value: plan.price.formatted,
                    tint: style.accentTint
                )
                DetailFactRow(
                    systemImage: "arrow.uturn.backward",
                    title: "Cancel any time — your benefits stay yours until the end of the period you've paid for.",
                    tint: style.accentTint
                )
                DetailFactRow(
                    systemImage: "building.2.fill",
                    title: salonName.map { "Valid at \($0)" } ?? "Valid at the salon that issued this plan",
                    tint: style.accentTint
                )
                DetailFactRow(
                    systemImage: "lock.fill",
                    title: "Payments are processed securely; card details never touch this device.",
                    tint: style.accentTint
                )
            }
            .prvGlassCard()
        }
    }

    // MARK: - Call to action

    private var subscribeBar: some View {
        VStack(spacing: PRVSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(MembershipsFormatting.pricePerCycle(plan.price, cycle: plan.cycle))
                    .prvStyle(.subheadline)
                Spacer()
                if isAlreadySubscribed {
                    PRVBadge("Member", tint: Color.prv.success)
                }
            }

            Button {
                join()
            } label: {
                if model.isSubscribing(to: plan) {
                    ProgressView()
                        .tint(Color.prv.textOnAccent)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(ctaTitle)
                }
            }
            .buttonStyle(.prvPrimary)
            .disabled(!canJoin)
            .accessibilityLabel(ctaAccessibilityLabel)
        }
    }

    private var canJoin: Bool {
        session.currentUser != nil && !isAlreadySubscribed && model.subscribingPlanID == nil
    }

    private var ctaTitle: String {
        if session.currentUser == nil { return "Sign in to join" }
        if isAlreadySubscribed { return "You're already a member" }
        return "Join for \(plan.price.formatted)"
    }

    private var ctaAccessibilityLabel: String {
        if session.currentUser == nil { return "Sign in to join this membership" }
        if isAlreadySubscribed { return "You already hold this membership" }
        return "Join \(plan.name) for \(MembershipsFormatting.pricePerCycle(plan.price, cycle: plan.cycle))"
    }

    // MARK: - Actions

    private func join() {
        guard let user = session.currentUser, canJoin else { return }
        PRVHaptics.impact()
        Task { await model.subscribe(to: plan, for: user, using: deps) }
    }

    private func finish() {
        model.dismissCelebration()
        dismiss()
    }
}

// MARK: - Celebration

/// The moment after joining: the tier emblem blooms out of a ring of
/// sparkles, the benefits are restated as won, and one button closes it.
///
/// Every movement here goes through `prvAnimation`, so with Reduce Motion on
/// the same scene simply appears — no sliding, no scaling, no sparkle spin.
struct MembershipCelebrationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What just happened.
    let celebration: MembershipsModel.Celebration
    /// Closes the celebration.
    let onDone: () -> Void

    @State private var hasBloomed = false

    private var style: MembershipTierStyle {
        MembershipTierStyle.style(for: celebration.plan.tier)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PRVSpacing.lg) {
                emblem
                    .padding(.top, PRVSpacing.xl)

                VStack(spacing: PRVSpacing.xs) {
                    Text("You're in")
                        .prvStyle(.display)
                    Text("Welcome to \(celebration.plan.name). Your benefits are active from right now.")
                        .prvStyle(.subheadline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !celebration.plan.benefits.isEmpty {
                    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                        ForEach(celebration.plan.benefits) { benefit in
                            MembershipBenefitRow(benefit: benefit, tint: style.accentTint)
                        }
                    }
                    .prvGlassCard()
                }

                DetailFactRow(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: MembershipsFormatting.renewal(celebration.subscription.renewsAt),
                    value: MembershipsFormatting.pricePerCycle(
                        celebration.plan.price,
                        cycle: celebration.plan.cycle
                    ),
                    tint: style.accentTint
                )
                .prvGlassCard()

                Spacer(minLength: PRVSpacing.md)
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.bottom, PRVSpacing.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .prvBottomBar {
            Button("Start Enjoying It") {
                PRVHaptics.tap()
                onDone()
            }
            .buttonStyle(.prvPrimary)
            .accessibilityLabel("Done. Close the welcome screen")
        }
        .task {
            // A single flag drives the whole bloom, so Reduce Motion only has
            // to be honored in one place.
            hasBloomed = true
        }
        .prvAnimation(PRVMotion.gentle, value: hasBloomed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You joined \(celebration.plan.name)")
    }

    private var emblem: some View {
        ZStack {
            ForEach(0 ..< 8, id: \.self) { index in
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.accentTint)
                    .offset(y: hasBloomed ? -78 : -44)
                    .rotationEffect(.degrees(Double(index) / 8 * 360))
                    .opacity(hasBloomed ? 0.9 : 0)
                    .accessibilityHidden(true)
            }

            Circle()
                .fill(style.gradient)
                .frame(width: 108, height: 108)
                .overlay {
                    Image(systemName: style.symbolName)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(style.onGradient)
                }
                .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
                .prvSoftShadow()
                .scaleEffect(hasBloomed || reduceMotion ? 1 : 0.7)
                .accessibilityHidden(true)
        }
        .frame(height: 180)
    }
}

// MARK: - Previews

#Preview("Plan Detail") {
    PlanDetailSheet(
        plan: PreviewData.goldPlan,
        salonName: PreviewData.salonLumiere.name,
        model: MembershipsModel()
    )
    .environment(UserSession.previewClient)
}

#Preview("Celebration — Dark") {
    MembershipCelebrationView(
        celebration: MembershipsModel.Celebration(
            subscription: MembershipSubscription(
                planID: PreviewData.goldPlan.id,
                plan: PreviewData.goldPlan,
                userID: PreviewData.client.id,
                renewsAt: Date.now.addingTimeInterval(60 * 60 * 24 * 30)
            ),
            plan: PreviewData.goldPlan
        )
    ) {}
        .background(Color.prv.canvas)
        .preferredColorScheme(.dark)
}
