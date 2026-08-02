import Foundation

/// Input to the availability engine: which services, with whom, and when.
public struct AvailabilityRequest: Codable, Hashable, Sendable {
    public var salonID: Salon.ID
    public var serviceIDs: [SalonService.ID]
    /// Preferred professional; nil = any available professional.
    public var professionalID: Professional.ID?
    public var rangeStart: Date
    public var rangeEnd: Date

    public init(
        salonID: Salon.ID,
        serviceIDs: [SalonService.ID],
        professionalID: Professional.ID? = nil,
        rangeStart: Date,
        rangeEnd: Date
    ) {
        self.salonID = salonID
        self.serviceIDs = serviceIDs
        self.professionalID = professionalID
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }
}

/// A booking submission from the client flow.
public struct BookingRequest: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var serviceID: SalonService.ID
        public var professionalID: Professional.ID?
        public var addOnIDs: [ServiceAddOn.ID]

        public init(
            serviceID: SalonService.ID,
            professionalID: Professional.ID? = nil,
            addOnIDs: [ServiceAddOn.ID] = []
        ) {
            self.serviceID = serviceID
            self.professionalID = professionalID
            self.addOnIDs = addOnIDs
        }
    }

    public var salonID: Salon.ID
    public var clientID: User.ID
    public var items: [Item]
    public var slot: TimeSlot
    /// Additional clients joining this visit (group booking).
    public var additionalClientIDs: [User.ID]
    public var recurrence: RecurrenceRule?
    public var notes: String?
    /// Chosen prepayment level (nil = pay at salon).
    public var prepaymentPercent: PrepaymentPolicy.Percent?
    public var couponCode: String?

    public init(
        salonID: Salon.ID,
        clientID: User.ID,
        items: [Item],
        slot: TimeSlot,
        additionalClientIDs: [User.ID] = [],
        recurrence: RecurrenceRule? = nil,
        notes: String? = nil,
        prepaymentPercent: PrepaymentPolicy.Percent? = nil,
        couponCode: String? = nil
    ) {
        self.salonID = salonID
        self.clientID = clientID
        self.items = items
        self.slot = slot
        self.additionalClientIDs = additionalClientIDs
        self.recurrence = recurrence
        self.notes = notes
        self.prepaymentPercent = prepaymentPercent
        self.couponCode = couponCode
    }
}
