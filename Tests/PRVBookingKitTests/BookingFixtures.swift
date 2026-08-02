import Foundation
import PRVBookingKit
import PRVModels

/// Deterministic scheduling fixtures.
///
/// Every date in the booking tests comes from here. The reference week is
/// **Monday 2 March 2026**, chosen because 1 March 2026 is a Sunday, which gives a
/// clean closed-day neighbour for opening-hours tests. All arithmetic runs through a
/// fixed UTC Gregorian calendar so results never depend on the machine's region,
/// locale, or daylight-saving rules — and `Date.now` never appears in an assertion.
enum Fixtures {
    // MARK: Calendar & dates

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    /// Sunday 1 March 2026 — the salon is closed.
    static var sunday: Date { date(2026, 3, 1) }
    /// Monday 2 March 2026, midnight.
    static var monday: Date { date(2026, 3, 2) }
    /// Tuesday 3 March 2026, midnight.
    static var tuesday: Date { date(2026, 3, 3) }

    static func sundayAt(_ hour: Int, _ minute: Int = 0) -> Date { date(2026, 3, 1, hour, minute) }
    static func mondayAt(_ hour: Int, _ minute: Int = 0) -> Date { date(2026, 3, 2, hour, minute) }
    static func tuesdayAt(_ hour: Int, _ minute: Int = 0) -> Date { date(2026, 3, 3, hour, minute) }

    // MARK: Opening hours

    /// Monday–Saturday 09:00–18:00, closed Sunday.
    static let standardHours: [OpeningHours] =
        (2...7).map { OpeningHours(weekday: $0, intervals: [.init(openMinutes: 540, closeMinutes: 1_080)]) }
            + [OpeningHours(weekday: 1, intervals: [])]

    /// Monday–Saturday 09:00–12:00 and 13:00–18:00, closed Sunday.
    static let splitHours: [OpeningHours] =
        (2...7).map {
            OpeningHours(
                weekday: $0,
                intervals: [
                    .init(openMinutes: 540, closeMinutes: 720),
                    .init(openMinutes: 780, closeMinutes: 1_080),
                ]
            )
        } + [OpeningHours(weekday: 1, intervals: [])]

    // MARK: Identifiers

    static let salonID = Salon.ID("10000000-0000-4000-8000-000000000001")
    static let otherSalonID = Salon.ID("10000000-0000-4000-8000-000000000002")
    static let clientID = User.ID("20000000-0000-4000-8000-000000000001")
    static let guestID = User.ID("20000000-0000-4000-8000-000000000002")

    static let cutID = SalonService.ID("30000000-0000-4000-8000-000000000001")
    static let colourID = SalonService.ID("30000000-0000-4000-8000-000000000002")
    static let manicureID = SalonService.ID("30000000-0000-4000-8000-000000000003")

    static let proAID = Professional.ID("40000000-0000-4000-8000-000000000001")
    static let proBID = Professional.ID("40000000-0000-4000-8000-000000000002")
    static let proCID = Professional.ID("40000000-0000-4000-8000-000000000003")

    static let waitlistOneID = WaitlistEntry.ID("50000000-0000-4000-8000-000000000001")
    static let waitlistTwoID = WaitlistEntry.ID("50000000-0000-4000-8000-000000000002")
    static let waitlistThreeID = WaitlistEntry.ID("50000000-0000-4000-8000-000000000003")

    static let olaplexID = ServiceAddOn.ID("60000000-0000-4000-8000-000000000001")

    // MARK: Services

    /// A 60-minute service with no preparation, cleanup, or buffer.
    static let plainCut = service()

    static func service(
        id: SalonService.ID = Fixtures.cutID,
        duration: Int = 60,
        prep: Int = 0,
        cleanup: Int = 0,
        buffer: Int = 0,
        isActive: Bool = true,
        requiresPrepayment: Bool = false,
        addOns: [ServiceAddOn] = []
    ) -> SalonService {
        SalonService(
            id: id,
            salonID: Fixtures.salonID,
            name: "Fixture Service",
            category: .hairSalon,
            price: Money(60),
            durationMinutes: duration,
            preparationMinutes: prep,
            cleanupMinutes: cleanup,
            bufferMinutes: buffer,
            isActive: isActive,
            requiresPrepayment: requiresPrepayment,
            addOns: addOns
        )
    }

    static let olaplex = ServiceAddOn(id: olaplexID, name: "Olaplex", price: Money(35), extraMinutes: 15)

