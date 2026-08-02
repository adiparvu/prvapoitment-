import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Outcome of the subscriptions fetch, mapped to `Sendable` values before it
/// crosses back onto the main actor. Declared at file scope, outside the
/// `@MainActor` model, so the nonisolated fetch can build it freely.
private enum SubscriptionsOutcome: Sendable {
    /// Nobody is signed in.
    case guest
    /// The client's subscriptions.
    case loaded([MembershipSubscription])
    /// The fetch failed, with copy ready for the screen.
    case failed(String)
}

/// Screen model backing ``MembershipsView``.
///
/// The plan grid is the screen's spine: if plans cannot be read, the screen
/// says so rather than showing an empty shop. The client's own subscriptions
/// load alongside them and degrade independently — a failure there becomes an
/// inline retry card, never an incorrect "you have no memberships", because
/// telling someone they lost a membership they are paying for is the worst
/// possible failure mode of this screen.
@Observable
@MainActor
final class MembershipsModel {
    /// The moment right after a subscription succeeds — drives the
    /// celebration state that replaces the plan sheet.
    struct Celebration: Identifiable, Equatable, Sendable {
        /// The freshly created subscription.
        let subscription: MembershipSubscription
        /// The plan it was created from, kept so the celebration can show
        /// benefits even when the repository returns a thin subscription.
        let plan: MembershipPlan

        var id: MembershipSubscription.ID { subscription.id }
    }

    // MARK: - State

    private(set) var phase: MembershipsPhase = .loading
    /// Plans on sale, entry tier first.
    private(set) var plans: [MembershipPlan] = []
    /// The signed-in client's subscriptions, newest first.
    private(set) var subscriptions: [MembershipSubscription] = []
    /// Set when the client's own memberships could not be read while plans
    /// loaded fine — rendered as an inline retry, not a screen-wide error.
    private(set) var subscriptionsFailure: String?
    /// Salon names behind the plans, for cross-salon plan lists.
    private(set) var salonNames: [Salon.ID: String] = [:]
    /// Precomputed comparison table, rebuilt only when plans change.
    private(set) var comparison: TierComparisonMatrix = .empty
    /// `true` when nobody is signed in — plans stay browsable, joining does not.
    private(set) var isGuest = false
    /// Plan whose subscribe CTA is in flight.
    private(set) var subscribingPlanID: MembershipPlan.ID?
    /// Subscription whose cancellation is in flight.
    private(set) var cancellingSubscriptionID: MembershipSubscription.ID?
    /// Set for the few seconds after joining, so the sheet can celebrate.
    private(set) var celebration: Celebration?

    /// Billing cycle the plan grid is filtered to.
    var cycleFilter: PlanCycleFilter = .all
    /// Transient feedback (join failed, membership cancelled…).
    var toast: PRVToast?

    /// Set after the first successful load; later refreshes keep content on
    /// screen instead of flashing skeletons.
    private var hasLoadedOnce = false

    /// Creates an empty model. All data arrives through ``load(for:salonID:using:)``.
    init() {}

    // MARK: - Derived

    /// Memberships still entitling the client to benefits, soonest renewal first.
    var activeSubscriptions: [MembershipSubscription] {
        subscriptions
            .filter { $0.status.membershipIsLive }
            .sorted { $0.renewsAt < $1.renewsAt }
    }

