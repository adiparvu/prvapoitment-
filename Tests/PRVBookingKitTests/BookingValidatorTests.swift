import Foundation
import PRVBookingKit
import PRVModels
import Testing

@Suite("BookingValidator")
struct BookingValidatorTests {
    private let validator = BookingValidator(calendar: Fixtures.calendar)

    private func input(
        request: BookingRequest,
        salon: Salon = Fixtures.salon(),
        catalog: [SalonService] = [Fixtures.plainCut],
        professionals: [Professional] = [],
        referenceDate: Date? = Fixtures.mondayAt(8),
        lead: Int = 0
    ) -> BookingValidator.Input {
        BookingValidator.Input(
            request: request,
            salon: salon,
            catalog: catalog,
            professionals: professionals,
            referenceDate: referenceDate,
            minimumLeadTimeMinutes: lead
        )
    }

    // MARK: Happy paths

    @Test("A well-formed request produces no errors")
    func validRequestPasses() {
        let errors = validator.validate(input(request: Fixtures.bookingRequest()))

        #expect(errors.isEmpty)
        #expect(validator.isValid(input(request: Fixtures.bookingRequest())))
    }

    @Test("Preparation and cleanup are allowed to sit inside opening hours")
    func paddedServiceFitsInsideOpeningHours() {
        let padded = Fixtures.service(duration: 60, prep: 10, cleanup: 15)
        let request = Fixtures.bookingRequest(slotStart: Fixtures.mondayAt(10), slotMinutes: 60)

        #expect(validator.validate(input(request: request, catalog: [padded])).isEmpty)
    }

    @Test("Add-on minutes count toward the expected slot length")
    func addOnMinutesExtendTheExpectedDuration() {
        let withAddOn = Fixtures.service(addOns: [Fixtures.olaplex])
        let request = Fixtures.bookingRequest(addOnIDs: [Fixtures.olaplexID], slotMinutes: 75)

        #expect(validator.validate(input(request: request, catalog: [withAddOn])).isEmpty)
    }

    @Test("Time checks are skipped when no reference date is supplied")
    func timeChecksNeedAReferenceDate() {
        let request = Fixtures.bookingRequest(slotStart: Fixtures.mondayAt(10))
        let errors = validator.validate(input(request: request, referenceDate: nil, lead: 10_000))

        #expect(errors.isEmpty)
    }

    // MARK: Service problems

    @Test("An empty item list is rejected")
    func emptyItemListIsRejected() {
        let request = BookingRequest(
            salonID: Fixtures.salonID,
            clientID: Fixtures.clientID,
            items: [],
            slot: TimeSlot(start: Fixtures.mondayAt(10), end: Fixtures.mondayAt(11))
        )

        #expect(validator.validate(input(request: request)) == [.noServicesSelected])
    }

    @Test("A service that is not in the catalogue is rejected")
    func unknownServiceIsRejected() {
        let request = Fixtures.bookingRequest(serviceID: Fixtures.colourID)
        let errors = validator.validate(input(request: request))

        #expect(errors.contains(.unknownService(Fixtures.colourID)))
    }

    @Test("An inactive service is rejected")
    func inactiveServiceIsRejected() {
        let retired = Fixtures.service(isActive: false)
        let errors = validator.validate(input(request: Fixtures.bookingRequest(), catalog: [retired]))

        #expect(errors.contains(.inactiveService(Fixtures.cutID)))
    }

    @Test("A service belonging to another location is rejected")
    func foreignServiceIsRejected() {
        let foreign = SalonService(
            id: Fixtures.cutID,
            salonID: Fixtures.otherSalonID,
            name: "Foreign Service",
            category: .hairSalon,
            price: Money(60),
            durationMinutes: 60
        )
        let errors = validator.validate(input(request: Fixtures.bookingRequest(), catalog: [foreign]))

        #expect(errors.contains(.serviceNotOfferedBySalon(Fixtures.cutID)))
    }

    @Test("An add-on that does not belong to the service is rejected")
    func unknownAddOnIsRejected() {
        let request = Fixtures.bookingRequest(addOnIDs: [Fixtures.olaplexID])
        let errors = validator.validate(input(request: request))

        #expect(errors.contains(.unknownAddOn(Fixtures.olaplexID)))
    }

    // MARK: Professional problems

