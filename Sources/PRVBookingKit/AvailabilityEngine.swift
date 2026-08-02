import Foundation
import PRVModels

// MARK: - AvailabilityInput

/// Everything the availability engine needs to enumerate bookable slots.
///
/// The type is a pure snapshot: it carries no repositories, no clock, and no
/// ambient state. `referenceDate` stands in for "now" so lead-time rules stay
/// testable — the engine never reads `Date.now`.
public struct AvailabilityInput: Sendable {
    /// The services to book, in the order they will be performed.
    public var services: [SalonService]
    /// The salon's weekly opening hours. A weekday with no entry is closed.
    public var openingHours: [OpeningHours]
    /// Appointments already on the salon's calendar. Inactive ones are ignored.
    public var existingAppointments: [Appointment]
    /// Professionals who could take the booking. Empty means the salon keeps no
    /// staff records and bookings are scheduled against salon-wide capacity.
    public var professionals: [Professional]
    /// Inclusive lower bound for the client-facing start of a slot.
    public var rangeStart: Date
    /// Inclusive upper bound for the client-facing start of a slot.
    public var rangeEnd: Date
    /// A specific professional the client asked for; `nil` means "any professional".
    public var preferredProfessionalID: Professional.ID?
    /// The instant that counts as "now"; `nil` disables lead-time filtering.
    public var referenceDate: Date?
    /// How far ahead of `referenceDate` the earliest slot may start.
    public var minimumLeadTimeMinutes: Int
    /// Extra client-facing minutes, e.g. the total `extraMinutes` of chosen add-ons.
    public var additionalMinutes: Int

    /// Creates an availability snapshot.
    public init(
        services: [SalonService],
        openingHours: [OpeningHours],
        existingAppointments: [Appointment] = [],
        professionals: [Professional] = [],
        rangeStart: Date,
        rangeEnd: Date,
        preferredProfessionalID: Professional.ID? = nil,
        referenceDate: Date? = nil,
        minimumLeadTimeMinutes: Int = 0,
        additionalMinutes: Int = 0
    ) {
        self.services = services
        self.openingHours = openingHours
        self.existingAppointments = existingAppointments
        self.professionals = professionals
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.preferredProfessionalID = preferredProfessionalID
        self.referenceDate = referenceDate
        self.minimumLeadTimeMinutes = minimumLeadTimeMinutes
        self.additionalMinutes = additionalMinutes
    }

    /// Builds an input from the shared `AvailabilityRequest` contract plus the data
    /// a feature module already holds. Service order follows `request.serviceIDs`.
    public init(
        request: AvailabilityRequest,
        salon: Salon,
        catalog: [SalonService],
        existingAppointments: [Appointment] = [],
        professionals: [Professional] = [],
        referenceDate: Date? = nil,
        minimumLeadTimeMinutes: Int = 0,
        additionalMinutes: Int = 0
    ) {
        let ordered = request.serviceIDs.compactMap { id in catalog.first { $0.id == id } }
        self.init(
            services: ordered,
            openingHours: salon.openingHours,
            existingAppointments: existingAppointments.filter { $0.salonID == salon.id },
            professionals: professionals.filter { $0.salonID == nil || $0.salonID == salon.id },
            rangeStart: request.rangeStart,
            rangeEnd: request.rangeEnd,
            preferredProfessionalID: request.professionalID,
            referenceDate: referenceDate,
            minimumLeadTimeMinutes: minimumLeadTimeMinutes,
            additionalMinutes: additionalMinutes
        )
    }

    /// The earliest client-facing start permitted by the lead-time rule.
    public var earliestBookableStart: Date {
        guard let referenceDate else { return .distantPast }
        return referenceDate.addingTimeInterval(TimeInterval(max(0, minimumLeadTimeMinutes) * 60))
    }

    /// The chair time this booking consumes.
    public var occupancy: ServiceOccupancy {
        ServiceOccupancy(services: services, additionalMinutes: additionalMinutes)
    }
}

// MARK: - SlotCandidate

/// A bookable slot together with the chair-time block it would reserve.
///
/// `slot` is what the client sees; `occupancy` is what the salon's calendar loses,
/// including preparation and cleanup. The schedule optimizer scores against
/// `occupancy`, because gap-filling is about chair time, not marketing copy.
public struct SlotCandidate: Hashable, Sendable, Identifiable {
    /// The client-facing window.
    public var slot: TimeSlot
    /// The full block reserved on the professional's calendar.
    public var occupancy: BookingInterval

    /// Creates a candidate.
    public init(slot: TimeSlot, occupancy: BookingInterval) {
        self.slot = slot
        self.occupancy = occupancy
    }

