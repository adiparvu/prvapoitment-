import Foundation

public enum AppointmentStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pendingConfirmation = "pending_confirmation"
    case confirmed
    case checkedIn = "checked_in"
    case inProgress = "in_progress"
    case completed
    case cancelledByClient = "cancelled_by_client"
    case cancelledBySalon = "cancelled_by_salon"
    case noShow = "no_show"

    public var isActive: Bool {
        switch self {
        case .pendingConfirmation, .confirmed, .checkedIn, .inProgress: true
        case .completed, .cancelledByClient, .cancelledBySalon, .noShow: false
        }
    }

    public var displayName: String {
        switch self {
        case .pendingConfirmation: "Pending"
        case .confirmed: "Confirmed"
        case .checkedIn: "Checked In"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        case .cancelledByClient: "Cancelled"
        case .cancelledBySalon: "Cancelled by Salon"
        case .noShow: "No-Show"
        }
    }
}

/// One booked service within an appointment (appointments can bundle several).
public struct AppointmentItem: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<AppointmentItem>

    public var id: ID
    public var serviceID: SalonService.ID
    public var serviceName: String
    public var professionalID: Professional.ID?
    public var professionalName: String?
    public var start: Date
    public var durationMinutes: Int
    public var price: Money
    public var addOnIDs: [ServiceAddOn.ID]

    public init(
        id: ID = ID(),
        serviceID: SalonService.ID,
        serviceName: String,
        professionalID: Professional.ID? = nil,
        professionalName: String? = nil,
        start: Date,
        durationMinutes: Int,
        price: Money,
        addOnIDs: [ServiceAddOn.ID] = []
    ) {
        self.id = id
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.professionalID = professionalID
        self.professionalName = professionalName
        self.start = start
        self.durationMinutes = durationMinutes
        self.price = price
        self.addOnIDs = addOnIDs
    }

    public var end: Date { start.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
}

public struct RecurrenceRule: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, Hashable, Sendable, CaseIterable {
        case weekly
        case biweekly
        case every4Weeks = "every_4_weeks"
        case monthly
    }

    public var frequency: Frequency
    /// Total occurrences including the first; nil = until cancelled.
    public var occurrences: Int?

    public init(frequency: Frequency, occurrences: Int? = nil) {
        self.frequency = frequency
        self.occurrences = occurrences
    }
}

public struct Appointment: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Appointment>

    public var id: ID
    public var salonID: Salon.ID
    public var salonName: String
    public var clientID: User.ID
    /// Additional clients for group bookings.
    public var additionalClientIDs: [User.ID]
    public var items: [AppointmentItem]
    public var status: AppointmentStatus
    public var recurrence: RecurrenceRule?
    /// Order that pays for this appointment, once checkout has happened.
    public var orderID: PRVID<Order>?
    public var clientNotes: String?
    public var internalNotes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        salonName: String,
        clientID: User.ID,
        additionalClientIDs: [User.ID] = [],
        items: [AppointmentItem],
        status: AppointmentStatus = .pendingConfirmation,
        recurrence: RecurrenceRule? = nil,
        orderID: PRVID<Order>? = nil,
        clientNotes: String? = nil,
        internalNotes: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.salonID = salonID
        self.salonName = salonName
        self.clientID = clientID
        self.additionalClientIDs = additionalClientIDs
        self.items = items
        self.status = status
        self.recurrence = recurrence
        self.orderID = orderID
        self.clientNotes = clientNotes
        self.internalNotes = internalNotes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var start: Date? { items.map(\.start).min() }
    public var end: Date? { items.map(\.end).max() }

    public var totalPrice: Money {
        guard let first = items.first else { return .zero() }
        return items.dropFirst().reduce(first.price) { $0 + $1.price }
    }

    public var isGroupBooking: Bool { !additionalClientIDs.isEmpty }
}

/// A concrete bookable slot produced by the availability engine.
public struct TimeSlot: Codable, Hashable, Sendable, Identifiable {
    public var start: Date
    public var end: Date
    public var professionalID: Professional.ID?
    /// Higher = better for the salon's calendar (gap-filling score).
    public var optimizationScore: Double

    public init(start: Date, end: Date, professionalID: Professional.ID? = nil, optimizationScore: Double = 0) {
        self.start = start
        self.end = end
        self.professionalID = professionalID
        self.optimizationScore = optimizationScore
    }

    public var id: String {
        "\(start.timeIntervalSince1970)-\(professionalID?.description ?? "any")"
    }
}

public struct WaitlistEntry: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<WaitlistEntry>

    public var id: ID
    public var salonID: Salon.ID
    public var clientID: User.ID
    public var serviceID: SalonService.ID
    public var professionalID: Professional.ID?
    /// Window the client is willing to come in.
    public var earliest: Date
    public var latest: Date
    public var createdAt: Date
    public var notified: Bool

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        clientID: User.ID,
        serviceID: SalonService.ID,
        professionalID: Professional.ID? = nil,
        earliest: Date,
        latest: Date,
        createdAt: Date = .now,
        notified: Bool = false
    ) {
        self.id = id
        self.salonID = salonID
        self.clientID = clientID
        self.serviceID = serviceID
        self.professionalID = professionalID
        self.earliest = earliest
        self.latest = latest
        self.createdAt = createdAt
        self.notified = notified
    }
}
