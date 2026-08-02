import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking

/// An `AssistantRecommendation` with every identifier resolved into the
/// entity it points at, ready to render as a rich card.
///
/// The shared contract deliberately keeps `AssistantRecommendation` as a bag
/// of IDs so it stays small on the wire; resolving it is a presentation
/// concern owned by whichever feature displays it.
struct AssistantPlan: Hashable, Sendable, Identifiable {
    /// The raw recommendation the assistant returned.
    var recommendation: AssistantRecommendation
    /// Recommended services, in the order the assistant listed them.
    var services: [SalonService]
    /// Salons where the plan can be carried out.
    var salons: [Salon]
    /// Professionals the assistant suggests booking with.
    var professionals: [Professional]
    /// Bundles that cover part or all of the plan.
    var packages: [ServicePackage]
    /// Bookable times — the recommendation's own suggestions when it has
    /// them, otherwise live availability fetched for the primary salon.
    var slots: [TimeSlot]

    var id: AssistantRecommendation.ID { recommendation.id }

    init(
        recommendation: AssistantRecommendation,
        services: [SalonService] = [],
        salons: [Salon] = [],
        professionals: [Professional] = [],
        packages: [ServicePackage] = [],
        slots: [TimeSlot] = []
    ) {
        self.recommendation = recommendation
        self.services = services
        self.salons = salons
        self.professionals = professionals
        self.packages = packages
        self.slots = slots
    }

    /// The salon a "book this plan" action should open.
    var primarySalonID: Salon.ID? {
        salons.first?.id ?? services.compactMap(\.salonID).first
    }

    /// Services belonging to the primary salon — the exact set carried into
    /// the booking flow.
    var bookableServiceIDs: [SalonService.ID] {
        guard let primarySalonID else { return services.map(\.id) }
        let matching = services.filter { $0.salonID == primarySalonID }
        return matching.isEmpty ? services.map(\.id) : matching.map(\.id)
    }

    /// Combined price of the recommended services, or `nil` when they mix
    /// currencies (never summed across currencies).
    var totalPrice: Money? {
        guard let first = services.first else { return nil }
        guard services.allSatisfy({ $0.price.currency == first.price.currency }) else { return nil }
        return services.dropFirst().reduce(first.price) { $0 + $1.price }
    }

    /// Combined chair time of the recommended services.
    var totalDurationMinutes: Int {
        services.reduce(0) { $0 + $1.durationMinutes }
    }

    /// Whether any service carries a "from" price, making the total an
    /// estimate rather than a quote.
    var isEstimatedTotal: Bool {
        services.contains { $0.isStartingPrice }
    }

    /// Whether the card has anything beyond the headline and rationale.
    var hasDetails: Bool {
        !services.isEmpty || !salons.isEmpty || !professionals.isEmpty
            || !packages.isEmpty || !slots.isEmpty
    }
}

/// Turns an `AssistantRecommendation` into an ``AssistantPlan`` by resolving
/// its identifiers through the repositories.
///
/// Every lookup is independent and failure-tolerant: a salon that no longer
/// exists simply drops out of the card instead of failing the whole answer.
enum AssistantPlanResolver {
    /// How far ahead to look for real availability when the assistant did not
    /// suggest slots itself.
    static let availabilityHorizonDays = 14
    /// How many suggested times a card shows.
    static let maximumSlots = 6
    /// At most this many suggestions per calendar day, so the row spreads
    /// across the week instead of stacking one morning.
    static let maximumSlotsPerDay = 2

    /// Resolves every reference in `recommendation`, then tops the plan up
    /// with live availability when it carries no suggested times.
    static func resolve(
        _ recommendation: AssistantRecommendation,
        using deps: PRVDependencies
    ) async -> AssistantPlan {
        async let servicesTask = services(recommendation.serviceIDs, using: deps)
        async let salonsTask = salons(recommendation.salonIDs, using: deps)
        async let professionalsTask = professionals(recommendation.professionalIDs, using: deps)
        async let packagesTask = packages(recommendation.packageIDs, using: deps)

        var plan = AssistantPlan(
            recommendation: recommendation,
            services: await servicesTask,
            salons: await salonsTask,
            professionals: await professionalsTask,
            packages: await packagesTask,
            slots: recommendation.suggestedSlots
        )

        if plan.slots.isEmpty {
            plan.slots = await availability(for: plan, using: deps)
        } else {
            plan.slots = spread(plan.slots)
        }
        return plan
    }

    // MARK: - Lookups

    private static func services(
        _ ids: [SalonService.ID],
        using deps: PRVDependencies
    ) async -> [SalonService] {
        await resolveAll(ids) { try await deps.salons.service(id: $0) }
    }

    private static func salons(
        _ ids: [Salon.ID],
        using deps: PRVDependencies
    ) async -> [Salon] {
        await resolveAll(ids) { try await deps.salons.salon(id: $0) }
    }

    private static func professionals(
        _ ids: [Professional.ID],
        using deps: PRVDependencies
    ) async -> [Professional] {
        await resolveAll(ids) { try await deps.salons.professional(id: $0) }
    }

    /// Packages are fetched as a catalogue and filtered — the repository has
    /// no by-ID accessor for them.
    private static func packages(
        _ ids: [ServicePackage.ID],
        using deps: PRVDependencies
    ) async -> [ServicePackage] {
        guard !ids.isEmpty else { return [] }
        guard let catalogue = try? await deps.memberships.packages(salonID: nil) else { return [] }
        return ids.compactMap { id in catalogue.first { $0.id == id } }
    }

    /// Fetches every entity concurrently, preserving the requested order and
    /// silently dropping anything that fails to resolve.
    private static func resolveAll<ID: Hashable & Sendable, Value: Sendable>(
        _ ids: [ID],
        fetch: @escaping @Sendable (ID) async throws -> Value
    ) async -> [Value] {
        guard !ids.isEmpty else { return [] }
        let resolved = await withTaskGroup(
            of: (Int, Value?).self,
            returning: [Int: Value].self
        ) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    let value = try? await fetch(id)
                    return (index, value)
                }
            }
            var buffer: [Int: Value] = [:]
            for await (index, value) in group {
                if let value { buffer[index] = value }
            }
            return buffer
        }
        return ids.indices.compactMap { resolved[$0] }
    }

    // MARK: - Availability

    /// Live availability for the plan's primary salon, spread across days.
    private static func availability(
        for plan: AssistantPlan,
        using deps: PRVDependencies
    ) async -> [TimeSlot] {
        guard let salonID = plan.primarySalonID else { return [] }
        let serviceIDs = plan.bookableServiceIDs
        guard !serviceIDs.isEmpty else { return [] }

        let request = AvailabilityRequest(
            salonID: salonID,
            serviceIDs: serviceIDs,
            rangeStart: .now,
            rangeEnd: Date.now.adding(days: availabilityHorizonDays)
        )
        guard let slots = try? await deps.appointments.availableSlots(request) else { return [] }
        return spread(slots)
    }

    /// Picks a readable handful of times: earliest first, at most
    /// ``maximumSlotsPerDay`` per day so the row covers several days.
    static func spread(_ slots: [TimeSlot], calendar: Calendar = .current) -> [TimeSlot] {
        var perDay: [Date: Int] = [:]
        var picked: [TimeSlot] = []
        for slot in slots.sorted(by: { $0.start < $1.start }) {
            let day = calendar.startOfDay(for: slot.start)
            let used = perDay[day, default: 0]
            guard used < maximumSlotsPerDay else { continue }
            perDay[day] = used + 1
            picked.append(slot)
            if picked.count == maximumSlots { break }
        }
        return picked
    }
}