    /// Stable identity, shared with the underlying `TimeSlot`.
    public var id: String { slot.id }

    /// The professional the slot resolved to, if any.
    public var professionalID: Professional.ID? { slot.professionalID }

    /// Returns a copy whose slot carries `score`.
    public func scored(_ score: Double) -> SlotCandidate {
        var copy = self
        copy.slot.optimizationScore = score
        return copy
    }
}

// MARK: - AvailabilityEngine

/// Turns a salon's opening hours, committed appointments and staff roster into the
/// exact list of slots a client may book.
///
/// The engine is a pure function of its input. Given the same `AvailabilityInput`
/// and the same injected `Calendar` it always produces the same slots, in the same
/// order — which is what makes booking behaviour reviewable and testable.
///
/// Rules it enforces:
/// - the whole occupancy block (preparation + services + cleanup) must sit inside a
///   single opening interval, so nothing spills over a lunch break or closing time;
/// - closed weekdays produce nothing;
/// - a slot may not overlap a professional's committed chair time, padded on both
///   sides by the largest `bufferMinutes` among the booked services;
/// - "any professional" resolves to the least-loaded qualifying professional who is
///   free at that moment, measured by minutes already booked that day.
public struct AvailabilityEngine: Sendable {
    /// Tunables that shape slot generation.
    public struct Configuration: Hashable, Sendable {
        /// Spacing of candidate start times inside an opening interval.
        public var slotGranularityMinutes: Int
        /// Hard ceiling on returned slots, protecting the UI from unbounded lists.
        public var maximumSlots: Int
        /// Hard ceiling on days scanned, protecting against absurd date ranges.
        public var maximumDaysScanned: Int
        /// When a professional lists no services, treat them as able to perform
        /// everything (`true`) rather than nothing (`false`).
        public var treatsEmptyServiceRosterAsGeneralist: Bool

        /// Creates a configuration. Defaults match the PRV booking flow.
        public init(
            slotGranularityMinutes: Int = 15,
            maximumSlots: Int = 500,
            maximumDaysScanned: Int = 180,
            treatsEmptyServiceRosterAsGeneralist: Bool = true
        ) {
            self.slotGranularityMinutes = max(1, slotGranularityMinutes)
            self.maximumSlots = max(0, maximumSlots)
            self.maximumDaysScanned = max(1, maximumDaysScanned)
            self.treatsEmptyServiceRosterAsGeneralist = treatsEmptyServiceRosterAsGeneralist
        }
    }

    /// The calendar all day/weekday maths runs through.
    public let calendar: Calendar
    /// Slot-generation tunables.
    public let configuration: Configuration

    /// Creates an engine.
    /// - Parameters:
    ///   - calendar: inject the salon's calendar; defaults to the deterministic
    ///     `Calendar.prvBooking`.
    ///   - configuration: slot granularity and safety ceilings.
    public init(calendar: Calendar = .prvBooking, configuration: Configuration = Configuration()) {
        self.calendar = calendar
        self.configuration = configuration
    }

    /// The professionals able to perform every requested service.
    public func qualifyingProfessionals(for input: AvailabilityInput) -> [Professional] {
        let required = Set(input.services.map(\.id))
        return input.professionals.filter { professional in
            guard !professional.serviceIDs.isEmpty else {
                return configuration.treatsEmptyServiceRosterAsGeneralist
            }
            return required.isSubset(of: Set(professional.serviceIDs))
        }
    }

