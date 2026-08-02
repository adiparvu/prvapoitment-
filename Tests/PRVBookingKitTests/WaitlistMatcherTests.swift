import Foundation
import PRVBookingKit
import PRVModels
import Testing

@Suite("WaitlistMatcher")
struct WaitlistMatcherTests {
    private let matcher = WaitlistMatcher()

    /// A freed 10:00–11:00 cut with professional A.
    private var freed: FreedSlot {
        FreedSlot(
            salonID: Fixtures.salonID,
            slot: TimeSlot(
                start: Fixtures.mondayAt(10),
                end: Fixtures.mondayAt(11),
                professionalID: Fixtures.proAID
            ),
            serviceIDs: [Fixtures.cutID]
        )
    }

    private func entry(
        id: WaitlistEntry.ID = Fixtures.waitlistOneID,
        salonID: Salon.ID = Fixtures.salonID,
        serviceID: SalonService.ID = Fixtures.cutID,
        professionalID: Professional.ID? = nil,
        earliest: Date = Fixtures.mondayAt(9),
        latest: Date = Fixtures.mondayAt(12),
        createdAt: Date = Fixtures.date(2026, 2, 1),
        notified: Bool = false
    ) -> WaitlistEntry {
        WaitlistEntry(
            id: id,
            salonID: salonID,
            clientID: Fixtures.clientID,
            serviceID: serviceID,
            professionalID: professionalID,
            earliest: earliest,
            latest: latest,
            createdAt: createdAt,
            notified: notified
        )
    }

    @Test("An entry whose window contains the freed slot matches")
    func containedWindowMatches() throws {
        let matches = matcher.matches(for: freed, in: [entry()])
        let match = try #require(matches.first)

        #expect(matches.count == 1)
        #expect(match.rank == 0)
        #expect(match.id == Fixtures.waitlistOneID)
        #expect(match.slot.start == Fixtures.mondayAt(10))
    }

    @Test("An entry whose window only partly covers the slot is rejected")
    func partiallyOverlappingWindowIsRejected() {
        let tooLate = entry(earliest: Fixtures.mondayAt(10, 30), latest: Fixtures.mondayAt(12))

        #expect(matcher.matches(for: freed, in: [tooLate]).isEmpty)
        #expect(!matcher.isCompatible(tooLate, with: freed))
    }

    @Test("Overlap matching can be opted into for looser waitlists")
    func overlapMatchingCanBeEnabled() {
        let relaxed = WaitlistMatcher(options: .init(requiresFullWindowContainment: false))
        let tooLate = entry(earliest: Fixtures.mondayAt(10, 30), latest: Fixtures.mondayAt(12))

        #expect(relaxed.matches(for: freed, in: [tooLate]).count == 1)
    }

    @Test("An entry for a different service never matches")
    func differentServiceIsRejected() {
        #expect(matcher.matches(for: freed, in: [entry(serviceID: Fixtures.manicureID)]).isEmpty)
    }

    @Test("An entry for a different salon never matches")
    func differentSalonIsRejected() {
        #expect(matcher.matches(for: freed, in: [entry(salonID: Fixtures.otherSalonID)]).isEmpty)
    }

    @Test("An entry asking for another professional is rejected")
    func mismatchedProfessionalIsRejected() {
        #expect(matcher.matches(for: freed, in: [entry(professionalID: Fixtures.proBID)]).isEmpty)
    }

    @Test("An entry asking for the slot's professional matches")
    func matchingProfessionalIsAccepted() {
        #expect(matcher.matches(for: freed, in: [entry(professionalID: Fixtures.proAID)]).count == 1)
    }

    @Test("An unassigned slot is offered even to clients with a preferred professional")
    func unassignedSlotMatchesPreferences() {
        let unassigned = FreedSlot(
            salonID: Fixtures.salonID,
            slot: TimeSlot(start: Fixtures.mondayAt(10), end: Fixtures.mondayAt(11)),
            serviceIDs: [Fixtures.cutID]
        )

        #expect(matcher.matches(for: unassigned, in: [entry(professionalID: Fixtures.proBID)]).count == 1)
    }