    /// Memberships that have ended, most recent first — kept visible so the
    /// client can see what they used to have (and re-join in one tap).
    var lapsedSubscriptions: [MembershipSubscription] {
        subscriptions
            .filter { !$0.status.membershipIsLive }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Plans the client is currently subscribed to.
    var subscribedPlanIDs: Set<MembershipPlan.ID> {
        Set(activeSubscriptions.map(\.planID))
    }

    /// Cycles actually on sale, shortest first.
    var availableCycles: [BillingCycle] {
        Set(plans.map(\.cycle)).sorted { $0.months < $1.months }
    }

    /// Segments for the cycle picker — empty when everything shares one
    /// cycle, because a picker with a single meaningful choice is noise.
    var cycleOptions: [PlanCycleFilter] {
        let cycles = availableCycles
        guard cycles.count > 1 else { return [] }
        return [.all] + cycles.map(PlanCycleFilter.cycle)
    }

    /// Plans passing the cycle filter, entry tier first.
    var filteredPlans: [MembershipPlan] {
        plans.filter { cycleFilter.matches($0.cycle) }
    }

    /// The plan to crown "Most popular": the highest tier on offer within the
    /// current filter. Only meaningful once there is something to compare it to.
    var featuredPlanID: MembershipPlan.ID? {
        let visible = filteredPlans
        guard visible.count > 1 else { return nil }
        return visible.max { lhs, rhs in
            (lhs.tier.membershipRank, lhs.price.amount) < (rhs.tier.membershipRank, rhs.price.amount)
        }?.id
    }

    /// `true` when the salon (or platform) sells nothing right now.
    var hasNoPlans: Bool { plans.isEmpty }

    /// Name of the salon behind a plan or package, when known.
    func salonName(for salonID: Salon.ID) -> String? { salonNames[salonID] }

    /// The plan behind a subscription: the joined copy when the repository
    /// sent one, otherwise the matching plan from the grid.
    func plan(for subscription: MembershipSubscription) -> MembershipPlan? {
        subscription.plan ?? plans.first { $0.id == subscription.planID }
    }

    /// Whether this plan's CTA should show a spinner.
    func isSubscribing(to plan: MembershipPlan) -> Bool { subscribingPlanID == plan.id }

    /// Whether this subscription's cancel button should show a spinner.
    func isCancelling(_ subscription: MembershipSubscription) -> Bool {
        cancellingSubscriptionID == subscription.id
    }

    // MARK: - Loading

    /// Loads plans and the client's subscriptions concurrently.
    ///
    /// Safe to call repeatedly (pull-to-refresh, sign-in changes).
    /// - Parameters:
    ///   - user: The signed-in user, or `nil` for guests.
    ///   - salonID: Restricts plans to one salon; `nil` shows every plan the
    ///     platform sells.
    ///   - deps: Repository container from the environment.
    func load(for user: User?, salonID: Salon.ID?, using deps: PRVDependencies) async {
        isGuest = user == nil
        if !hasLoadedOnce { phase = .loading }

        async let plansTask = deps.memberships.plans(salonID: salonID)
        async let subscriptionsTask = Self.fetchSubscriptions(for: user, using: deps)

        do {
            let loaded = try await plansTask
            apply(plans: loaded)
            phase = .loaded
            hasLoadedOnce = true
        } catch {
            let message = MembershipsFormatting.friendlyError(error, subject: "Memberships")
            if hasLoadedOnce {
                // Keep the last known plan grid on screen; mention the hiccup quietly.
                toast = .warning(message)
                phase = .loaded
            } else {
                phase = .failed(message)
            }
        }

        switch await subscriptionsTask {
        case .guest:
            subscriptions = []
            subscriptionsFailure = nil
        case .loaded(let list):
            subscriptions = list.sorted { $0.startedAt > $1.startedAt }
            subscriptionsFailure = nil
        case .failed(let message):
            subscriptionsFailure = message
        }

        await loadSalonNames(using: deps)
    }

    /// Retries only the client's own memberships, from the inline failure card.
    func reloadSubscriptions(for user: User?, using deps: PRVDependencies) async {
        switch await Self.fetchSubscriptions(for: user, using: deps) {
        case .guest:
            subscriptions = []
            subscriptionsFailure = nil
        case .loaded(let list):
            subscriptions = list.sorted { $0.startedAt > $1.startedAt }
            subscriptionsFailure = nil
        case .failed(let message):
            subscriptionsFailure = message
        }
    }

    /// Sorts, filters, and indexes a freshly fetched plan list.
    private func apply(plans loaded: [MembershipPlan]) {
        plans = loaded
            .filter(\.isActive)
            .sorted { lhs, rhs in
                if lhs.tier.membershipRank != rhs.tier.membershipRank {
                    return lhs.tier.membershipRank < rhs.tier.membershipRank
                }
                if lhs.cycle.months != rhs.cycle.months {
                    return lhs.cycle.months < rhs.cycle.months
                }
                return lhs.price.amount < rhs.price.amount
            }
        comparison = TierComparisonMatrix.build(from: plans)

        // A filter that survives a refresh but no longer matches anything
        // would leave the client staring at an empty grid.
        if case .cycle(let cycle) = cycleFilter, !availableCycles.contains(cycle) {
            cycleFilter = .all
        }
    }

    /// Fills in the names of the salons behind the plans, so a cross-salon
    /// list reads as "Maison Lumière — Gold" rather than a bare tier.
    private func loadSalonNames(using deps: PRVDependencies) async {
        let missing = Set(plans.map(\.salonID)).subtracting(salonNames.keys)
        guard !missing.isEmpty else { return }
        let fetched = await Self.fetchSalonNames(missing, using: deps)
        salonNames.merge(fetched) { _, new in new }
    }

    // MARK: - Subscribing

    /// Subscribes the client to `plan` and raises the celebration state.
    ///
    /// - Returns: `true` when the subscription was created.
    @discardableResult
    func subscribe(to plan: MembershipPlan, for user: User, using deps: PRVDependencies) async -> Bool {
        guard subscribingPlanID == nil else { return false }
        subscribingPlanID = plan.id
        defer { subscribingPlanID = nil }

        do {
            var subscription = try await deps.memberships.subscribe(planID: plan.id, userID: user.id)
            // Repositories may return a thin subscription; keep the plan we
            // already hold so every downstream card can render benefits.
            if subscription.plan == nil { subscription.plan = plan }
            subscriptions.insert(subscription, at: 0)
            celebration = Celebration(subscription: subscription, plan: plan)
            PRVHaptics.success()
            return true
        } catch {
            PRVHaptics.error()
            toast = .error(MembershipsFormatting.friendlyError(error, subject: plan.name))
            return false
        }
    }

    /// Clears the celebration once the client has taken it in.
    func dismissCelebration() {
        celebration = nil
    }

    // MARK: - Cancelling

    /// Cancels a subscription. The client keeps every benefit until the paid
    /// period ends, and the copy says so.
    func cancel(_ subscription: MembershipSubscription, using deps: PRVDependencies) async {
        guard cancellingSubscriptionID == nil else { return }
        cancellingSubscriptionID = subscription.id
        defer { cancellingSubscriptionID = nil }

        do {
            var updated = try await deps.memberships.cancelSubscription(id: subscription.id)
            if updated.plan == nil { updated.plan = subscription.plan }
            if let index = subscriptions.firstIndex(where: { $0.id == updated.id }) {
                subscriptions[index] = updated
            } else {
                subscriptions.insert(updated, at: 0)
            }
            PRVHaptics.success()
            toast = .success(MembershipsFormatting.benefitsUntil(updated.renewsAt))
        } catch {
            PRVHaptics.error()
            let name = plan(for: subscription)?.name ?? "This membership"
            toast = .error(MembershipsFormatting.friendlyError(error, subject: name))
        }
    }

    // MARK: - Fetching helpers

    /// Fetches subscriptions off the main actor, mapping any failure to copy
    /// before it crosses back — errors are not `Sendable`, messages are.
    private nonisolated static func fetchSubscriptions(
        for user: User?,
        using deps: PRVDependencies
    ) async -> SubscriptionsOutcome {
        guard let user else { return .guest }
        do {
            return .loaded(try await deps.memberships.subscriptions(userID: user.id))
        } catch {
            return .failed(MembershipsFormatting.friendlyError(error, subject: "Your memberships"))
        }
    }

    /// Resolves salon names concurrently. A salon that fails to load simply
    /// stays unnamed — a missing subtitle is never worth an error surface.
    private nonisolated static func fetchSalonNames(
        _ salonIDs: Set<Salon.ID>,
        using deps: PRVDependencies
    ) async -> [Salon.ID: String] {
        await withTaskGroup(of: (Salon.ID, String)?.self) { group in
            for salonID in salonIDs {
                group.addTask {
                    guard let salon = try? await deps.salons.salon(id: salonID) else { return nil }
                    return (salon.id, salon.name)
                }
            }
            var names: [Salon.ID: String] = [:]
            for await pair in group {
                if let pair { names[pair.0] = pair.1 }
            }
            return names
        }
    }
}
