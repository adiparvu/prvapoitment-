import Foundation
import PRVModels

/// Everything that can be wrong with a `BookingRequest`.
///
/// Cases carry the offending identifier so the booking UI can highlight the exact
/// row rather than showing a generic failure.
public enum BookingValidationError: LocalizedError, Hashable, Sendable {
    /// The request contains no services.
    case noServicesSelected
    /// A requested service is not in the salon's catalogue.
    case unknownService(SalonService.ID)
    /// A requested service exists but is no longer bookable.
    case inactiveService(SalonService.ID)
    /// A requested service belongs to a different salon.
    case serviceNotOfferedBySalon(SalonService.ID)
    /// A selected add-on does not belong to its service.
    case unknownAddOn(ServiceAddOn.ID)
    /// The requested professional is not on the salon's roster.
    case unknownProfessional(Professional.ID)
    /// The requested professional does not perform that service.
    case professionalCannotPerformService(professionalID: Professional.ID, serviceID: SalonService.ID)
    /// The slot ends at or before it starts.
    case invalidSlotBounds
    /// The slot length does not match the services and add-ons selected.
    case slotDurationMismatch(expectedMinutes: Int, actualMinutes: Int)
    /// The salon is closed on the requested weekday.
    case salonClosedOnRequestedDay
    /// The visit — including preparation and cleanup — does not fit inside one
    /// opening interval.
    case slotOutsideOpeningHours
    /// The slot has already happened.
    case slotInThePast
    /// The slot is sooner than the salon's minimum notice.
    case leadTimeNotMet(requiredMinutes: Int)
    /// A service requires a deposit but no prepayment level was chosen.
    case prepaymentRequired(SalonService.ID)
    /// The chosen prepayment level is not one the salon offers.
    case prepaymentPercentNotOffered(PrepaymentPolicy.Percent)
    /// The same person appears twice in a group booking.
    case duplicateClientInGroupBooking(User.ID)
    /// A recurrence rule asks for a non-positive number of occurrences.
    case invalidRecurrenceOccurrenceCount(Int)

    /// A user-facing explanation, suitable for a toast or inline error.
    public var errorDescription: String? {
        switch self {
        case .noServicesSelected:
            return "Choose at least one service to continue."
        case .unknownService:
            return "That service is no longer available at this salon."
        case .inactiveService:
            return "That service is not currently bookable."
        case .serviceNotOfferedBySalon:
            return "That service belongs to a different location."
        case .unknownAddOn:
            return "One of the selected add-ons is no longer offered."
        case .unknownProfessional:
            return "That professional is no longer part of this team."
        case .professionalCannotPerformService:
            return "The professional you picked doesn't perform this service."
        case .invalidSlotBounds:
            return "The selected time is invalid. Pick another slot."
        case let .slotDurationMismatch(expected, actual):
            return "This visit needs \(expected) minutes but the slot is \(actual)."
        case .salonClosedOnRequestedDay:
            return "The salon is closed that day."
        case .slotOutsideOpeningHours:
            return "That time falls outside the salon's opening hours."
        case .slotInThePast:
            return "That time has already passed."
        case let .leadTimeNotMet(minutes):
            return "This salon needs at least \(minutes) minutes' notice."
        case .prepaymentRequired:
            return "This service requires a deposit. Choose a prepayment option."
        case .prepaymentPercentNotOffered:
            return "That prepayment option isn't offered by this salon."
        case .duplicateClientInGroupBooking:
            return "Each guest can only be added once."
        case .invalidRecurrenceOccurrenceCount:
            return "A repeating booking needs at least one visit."
        }
    }
}

/// Validates a `BookingRequest` before it reaches the network.
///
/// The validator is intentionally exhaustive rather than fail-fast: it returns
/// *every* problem it finds, in a stable order, so a booking sheet can mark all
/// offending rows in one pass instead of walking the client through errors one at a
/// time. Use ``validateOrThrow(_:)`` when a single throwing failure is enough.
public struct BookingValidator: Sendable {
    /// The request plus the salon-side facts needed to judge it.
    public struct Input: Sendable {
        /// The submission under review.
        public var request: BookingRequest
        /// The salon being booked.
        public var salon: Salon
        /// The salon's service catalogue.
        public var catalog: [SalonService]
        /// The salon's professionals.
        public var professionals: [Professional]
        /// The instant that counts as "now"; `nil` disables time-based checks.
        public var referenceDate: Date?
        /// Minimum notice the salon requires, in minutes.
        public var minimumLeadTimeMinutes: Int
        /// When a professional lists no services, treat them as able to perform
        /// everything rather than nothing.
        public var treatsEmptyServiceRosterAsGeneralist: Bool

        /// Creates a validation input.
        public init(
            request: BookingRequest,
            salon: Salon,
            catalog: [SalonService],
            professionals: [Professional] = [],
            referenceDate: Date? = nil,
            minimumLeadTimeMinutes: Int = 0,
            treatsEmptyServiceRosterAsGeneralist: Bool = true
        ) {
            self.request = request
            self.salon = salon
            self.catalog = catalog
            self.professionals = professionals
            self.referenceDate = referenceDate
            self.minimumLeadTimeMinutes = minimumLeadTimeMinutes
            self.treatsEmptyServiceRosterAsGeneralist = treatsEmptyServiceRosterAsGeneralist
        }
    }