    /// Enumerates every bookable slot with its reserved chair-time block.
    ///
    /// Returns an empty array when the booking is impossible in principle — no
    /// services, an inactive service, an inverted range, or nobody who can perform
    /// the work.
    public func candidates(for input: AvailabilityInput) -> [SlotCandidate] {
        guard
            !input.services.isEmpty,
            input.services.allSatisfy(\.isActive),
            input.rangeStart <= input.rangeEnd
        else { return [] }

        let occupancy = input.occupancy
        guard occupancy.totalMinutes > 0 else { return [] }

        let busy = BusyIndex(appointments: input.existingAppointments)
        let resources = bookingResources(for: input, busy: busy)
        guard !resources.isEmpty else { return [] }

        let earliestStart = input.earliestBookableStart
        let granularity = configuration.slotGranularityMinutes
        var found: [SlotCandidate] = []

        var day = calendar.startOfDay(for: input.rangeStart)
        let finalDay = calendar.startOfDay(for: input.rangeEnd)
        var scannedDays = 0

        while day <= finalDay, scannedDays < configuration.maximumDaysScanned {
            scannedDays += 1
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day).map { calendar.startOfDay(for: $0) }
            let windows = input.openingHours.bookingWindows(on: day, calendar: calendar)

            if !windows.isEmpty {
                let dayWindow = BookingInterval(start: day, end: nextDay ?? day.addingTimeInterval(86_400))
                let ranked = rankedByLoad(resources, busy: busy, on: dayWindow)

                for window in windows {
                    let capacity = Int(window.duration / 60)
                    guard capacity >= occupancy.totalMinutes else { continue }
                    let lastOffset = capacity - occupancy.totalMinutes
                    var offset = 0

                    while offset <= lastOffset {
                        let blockStart = window.start.addingTimeInterval(TimeInterval(offset * 60))
                        offset += granularity

                        let block = BookingInterval(start: blockStart, minutes: occupancy.totalMinutes)
                        let clientWindow = occupancy.clientWindow(forBlockStart: blockStart)

                        guard
                            clientWindow.start >= input.rangeStart,
                            clientWindow.start <= input.rangeEnd,
                            clientWindow.start >= earliestStart
                        else { continue }

                        let reserved = block.padded(byMinutes: occupancy.bufferMinutes)
                        guard let resource = ranked.first(where: { candidate in
                            !candidate.busy.contains { $0.overlaps(reserved) }
                        }) else { continue }

                        found.append(
                            SlotCandidate(
                                slot: TimeSlot(
                                    start: clientWindow.start,
                                    end: clientWindow.end,
                                    professionalID: resource.professionalID
                                ),
                                occupancy: block
                            )
                        )
                    }
                }
            }

            guard let nextDay else { break }
            day = nextDay
        }

        let ordered = found.sorted { lhs, rhs in
            if lhs.slot.start != rhs.slot.start { return lhs.slot.start < rhs.slot.start }
            return (lhs.professionalID?.description ?? "") < (rhs.professionalID?.description ?? "")
        }
        return Array(ordered.prefix(configuration.maximumSlots))
    }

    /// Enumerates bookable slots, discarding the internal occupancy blocks.
    ///
    /// Use ``candidates(for:)`` instead when the result feeds `ScheduleOptimizer`,
    /// which needs the reserved block to reason about gaps.
    public func availableSlots(for input: AvailabilityInput) -> [TimeSlot] {
        candidates(for: input).map(\.slot)
    }

    /// `true` when `slot` is still bookable for `input` — the check to run again
    /// immediately before committing a booking, to close the race window.
    public func isStillAvailable(_ slot: TimeSlot, for input: AvailabilityInput) -> Bool {
        candidates(for: input).contains { candidate in
            candidate.slot.start == slot.start
                && candidate.slot.end == slot.end
                && (slot.professionalID == nil || candidate.professionalID == slot.professionalID)
        }
    }

    // MARK: Private

    /// One schedulable resource: a named professional, or the salon itself.
    private struct BookingResource: Sendable {
        var professionalID: Professional.ID?
        var order: Int
        var busy: [BookingInterval]
    }

    private func bookingResources(for input: AvailabilityInput, busy: BusyIndex) -> [BookingResource] {
        guard !input.professionals.isEmpty else {
            // No staff records: schedule against salon-wide capacity, which every
            // committed appointment consumes regardless of who performs it.
            guard input.preferredProfessionalID == nil else { return [] }
            return [BookingResource(professionalID: nil, order: 0, busy: busy.intervals(for: nil))]
        }

        var qualifying = qualifyingProfessionals(for: input)
        if let preferred = input.preferredProfessionalID {
            qualifying = qualifying.filter { $0.id == preferred }
        }
        return qualifying.enumerated().map { index, professional in
            BookingResource(
                professionalID: professional.id,
                order: index,
                busy: busy.intervals(for: professional.id)
            )
        }
    }

    /// Orders resources least-loaded-first for a single day.
    ///
    /// Load is measured once per day against the *committed* schedule, never against
    /// hypothetical slots — candidate slots are alternatives, not simultaneous
    /// bookings, so accumulating them would make the result order-dependent.
    private func rankedByLoad(
        _ resources: [BookingResource],
        busy: BusyIndex,
        on dayWindow: BookingInterval
    ) -> [BookingResource] {
        guard resources.count > 1 else { return resources }
        let loads = resources.map { busy.bookedMinutes(for: $0.professionalID, within: dayWindow) }
        return resources.indices
            .sorted { lhs, rhs in
                loads[lhs] == loads[rhs] ? resources[lhs].order < resources[rhs].order : loads[lhs] < loads[rhs]
            }
            .map { resources[$0] }
    }
}
