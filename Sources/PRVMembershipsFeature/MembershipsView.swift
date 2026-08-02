import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Memberships: what the client already holds, what a salon sells, and how
/// the tiers compare.
///
/// The screen reads top-down as a decision: your current standing first, the
/// plans on offer second (filtered by billing cycle when a salon sells more
/// than one), and the tier comparison last for the client who wants the whole
/// picture before committing. Joining always happens in the plan sheet, never
/// from the grid — a membership is a recurring charge, and one stray tap
/// should never start one.
///
/// Data flows exclusively through `@Environment(\.prvDependencies)`; the
/// screen never imports another feature.
public struct MembershipsView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    private let salonID: Salon.ID?

    @State private var model = MembershipsModel()
    @State private var selectedPlan: MembershipPlan?
    @State private var cancellationTarget: MembershipSubscription?

    /// Creates the memberships screen.
    /// - Parameter salonID: Restricts the plans on offer to one salon. Pass
    ///   `nil` (the default) to browse every membership on the platform.
    public init(salonID: Salon.ID? = nil) {
        self.salonID = salonID
    }

    public var body: some View {
        ScrollView {
            Group {
                switch model.phase {
                case .loading:
                    MembershipsSkeleton()
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
        .navigationTitle("Memberships")
        .navigationBarTitleDisplayMode(.large)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) { await refresh() }
        .sheet(item: $selectedPlan) { plan in
            PlanDetailSheet(
                plan: plan,
                salonName: model.salonName(for: plan.salonID),
                model: model
            )
        }
        .confirmationDialog(
            "Cancel this membership?",
            isPresented: cancellationDialogBinding,
            titleVisibility: .visible,
            presenting: cancellationTarget
        ) { subscription in
            Button("Cancel Membership", role: .destructive) {
                confirmCancellation(of: subscription)
            }
            Button("Keep Membership", role: .cancel) {
                cancellationTarget = nil
            }
        } message: { subscription in
            Text("\(MembershipsFormatting.benefitsUntil(subscription.renewsAt)). After that it won't renew, and you can re-join at any time.")
        }
        .prvToast($model.toast)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xl) {
            standingSection
            plansSection
            comparisonSection
            lapsedSection
        }
    }

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "exclamationmark.icloud",
            title: "Memberships unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    // MARK: - Your standing

    @ViewBuilder
    private var standingSection: some View {
        if let failure = model.subscriptionsFailure {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader("Your Memberships")
                InlineFailureCard(message: failure) { reloadSubscriptions() }
            }
        } else if !model.activeSubscriptions.isEmpty {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader(
                    "Your Memberships",
                    subtitle: model.activeSubscriptions.count == 1
                        ? "One membership, working quietly in the background"
                        : "\(model.activeSubscriptions.count) memberships"
                )

                VStack(spacing: PRVSpacing.md) {
                    ForEach(model.activeSubscriptions) { subscription in
                        ActiveSubscriptionCard(
                            subscription: subscription,
                            plan: model.plan(for: subscription),
                            salonName: salonName(for: subscription),
                            isCancelling: model.isCancelling(subscription)
                        ) {
                            cancellationTarget = subscription
                        }
                    }
                }
            }
        } else if !model.hasNoPlans {
            invitationCard
        }
    }

    /// The value proposition, shown to anyone who isn't a member yet.
    private var invitationCard: some View {
        HStack(alignment: .top, spacing: PRVSpacing.md) {
            GradientMedallion(
                systemName: "crown.fill",
                gradient: Color.prv.accentGradient,
                size: 46
            )

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text(model.isGuest ? "Memberships, made simple" : "Become a member")
                    .prvStyle(.headline)
                Text(model.isGuest
                     ? "Sign in to join a plan, keep your benefits in one place, and book before anyone else."
                     : "Standing discounts, priority booking, and a ritual that's already paid for.")
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Plans

    @ViewBuilder
    private var plansSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(
                "Plans",
                subtitle: model.hasNoPlans ? nil : "Cancel any time — benefits stay until the period ends"
            )

            if !model.cycleOptions.isEmpty {
                PRVSegmentedGlassControl(
                    selection: cycleBinding,
                    options: model.cycleOptions,
                    title: \.title
                )
                .accessibilityLabel("Filter plans by billing cycle")
            }

            if model.hasNoPlans {
                PRVEmptyState(
                    systemImage: "crown",
                    title: "No memberships yet",
                    message: salonID == nil
                        ? "No salon on PRV is selling memberships right now. Packages and gift cards are still available."
                        : "This salon doesn't sell memberships yet. Ask at reception — they can often arrange something.",
                    actionTitle: "Browse Packages"
                ) {
                    PRVHaptics.tap()
                    router.push(.packages(salonID: salonID))
                }
                .padding(.vertical, PRVSpacing.lg)
            } else if model.filteredPlans.isEmpty {
                PRVEmptyState(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "Nothing on this cycle",
                    message: "No plan is billed \(model.cycleFilter.title.lowercased()) here. Try another billing cycle.",
                    actionTitle: "Show All Plans"
                ) {
                    PRVHaptics.tap()
                    model.cycleFilter = .all
                }
                .padding(.vertical, PRVSpacing.lg)
            } else {
                LazyVStack(spacing: PRVSpacing.lg) {
                    ForEach(model.filteredPlans) { plan in
                        MembershipPlanCard(
                            plan: plan,
                            salonName: planSalonName(for: plan),
                            isFeatured: plan.id == model.featuredPlanID,
                            isSubscribed: model.subscribedPlanIDs.contains(plan.id)
                        ) {
                            selectedPlan = plan
                        }
                    }
                }
                .prvAnimation(PRVMotion.spring, value: model.cycleFilter)
            }
        }
    }

    // MARK: - Comparison

    @ViewBuilder
    private var comparisonSection: some View {
        if !model.comparison.isEmpty {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader(
                    model.comparison.isComparison ? "Compare Tiers" : "What's Included",
                    subtitle: model.comparison.isComparison
                        ? "Every benefit, side by side"
                        : "Everything this tier carries"
                )
                TierComparisonTable(matrix: model.comparison)
            }
        }
    }

    // MARK: - Past memberships

    @ViewBuilder
    private var lapsedSection: some View {
        if !model.lapsedSubscriptions.isEmpty {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader("Past Memberships", subtitle: "Re-join whenever you like")

                VStack(spacing: PRVSpacing.md) {
                    ForEach(model.lapsedSubscriptions) { subscription in
                        ActiveSubscriptionCard(
                            subscription: subscription,
                            plan: model.plan(for: subscription),
                            salonName: salonName(for: subscription)
                        ) {}
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    /// Presents the cancellation dialog while a target is set, and clears the
    /// target the moment the dialog goes away — however it goes away.
    private var cancellationDialogBinding: Binding<Bool> {
        Binding(
            get: { cancellationTarget != nil },
            set: { isPresented in
                if !isPresented { cancellationTarget = nil }
            }
        )
    }

    private var cycleBinding: Binding<PlanCycleFilter> {
        Binding(
            get: { model.cycleFilter },
            set: { model.cycleFilter = $0 }
        )
    }

    // MARK: - Helpers

    /// Salon name for a plan, shown only when the grid spans several salons —
    /// on a single salon's page it would just be noise.
    private func planSalonName(for plan: MembershipPlan) -> String? {
        salonID == nil ? model.salonName(for: plan.salonID) : nil
    }

    private func salonName(for subscription: MembershipSubscription) -> String? {
        guard let plan = model.plan(for: subscription) else { return nil }
        return model.salonName(for: plan.salonID)
    }

    // MARK: - Actions

    private func refresh() async {
        await model.load(for: session.currentUser, salonID: salonID, using: deps)
    }

    private func reload() {
        Task { await refresh() }
    }

    private func reloadSubscriptions() {
        let user = session.currentUser
        Task { await model.reloadSubscriptions(for: user, using: deps) }
    }

    private func confirmCancellation(of subscription: MembershipSubscription) {
        cancellationTarget = nil
        Task { await model.cancel(subscription, using: deps) }
    }
}

// MARK: - Previews

#Preview("Memberships — Client") {
    NavigationStack {
        MembershipsView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
}

#Preview("Memberships — Salon") {
    NavigationStack {
        MembershipsView(salonID: PreviewData.salonLumiere.id)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .wallet))
    .preferredColorScheme(.dark)
}

#Preview("Memberships — Guest") {
    NavigationStack {
        MembershipsView()
    }
    .environment(UserSession())
    .environment(AppRouter(selectedTab: .wallet))
}