    /// The calendar used for opening-hours resolution.
    public let calendar: Calendar

    /// Creates a validator.
    public init(calendar: Calendar = .prvBooking) {
        self.calendar = calendar
    }

    /// Every problem with the request; empty means it is safe to submit.
    public func validate(_ input: Input) -> [BookingValidationError] {
        var errors: [BookingValidationError] = []
        let request = input.request

        if request.items.isEmpty {
            errors.append(.noServicesSelected)
        }

        var resolved: [SalonService] = []
        var addOnMinutes = 0

        for item in request.items {
            guard let service = input.catalog.first(where: { $0.id == item.serviceID }) else {
                errors.append(.unknownService(item.serviceID))
                continue
            }
            if !service.isActive {
                errors.append(.inactiveService(service.id))
            }
            if let owner = service.salonID, owner != input.salon.id {
                errors.append(.serviceNotOfferedBySalon(service.id))
            }
            for addOnID in item.addOnIDs {
                guard let addOn = service.addOns.first(where: { $0.id == addOnID }) else {
                    errors.append(.unknownAddOn(addOnID))
                    continue
                }
                addOnMinutes += max(0, addOn.extraMinutes)
            }
            if let professionalID = item.professionalID {
                if let professional = input.professionals.first(where: { $0.id == professionalID }) {
                    let capable = professional.serviceIDs.isEmpty
                        ? input.treatsEmptyServiceRosterAsGeneralist
                        : professional.serviceIDs.contains(service.id)
                    if !capable {
                        errors.append(
                            .professionalCannotPerformService(
                                professionalID: professionalID,
                                serviceID: service.id
                            )
                        )
                    }
                } else {
                    errors.append(.unknownProfessional(professionalID))
                }
            }
            if service.requiresPrepayment, request.prepaymentPercent == nil {
                errors.append(.prepaymentRequired(service.id))
            }
            resolved.append(service)
        }

        if let percent = request.prepaymentPercent,
           !input.salon.prepaymentPolicy.offeredPercents.contains(percent) {
            errors.append(.prepaymentPercentNotOffered(percent))
        }

        errors.append(contentsOf: slotErrors(for: input, resolved: resolved, addOnMinutes: addOnMinutes))

        var seen: Set<User.ID> = [request.clientID]
        for guestID in request.additionalClientIDs where !seen.insert(guestID).inserted {
            errors.append(.duplicateClientInGroupBooking(guestID))
        }

        if let recurrence = request.recurrence, let occurrences = recurrence.occurrences, occurrences < 1 {
            errors.append(.invalidRecurrenceOccurrenceCount(occurrences))
        }

        return errors
    }

    /// `true` when the request has no problems.
    public func isValid(_ input: Input) -> Bool {
        validate(input).isEmpty
    }

    /// Throws the first problem found, if any.
    public func validateOrThrow(_ input: Input) throws {
        if let first = validate(input).first { throw first }
    }

    // MARK: Private

    private func slotErrors(
        for input: Input,
        resolved: [SalonService],
        addOnMinutes: Int
    ) -> [BookingValidationError] {
        var errors: [BookingValidationError] = []
        let slot = input.request.slot

        guard slot.end > slot.start else {
            return [.invalidSlotBounds]
        }

        // Only judge duration and chair time when every requested service resolved —
        // otherwise the unknown-service errors already explain the mismatch.
        let fullyResolved = !resolved.isEmpty && resolved.count == input.request.items.count
        let occupancy = fullyResolved
            ? ServiceOccupancy(services: resolved, additionalMinutes: addOnMinutes)
            : nil

        if let occupancy {
            let actual = calendar.minutes(from: slot.start, to: slot.end)
            if occupancy.clientFacingMinutes != actual {
                errors.append(
                    .slotDurationMismatch(
                        expectedMinutes: occupancy.clientFacingMinutes,
                        actualMinutes: actual
                    )
                )
            }
        }

        let block = occupancy?.occupancyBlock(forClientStart: slot.start)
            ?? BookingInterval(start: slot.start, end: slot.end)
        let windows = input.salon.openingHours.bookingWindows(on: slot.start, calendar: calendar)
        if windows.isEmpty {
            errors.append(.salonClosedOnRequestedDay)
        } else if !windows.contains(where: { $0.contains(block) }) {
            errors.append(.slotOutsideOpeningHours)
        }

        if let now = input.referenceDate {
            if slot.start < now {
                errors.append(.slotInThePast)
            } else if input.minimumLeadTimeMinutes > 0,
                      slot.start < now.addingTimeInterval(TimeInterval(input.minimumLeadTimeMinutes * 60)) {
                errors.append(.leadTimeNotMet(requiredMinutes: input.minimumLeadTimeMinutes))
            }
        }

        return errors
    }
}