    @Test("Matches are ordered strictly first-come, first-served")
    func matchesAreFifo() {
        let newest = entry(id: Fixtures.waitlistOneID, createdAt: Fixtures.date(2026, 2, 20))
        let oldest = entry(id: Fixtures.waitlistTwoID, createdAt: Fixtures.date(2026, 1, 5))
        let middle = entry(id: Fixtures.waitlistThreeID, createdAt: Fixtures.date(2026, 2, 1))

        let matches = matcher.matches(for: freed, in: [newest, oldest, middle])

        #expect(matches.map(\.id) == [Fixtures.waitlistTwoID, Fixtures.waitlistThreeID, Fixtures.waitlistOneID])
        #expect(matches.map(\.rank) == [0, 1, 2])
        #expect(matcher.bestMatch(for: freed, in: [newest, oldest, middle])?.id == Fixtures.waitlistTwoID)
    }

    @Test("Entries created at the same instant break ties deterministically")
    func simultaneousEntriesAreDeterministic() {
        let sameInstant = Fixtures.date(2026, 2, 1)
        let two = entry(id: Fixtures.waitlistTwoID, createdAt: sameInstant)
        let one = entry(id: Fixtures.waitlistOneID, createdAt: sameInstant)

        #expect(matcher.matches(for: freed, in: [two, one]).map(\.id) == [Fixtures.waitlistOneID, Fixtures.waitlistTwoID])
        #expect(matcher.matches(for: freed, in: [one, two]).map(\.id) == [Fixtures.waitlistOneID, Fixtures.waitlistTwoID])
    }

    @Test("Already-notified entries are skipped unless explicitly included")
    func notifiedEntriesAreSkippedByDefault() {
        let alreadyPinged = entry(notified: true)
        let inclusive = WaitlistMatcher(options: .init(includesNotifiedEntries: true))

        #expect(matcher.matches(for: freed, in: [alreadyPinged]).isEmpty)
        #expect(inclusive.matches(for: freed, in: [alreadyPinged]).count == 1)
    }

    @Test("The match ceiling limits how many clients get pinged")
    func maximumMatchesLimitsResults() {
        let entries = [
            entry(id: Fixtures.waitlistOneID, createdAt: Fixtures.date(2026, 1, 5)),
            entry(id: Fixtures.waitlistTwoID, createdAt: Fixtures.date(2026, 1, 6)),
            entry(id: Fixtures.waitlistThreeID, createdAt: Fixtures.date(2026, 1, 7)),
        ]
        let limited = WaitlistMatcher(options: .init(maximumMatches: 2))

        #expect(limited.matches(for: freed, in: entries).map(\.id) == [Fixtures.waitlistOneID, Fixtures.waitlistTwoID])
        #expect(WaitlistMatcher(options: .init(maximumMatches: 0)).matches(for: freed, in: entries).isEmpty)
    }

    @Test("A cancelled appointment becomes a freed slot")
    func cancellationProducesAFreedSlot() throws {
        let appointment = Fixtures.appointment(
            start: Fixtures.mondayAt(10),
            minutes: 60,
            professionalID: Fixtures.proAID
        )
        let derived = try #require(FreedSlot(cancelling: appointment))

        #expect(derived.salonID == Fixtures.salonID)
        #expect(derived.slot.start == Fixtures.mondayAt(10))
        #expect(derived.slot.end == Fixtures.mondayAt(11))
        #expect(derived.slot.professionalID == Fixtures.proAID)
        #expect(derived.serviceIDs == [Fixtures.cutID])
        #expect(matcher.matches(for: derived, in: [entry()]).count == 1)
    }

    @Test("An appointment with no items cannot free a slot")
    func emptyAppointmentCannotFreeASlot() {
        let empty = Appointment(
            salonID: Fixtures.salonID,
            salonName: "Fixture Salon",
            clientID: Fixtures.clientID,
            items: []
        )

        #expect(FreedSlot(cancelling: empty) == nil)
    }

    @Test("An entry with an inverted availability window never matches")
    func invertedWindowIsRejected() {
        let broken = entry(earliest: Fixtures.mondayAt(12), latest: Fixtures.mondayAt(9))

        #expect(matcher.matches(for: freed, in: [broken]).isEmpty)
    }
}