    // MARK: Professionals

    static func professional(
        id: Professional.ID,
        name: String = "Fixture Pro",
        serviceIDs: [SalonService.ID] = []
    ) -> Professional {
        Professional(
            id: id,
            salonID: Fixtures.salonID,
            displayName: name,
            title: "Stylist",
            serviceIDs: serviceIDs
        )
    }

    // MARK: Salon

    static let address = Address(
        street: "Schuttershofstraat 24",
        city: "Antwerp",
        postalCode: "2000",
        country: "BE",
        coordinate: GeoCoordinate(latitude: 51.2178, longitude: 4.4041)
    )

    static func salon(
        hours: [OpeningHours] = Fixtures.standardHours,
        policies: SalonPolicies = SalonPolicies(),
        prepayment: PrepaymentPolicy = PrepaymentPolicy()
    ) -> Salon {
        Salon(
            id: Fixtures.salonID,
            name: "Fixture Salon",
            categories: [.hairSalon],
            address: Fixtures.address,
            openingHours: hours,
            policies: policies,
            prepaymentPolicy: prepayment
        )
    }

    // MARK: Appointments

    static func appointment(
        start: Date,
        minutes: Int,
        professionalID: Professional.ID?,
        serviceID: SalonService.ID = Fixtures.cutID,
        status: AppointmentStatus = .confirmed
    ) -> Appointment {
        Appointment(
            salonID: Fixtures.salonID,
            salonName: "Fixture Salon",
            clientID: Fixtures.clientID,
            items: [
                AppointmentItem(
                    serviceID: serviceID,
                    serviceName: "Fixture Service",
                    professionalID: professionalID,
                    start: start,
                    durationMinutes: minutes,
                    price: Money(60)
                ),
            ],
            status: status,
            createdAt: Fixtures.date(2026, 1, 1),
            updatedAt: Fixtures.date(2026, 1, 1)
        )
    }

    // MARK: Engines

    static func engine(
        granularity: Int = 15,
        maximumSlots: Int = 500,
        generalist: Bool = true
    ) -> AvailabilityEngine {
        AvailabilityEngine(
            calendar: Fixtures.calendar,
            configuration: AvailabilityEngine.Configuration(
                slotGranularityMinutes: granularity,
                maximumSlots: maximumSlots,
                treatsEmptyServiceRosterAsGeneralist: generalist
            )
        )
    }

    static func availability(
        services: [SalonService],
        hours: [OpeningHours] = Fixtures.standardHours,
        appointments: [Appointment] = [],
        professionals: [Professional] = [],
        from: Date = Fixtures.monday,
        to: Date = Fixtures.mondayAt(23, 59),
        preferred: Professional.ID? = nil,
        referenceDate: Date? = nil,
        lead: Int = 0,
        additionalMinutes: Int = 0
    ) -> AvailabilityInput {
        AvailabilityInput(
            services: services,
            openingHours: hours,
            existingAppointments: appointments,
            professionals: professionals,
            rangeStart: from,
            rangeEnd: to,
            preferredProfessionalID: preferred,
            referenceDate: referenceDate,
            minimumLeadTimeMinutes: lead,
            additionalMinutes: additionalMinutes
        )
    }

    // MARK: Booking requests

    static func bookingRequest(
        serviceID: SalonService.ID = Fixtures.cutID,
        professionalID: Professional.ID? = nil,
        addOnIDs: [ServiceAddOn.ID] = [],
        slotStart: Date = Fixtures.mondayAt(10),
        slotMinutes: Int = 60,
        additionalClientIDs: [User.ID] = [],
        recurrence: RecurrenceRule? = nil,
        prepaymentPercent: PrepaymentPolicy.Percent? = nil
    ) -> BookingRequest {
        BookingRequest(
            salonID: Fixtures.salonID,
            clientID: Fixtures.clientID,
            items: [
                BookingRequest.Item(
                    serviceID: serviceID,
                    professionalID: professionalID,
                    addOnIDs: addOnIDs
                ),
            ],
            slot: TimeSlot(
                start: slotStart,
                end: slotStart.addingTimeInterval(TimeInterval(slotMinutes * 60)),
                professionalID: professionalID
            ),
            additionalClientIDs: additionalClientIDs,
            recurrence: recurrence,
            prepaymentPercent: prepaymentPercent
        )
    }
}
