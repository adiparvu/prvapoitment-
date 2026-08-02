import Foundation

/// A single point in a time series (revenue per day, bookings per week, …).
public struct MetricPoint: Codable, Hashable, Sendable, Identifiable {
    public var date: Date
    public var value: Decimal

    public init(date: Date, value: Decimal) {
        self.date = date
        self.value = value
    }

    public var id: Date { date }
}

/// The salon dashboard's headline numbers for a period.
public struct DashboardSnapshot: Codable, Hashable, Sendable {
    public var salonID: Salon.ID
    public var periodStart: Date
    public var periodEnd: Date
    public var revenue: Money
    public var revenueForecast: Money
    public var appointmentCount: Int
    public var completedCount: Int
    public var cancellationRate: Double
    public var occupancyRate: Double
    public var newClientCount: Int
    public var returningClientCount: Int
    public var retentionRate: Double
    public var averageTicket: Money
    public var productsSold: Int
    public var membershipsSold: Int
    public var revenueSeries: [MetricPoint]
    public var revenueByService: [NamedMetric]
    public var revenueByEmployee: [NamedMetric]

    public init(
        salonID: Salon.ID,
        periodStart: Date,
        periodEnd: Date,
        revenue: Money = .zero(),
        revenueForecast: Money = .zero(),
        appointmentCount: Int = 0,
        completedCount: Int = 0,
        cancellationRate: Double = 0,
        occupancyRate: Double = 0,
        newClientCount: Int = 0,
        returningClientCount: Int = 0,
        retentionRate: Double = 0,
        averageTicket: Money = .zero(),
        productsSold: Int = 0,
        membershipsSold: Int = 0,
        revenueSeries: [MetricPoint] = [],
        revenueByService: [NamedMetric] = [],
        revenueByEmployee: [NamedMetric] = []
    ) {
        self.salonID = salonID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.revenue = revenue
        self.revenueForecast = revenueForecast
        self.appointmentCount = appointmentCount
        self.completedCount = completedCount
        self.cancellationRate = cancellationRate
        self.occupancyRate = occupancyRate
        self.newClientCount = newClientCount
        self.returningClientCount = returningClientCount
        self.retentionRate = retentionRate
        self.averageTicket = averageTicket
        self.productsSold = productsSold
        self.membershipsSold = membershipsSold
        self.revenueSeries = revenueSeries
        self.revenueByService = revenueByService
        self.revenueByEmployee = revenueByEmployee
    }
}

/// A labelled metric for breakdowns (revenue by service, by employee, …).
public struct NamedMetric: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var value: Decimal

    public init(name: String, value: Decimal) {
        self.name = name
        self.value = value
    }

    public var id: String { name }
}

/// A recorded, immutable audit trail entry for privileged actions.
public struct AuditLogEntry: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<AuditLogEntry>

    public var id: ID
    public var actorID: User.ID
    public var action: String
    public var entity: String
    public var entityID: UUID?
    public var detail: String?
    public var createdAt: Date

    public init(
        id: ID = ID(),
        actorID: User.ID,
        action: String,
        entity: String,
        entityID: UUID? = nil,
        detail: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.actorID = actorID
        self.action = action
        self.entity = entity
        self.entityID = entityID
        self.detail = detail
        self.createdAt = createdAt
    }
}
