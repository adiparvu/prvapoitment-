import Foundation
import PRVBookingKit
import PRVModels
import Testing

@Suite("AvailabilityEngine")
struct AvailabilityEngineTests {
    // MARK: Opening hours

    @Test("Slots only appear inside the salon's opening hours")
    func slotsStayInsideOpeningHours() throws {
        let engine = Fixtures.engine(granularity: 60)
        let input = Fixtures.availability(services: [Fixtures.plainCut])
        let slots = engine.availableSlots(for: input)

        let first = try #require(slots.first)
        let last = try #require(slots.last)

        #expect(slots.count == 9)
        #expect(first.start == Fixtures.mondayAt(9))
        #expect(last.start == Fixtures.mondayAt(17))
        #expect(slots.allSatisfy { $0.start >= Fixtures.mondayAt(9) })
        #expect(slots.allSatisfy { $0.end <= Fixtures.mondayAt(18) })
    }

    @Test("A closed weekday produces no slots at all")
    func closedDayProducesNothing() {
        let engine = Fixtures.engine()
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            from: Fixtures.sunday,
            to: Fixtures.sundayAt(23, 59)
        )

        #expect(engine.availableSlots(for: input).isEmpty)
    }

    @Test("A lunch break splits availability into two blocks")
    func lunchBreakSplitsAvailability() {
        let engine = Fixtures.engine(granularity: 30)
        let input = Fixtures.availability(services: [Fixtures.plainCut], hours: Fixtures.splitHours)
        let slots = engine.availableSlots(for: input)
        let starts = slots.map(\.start)

        #expect(slots.count == 14)
        #expect(starts.contains(Fixtures.mondayAt(11)))
        #expect(starts.contains(Fixtures.mondayAt(13)))
        #expect(!starts.contains(Fixtures.mondayAt(11, 30)))
        #expect(!starts.contains(Fixtures.mondayAt(12)))
        #expect(!starts.contains(Fixtures.mondayAt(12, 30)))
    }

    // MARK: Preparation, cleanup, duration

    @Test("Preparation time pushes the first client-facing start past opening")
    func preparationDelaysFirstStart() throws {
        let engine = Fixtures.engine(granularity: 15)
        let service = Fixtures.service(duration: 60, prep: 10, cleanup: 15)
        let candidates = engine.candidates(for: Fixtures.availability(services: [service]))

        let first = try #require(candidates.first)
        #expect(first.slot.start == Fixtures.mondayAt(9, 10))
        #expect(first.occupancy.start == Fixtures.mondayAt(9))
        #expect(first.occupancy.durationMinutes == 85)
    }

    @Test("Cleanup must finish before closing time")
    func cleanupFitsBeforeClosing() throws {
        let engine = Fixtures.engine(granularity: 15)
        let service = Fixtures.service(duration: 60, prep: 10, cleanup: 15)
        let candidates = engine.candidates(for: Fixtures.availability(services: [service]))

        let last = try #require(candidates.last)
        #expect(last.slot.start == Fixtures.mondayAt(16, 40))
        #expect(last.occupancy.end == Fixtures.mondayAt(17, 55))
        #expect(candidates.allSatisfy { $0.occupancy.end <= Fixtures.mondayAt(18) })
    }

    @Test("The client-facing slot excludes preparation and cleanup")
    func clientWindowExcludesPadding() throws {
        let engine = Fixtures.engine(granularity: 15)
        let service = Fixtures.service(duration: 60, prep: 10, cleanup: 15)
        let slot = try #require(engine.availableSlots(for: Fixtures.availability(services: [service])).first)

        #expect(slot.end.timeIntervalSince(slot.start) == 60 * 60)
    }

    @Test("A chain of services occupies the sum of every service's chair time")
    func multiServiceChainOccupancy() throws {
        let engine = Fixtures.engine(granularity: 15)
        let first = Fixtures.service(id: Fixtures.cutID, duration: 60)
        let second = Fixtures.service(id: Fixtures.colourID, duration: 30, prep: 5, cleanup: 10)
        let candidate = try #require(
            engine.candidates(for: Fixtures.availability(services: [first, second])).first
        )

        #expect(candidate.occupancy.durationMinutes == 105)
        #expect(candidate.slot.start == Fixtures.mondayAt(9))
        #expect(candidate.slot.end == Fixtures.mondayAt(10, 35))
    }

    @Test("Add-on minutes extend the client-facing window")
    func addOnMinutesExtendSlot() throws {
        let engine = Fixtures.engine(granularity: 15)
        let input = Fixtures.availability(services: [Fixtures.plainCut], additionalMinutes: 15)
        let slot = try #require(engine.availableSlots(for: input).first)

        #expect(slot.end.timeIntervalSince(slot.start) == 75 * 60)
    }

    @Test("Slot starts are spaced by the configured granularity")
    func granularityControlsSpacing() {
        let engine = Fixtures.engine(granularity: 30)
        let slots = engine.availableSlots(for: Fixtures.availability(services: [Fixtures.plainCut]))
        let gaps = zip(slots, slots.dropFirst()).map { $1.start.timeIntervalSince($0.start) }

        #expect(!gaps.isEmpty)
        #expect(gaps.allSatisfy { $0 == 30 * 60 })
    }

    // MARK: Conflicts

    @Test("No slot may overlap a committed appointment")
    func overlapsArePrevented() {
        let engine = Fixtures.engine(granularity: 15)
        let booked = Fixtures.appointment(start: Fixtures.mondayAt(12), minutes: 60, professionalID: Fixtures.proAID)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [booked],
            professionals: [Fixtures.professional(id: Fixtures.proAID)]
        )
        let slots = engine.availableSlots(for: input)
        let starts = slots.map(\.start)

        let overlapping = slots.contains { $0.start < Fixtures.mondayAt(13) && $0.end > Fixtures.mondayAt(12) }
        #expect(!overlapping)
        #expect(starts.contains(Fixtures.mondayAt(11)))
        #expect(starts.contains(Fixtures.mondayAt(13)))
        #expect(!starts.contains(Fixtures.mondayAt(12)))
    }

    @Test("Buffer minutes keep new bookings clear of committed ones on both sides")
    func bufferIsRespectedOnBothSides() {
        let engine = Fixtures.engine(granularity: 15)
        let service = Fixtures.service(duration: 60, buffer: 15)
        let booked = Fixtures.appointment(start: Fixtures.mondayAt(12), minutes: 60, professionalID: Fixtures.proAID)
        let input = Fixtures.availability(
            services: [service],
            appointments: [booked],
            professionals: [Fixtures.professional(id: Fixtures.proAID)]
        )
        let starts = engine.availableSlots(for: input).map(\.start)

        #expect(starts.contains(Fixtures.mondayAt(10, 45)))
        #expect(!starts.contains(Fixtures.mondayAt(11)))
        #expect(!starts.contains(Fixtures.mondayAt(13)))
        #expect(starts.contains(Fixtures.mondayAt(13, 15)))
    }

    @Test("Cancelled appointments release their chair time")
    func cancelledAppointmentsDoNotBlock() {
        let engine = Fixtures.engine(granularity: 60)
        let cancelled = Fixtures.appointment(
            start: Fixtures.mondayAt(12),
            minutes: 60,
            professionalID: Fixtures.proAID,
            status: .cancelledByClient
        )
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [cancelled],
            professionals: [Fixtures.professional(id: Fixtures.proAID)]
        )

        #expect(engine.availableSlots(for: input).map(\.start).contains(Fixtures.mondayAt(12)))
    }

    @Test("A no-show also releases its chair time")
    func noShowAppointmentsDoNotBlock() {
        let engine = Fixtures.engine(granularity: 60)
        let noShow = Fixtures.appointment(
            start: Fixtures.mondayAt(12),
            minutes: 60,
            professionalID: Fixtures.proAID,
            status: .noShow
        )
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [noShow],
            professionals: [Fixtures.professional(id: Fixtures.proAID)]
        )

        #expect(engine.availableSlots(for: input).map(\.start).contains(Fixtures.mondayAt(12)))
    }

    // MARK: Professional resolution

    @Test("\"Any professional\" resolves to the least-loaded qualifying professional")
    func anyProfessionalPicksLeastLoaded() {
        let engine = Fixtures.engine(granularity: 60)
        let busyMorning = Fixtures.appointment(
            start: Fixtures.mondayAt(9),
            minutes: 180,
            professionalID: Fixtures.proAID
        )
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [busyMorning],
            professionals: [
                Fixtures.professional(id: Fixtures.proAID),
                Fixtures.professional(id: Fixtures.proBID),
            ]
        )
        let slots = engine.availableSlots(for: input)

        #expect(!slots.isEmpty)
        #expect(slots.allSatisfy { $0.professionalID == Fixtures.proBID })
    }

    @Test("Load balancing is recomputed for every day independently")
    func loadBalancingIsPerDay() {
        let engine = Fixtures.engine(granularity: 60)
        let mondayLoad = Fixtures.appointment(
            start: Fixtures.mondayAt(9),
            minutes: 180,
            professionalID: Fixtures.proAID
        )
        let tuesdayLoad = Fixtures.appointment(
            start: Fixtures.tuesdayAt(9),
            minutes: 240,
            professionalID: Fixtures.proBID
        )
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [mondayLoad, tuesdayLoad],
            professionals: [
                Fixtures.professional(id: Fixtures.proAID),
                Fixtures.professional(id: Fixtures.proBID),
            ],
            from: Fixtures.monday,
            to: Fixtures.tuesdayAt(23, 59)
        )
        let slots = engine.availableSlots(for: input)
        let mondaySlots = slots.filter { $0.start < Fixtures.tuesday }
        let tuesdaySlots = slots.filter { $0.start >= Fixtures.tuesday }

        #expect(!mondaySlots.isEmpty)
        #expect(!tuesdaySlots.isEmpty)
        #expect(mondaySlots.allSatisfy { $0.professionalID == Fixtures.proBID })
        #expect(tuesdaySlots.allSatisfy { $0.professionalID == Fixtures.proAID })
    }

    @Test("A preferred professional restricts every slot to that person")
    func preferredProfessionalRestrictsSlots() {
        let engine = Fixtures.engine(granularity: 60)
        let booked = Fixtures.appointment(start: Fixtures.mondayAt(12), minutes: 60, professionalID: Fixtures.proAID)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [booked],
            professionals: [
                Fixtures.professional(id: Fixtures.proAID),
                Fixtures.professional(id: Fixtures.proBID),
            ],
            preferred: Fixtures.proAID
        )
        let slots = engine.availableSlots(for: input)

        #expect(!slots.isEmpty)
        #expect(slots.allSatisfy { $0.professionalID == Fixtures.proAID })
        #expect(!slots.map(\.start).contains(Fixtures.mondayAt(12)))
    }

    @Test("Asking for a professional who is not on the roster yields nothing")
    func unknownPreferredProfessionalYieldsNothing() {
        let engine = Fixtures.engine()
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            professionals: [Fixtures.professional(id: Fixtures.proAID)],
            preferred: Fixtures.proCID
        )

        #expect(engine.availableSlots(for: input).isEmpty)
    }

    @Test("A professional who does not perform the service is excluded")
    func unqualifiedProfessionalIsExcluded() {
        let engine = Fixtures.engine()
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            professionals: [Fixtures.professional(id: Fixtures.proAID, serviceIDs: [Fixtures.manicureID])]
        )

        #expect(engine.availableSlots(for: input).isEmpty)
        #expect(engine.qualifyingProfessionals(for: input).isEmpty)
    }

    @Test("A professional whose roster covers every requested service qualifies")
    func qualifiedProfessionalIsIncluded() {
        let engine = Fixtures.engine(granularity: 60)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            professionals: [Fixtures.professional(id: Fixtures.proAID, serviceIDs: [Fixtures.cutID])]
        )

        #expect(engine.qualifyingProfessionals(for: input).count == 1)
        #expect(engine.availableSlots(for: input).allSatisfy { $0.professionalID == Fixtures.proAID })
    }

    @Test("An empty service roster can be treated as strictly unqualified")
    func generalistFlagCanBeDisabled() {
        let strict = Fixtures.engine(generalist: false)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            professionals: [Fixtures.professional(id: Fixtures.proAID)]
        )

        #expect(strict.availableSlots(for: input).isEmpty)
        #expect(!Fixtures.engine(generalist: true).availableSlots(for: input).isEmpty)
    }

    @Test("A salon with no staff records books against salon-wide capacity")
    func noProfessionalsFallsBackToSalonCapacity() {
        let engine = Fixtures.engine(granularity: 60)
        let booked = Fixtures.appointment(start: Fixtures.mondayAt(12), minutes: 60, professionalID: Fixtures.proAID)
        let input = Fixtures.availability(services: [Fixtures.plainCut], appointments: [booked])
        let slots = engine.availableSlots(for: input)

        #expect(!slots.isEmpty)
        #expect(slots.allSatisfy { $0.professionalID == nil })
        #expect(!slots.map(\.start).contains(Fixtures.mondayAt(12)))
    }

    // MARK: Guards and bounds

    @Test("An inactive service is never bookable")
    func inactiveServiceYieldsNothing() {
        let engine = Fixtures.engine()
        let input = Fixtures.availability(services: [Fixtures.service(isActive: false)])

        #expect(engine.availableSlots(for: input).isEmpty)
    }

    @Test("An empty service list yields nothing")
    func emptyServiceListYieldsNothing() {
        #expect(Fixtures.engine().availableSlots(for: Fixtures.availability(services: [])).isEmpty)
    }

    @Test("An inverted date range yields nothing")
    func invertedRangeYieldsNothing() {
        let engine = Fixtures.engine()
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            from: Fixtures.mondayAt(18),
            to: Fixtures.mondayAt(9)
        )

        #expect(engine.availableSlots(for: input).isEmpty)
    }

    @Test("Minimum lead time pushes the first bookable slot forward")
    func minimumLeadTimeIsRespected() throws {
        let engine = Fixtures.engine(granularity: 60)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            referenceDate: Fixtures.mondayAt(9),
            lead: 120
        )
        let slots = engine.availableSlots(for: input)
        let first = try #require(slots.first)

        #expect(first.start == Fixtures.mondayAt(11))
        #expect(slots.allSatisfy { $0.start >= Fixtures.mondayAt(11) })
    }

    @Test("The requested range clips slots at both ends")
    func rangeBoundsClipSlots() {
        let engine = Fixtures.engine(granularity: 60)
        let input = Fixtures.availability(
            services: [Fixtures.plainCut],
            from: Fixtures.mondayAt(11),
            to: Fixtures.mondayAt(15)
        )
        let slots = engine.availableSlots(for: input)

        #expect(slots.count == 5)
        #expect(slots.allSatisfy { $0.start >= Fixtures.mondayAt(11) && $0.start <= Fixtures.mondayAt(15) })
    }

    @Test("The slot ceiling caps the returned list")
    func maximumSlotsCapsResults() {
        let engine = Fixtures.engine(granularity: 15, maximumSlots: 5)

        #expect(engine.availableSlots(for: Fixtures.availability(services: [Fixtures.plainCut])).count == 5)
    }

    @Test("Re-checking a slot catches an appointment booked in the meantime")
    func availabilityRecheckCatchesRaces() throws {
        let engine = Fixtures.engine(granularity: 60)
        let professionals = [Fixtures.professional(id: Fixtures.proAID)]
        let before = Fixtures.availability(services: [Fixtures.plainCut], professionals: professionals)
        let slot = try #require(engine.availableSlots(for: before).first { $0.start == Fixtures.mondayAt(12) })

        #expect(engine.isStillAvailable(slot, for: before))

        let after = Fixtures.availability(
            services: [Fixtures.plainCut],
            appointments: [
                Fixtures.appointment(start: Fixtures.mondayAt(12), minutes: 60, professionalID: Fixtures.proAID),
            ],
            professionals: professionals
        )
        #expect(!engine.isStillAvailable(slot, for: after))
    }

    @Test("Slots are ordered chronologically")
    func slotsAreChronological() {
        let slots = Fixtures.engine(granularity: 30)
            .availableSlots(for: Fixtures.availability(
                services: [Fixtures.plainCut],
                from: Fixtures.monday,
                to: Fixtures.tuesdayAt(23, 59)
            ))

        #expect(zip(slots, slots.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    @Test("The AvailabilityRequest bridge orders services as requested")
    func availabilityRequestBridgePreservesOrder() {
        let colour = Fixtures.service(id: Fixtures.colourID, duration: 30)
        let request = AvailabilityRequest(
            salonID: Fixtures.salonID,
            serviceIDs: [Fixtures.colourID, Fixtures.cutID],
            rangeStart: Fixtures.monday,
            rangeEnd: Fixtures.mondayAt(23, 59)
        )
        let input = AvailabilityInput(
            request: request,
            salon: Fixtures.salon(),
            catalog: [Fixtures.plainCut, colour]
        )

        #expect(input.services.map(\.id) == [Fixtures.colourID, Fixtures.cutID])
        #expect(input.occupancy.clientFacingMinutes == 90)
    }
}