    @Test("A professional who is not on the roster is rejected")
    func unknownProfessionalIsRejected() {
        let request = Fixtures.bookingRequest(professionalID: Fixtures.proBID)
        let errors = validator.validate(
            input(request: request, professionals: [Fixtures.professional(id: Fixtures.proAID)])
        )

        #expect(errors.contains(.unknownProfessional(Fixtures.proBID)))
    }

    @Test("A professional who does not perform the service is rejected")
    func unqualifiedProfessionalIsRejected() {
        let request = Fixtures.bookingRequest(professionalID: Fixtures.proAID)
        let manicurist = Fixtures.professional(id: Fixtures.proAID, serviceIDs: [Fixtures.manicureID])
        let errors = validator.validate(input(request: request, professionals: [manicurist]))

        #expect(errors.contains(
            .professionalCannotPerformService(professionalID: Fixtures.proAID, serviceID: Fixtures.cutID)
        ))
    }

    @Test("A professional whose roster covers the service passes")
    func qualifiedProfessionalPasses() {
        let request = Fixtures.bookingRequest(professionalID: Fixtures.proAID)
        let stylist = Fixtures.professional(id: Fixtures.proAID, serviceIDs: [Fixtures.cutID])

        #expect(validator.validate(input(request: request, professionals: [stylist])).isEmpty)
    }

    // MARK: Slot problems

    @Test("An inverted slot is rejected on its own")
    func invertedSlotIsRejected() {
        let request = BookingRequest(
            salonID: Fixtures.salonID,
            clientID: Fixtures.clientID,
            items: [BookingRequest.Item(serviceID: Fixtures.cutID)],
            slot: TimeSlot(start: Fixtures.mondayAt(11), end: Fixtures.mondayAt(10))
        )

        #expect(validator.validate(input(request: request)) == [.invalidSlotBounds])
    }

    @Test("A slot whose length does not match the services is rejected")
    func durationMismatchIsRejected() {
        let request = Fixtures.bookingRequest(slotMinutes: 90)
        let errors = validator.validate(input(request: request))

        #expect(errors.contains(.slotDurationMismatch(expectedMinutes: 60, actualMinutes: 90)))
    }

    @Test("A slot before opening time is rejected")
    func slotBeforeOpeningIsRejected() {
        let request = Fixtures.bookingRequest(slotStart: Fixtures.mondayAt(8))
        let errors = validator.validate(input(request: request, referenceDate: Fixtures.mondayAt(7)))

        #expect(errors.contains(.slotOutsideOpeningHours))
    }

    @Test("A slot whose cleanup would run past closing time is rejected")
    func cleanupPastClosingIsRejected() {
        let padded = Fixtures.service(duration: 60, prep: 10, cleanup: 15)
        let request = Fixtures.bookingRequest(slotStart: Fixtures.mondayAt(16, 55), slotMinutes: 60)
        let errors = validator.validate(input(request: request, catalog: [padded]))

        #expect(errors.contains(.slotOutsideOpeningHours))
    }

    @Test("A slot on a closed day is rejected")
    func closedDayIsRejected() {
        let request = Fixtures.bookingRequest(slotStart: Fixtures.sundayAt(10))
        let errors = validator.validate(input(request: request, referenceDate: Fixtures.sundayAt(8)))

        #expect(errors.contains(.salonClosedOnRequestedDay))
        #expect(!errors.contains(.slotOutsideOpeningHours))
    }

    @Test("A slot in the past is rejected")
    func pastSlotIsRejected() {
        let request = Fixtures.bookingRequest(slotStart: Fixtures.mondayAt(10))
        let errors = validator.validate(input(request: request, referenceDate: Fixtures.mondayAt(12)))

        #expect(errors.contains(.slotInThePast))
    }

    @Test("A slot inside the salon's minimum notice is rejected")
    func leadTimeIsEnforced() {
        let request = Fixtures.bookingRequest(slotStart: Fixtures.mondayAt(10))
        let errors = validator.validate(
            input(request: request, referenceDate: Fixtures.mondayAt(9, 30), lead: 120)
        )

        #expect(errors.contains(.leadTimeNotMet(requiredMinutes: 120)))
        #expect(!errors.contains(.slotInThePast))
    }

    // MARK: Payment, guests, recurrence

    @Test("A service that requires a deposit rejects a request without prepayment")
    func missingPrepaymentIsRejected() {
        let deposit = Fixtures.service(requiresPrepayment: true)
        let errors = validator.validate(input(request: Fixtures.bookingRequest(), catalog: [deposit]))

        #expect(errors.contains(.prepaymentRequired(Fixtures.cutID)))
    }

    @Test("Choosing an offered prepayment level satisfies a deposit requirement")
    func offeredPrepaymentSatisfiesDeposit() {
        let deposit = Fixtures.service(requiresPrepayment: true)
        let request = Fixtures.bookingRequest(prepaymentPercent: .fifty)

        #expect(validator.validate(input(request: request, catalog: [deposit])).isEmpty)
    }

    @Test("A prepayment level the salon does not offer is rejected")
    func unofferedPrepaymentIsRejected() {
        let request = Fixtures.bookingRequest(prepaymentPercent: .ten)
        let errors = validator.validate(input(request: request))

        #expect(errors.contains(.prepaymentPercentNotOffered(.ten)))
    }

    @Test("A guest listed twice in a group booking is rejected")
    func duplicateGuestIsRejected() {
        let request = Fixtures.bookingRequest(additionalClientIDs: [Fixtures.guestID, Fixtures.guestID])
        let errors = validator.validate(input(request: request))

        #expect(errors.contains(.duplicateClientInGroupBooking(Fixtures.guestID)))
    }

    @Test("The booker cannot also be listed as their own guest")
    func bookerCannotBeTheirOwnGuest() {
        let request = Fixtures.bookingRequest(additionalClientIDs: [Fixtures.clientID])
        let errors = validator.validate(input(request: request))

        #expect(errors.contains(.duplicateClientInGroupBooking(Fixtures.clientID)))
    }

    @Test("A recurrence asking for no visits is rejected")
    func invalidRecurrenceIsRejected() {
        let request = Fixtures.bookingRequest(recurrence: RecurrenceRule(frequency: .weekly, occurrences: 0))
        let errors = validator.validate(input(request: request))

        #expect(errors.contains(.invalidRecurrenceOccurrenceCount(0)))
    }

    @Test("A valid recurrence passes")
    func validRecurrencePasses() {
        let request = Fixtures.bookingRequest(recurrence: RecurrenceRule(frequency: .monthly, occurrences: 6))

        #expect(validator.validate(input(request: request)).isEmpty)
    }

    // MARK: Reporting

    @Test("Every problem is reported in one pass")
    func allProblemsAreReportedTogether() {
        let request = Fixtures.bookingRequest(
            serviceID: Fixtures.colourID,
            slotStart: Fixtures.mondayAt(8),
            additionalClientIDs: [Fixtures.clientID],
            prepaymentPercent: .ten
        )
        let errors = validator.validate(input(request: request, referenceDate: Fixtures.mondayAt(7)))

        #expect(errors.contains(.unknownService(Fixtures.colourID)))
        #expect(errors.contains(.prepaymentPercentNotOffered(.ten)))
        #expect(errors.contains(.slotOutsideOpeningHours))
        #expect(errors.contains(.duplicateClientInGroupBooking(Fixtures.clientID)))
        #expect(errors.count >= 4)
    }

    @Test("validateOrThrow surfaces the first problem")
    func validateOrThrowThrows() throws {
        let invalid = input(request: Fixtures.bookingRequest(serviceID: Fixtures.colourID))

        #expect(throws: BookingValidationError.self) {
            try validator.validateOrThrow(invalid)
        }
        try validator.validateOrThrow(input(request: Fixtures.bookingRequest()))
    }

    @Test("Every error carries a user-facing description")
    func errorsAreLocalized() {
        let samples: [BookingValidationError] = [
            .noServicesSelected,
            .unknownService(Fixtures.cutID),
            .inactiveService(Fixtures.cutID),
            .invalidSlotBounds,
            .slotDurationMismatch(expectedMinutes: 60, actualMinutes: 90),
            .salonClosedOnRequestedDay,
            .slotOutsideOpeningHours,
            .slotInThePast,
            .leadTimeNotMet(requiredMinutes: 120),
            .prepaymentRequired(Fixtures.cutID),
            .prepaymentPercentNotOffered(.ten),
            .duplicateClientInGroupBooking(Fixtures.clientID),
            .invalidRecurrenceOccurrenceCount(0),
        ]

        #expect(samples.allSatisfy { ($0.errorDescription ?? "").isEmpty == false })
    }
}
