import Foundation

/// Employment details for a professional at a salon.
public struct Employee: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Employee>

    public enum CompensationModel: String, Codable, Hashable, Sendable, CaseIterable {
        case salary
        case hourly
        case commission
        case hybrid
    }

    public var id: ID
    public var salonID: Salon.ID
    public var professionalID: Professional.ID
    public var userID: User.ID?
    public var role: UserRole
    public var compensation: CompensationModel
    public var monthlySalary: Money?
    public var hourlyRate: Money?
    /// Commission percent (0–100) on services performed.
    public var commissionPercent: Int
    public var vacationDaysPerYear: Int
    public var vacationDaysUsed: Int
    public var hiredAt: Date

    public init(
        id: ID = ID(),
        salonID: Salon.ID,
        professionalID: Professional.ID,
        userID: User.ID? = nil,
        role: UserRole = .salonEmployee,
        compensation: CompensationModel = .hybrid,
        monthlySalary: Money? = nil,
        hourlyRate: Money? = nil,
        commissionPercent: Int = 0,
        vacationDaysPerYear: Int = 20,
        vacationDaysUsed: Int = 0,
        hiredAt: Date = .now
    ) {
        self.id = id
        self.salonID = salonID
        self.professionalID = professionalID
        self.userID = userID
        self.role = role
        self.compensation = compensation
        self.monthlySalary = monthlySalary
        self.hourlyRate = hourlyRate
        self.commissionPercent = commissionPercent
        self.vacationDaysPerYear = vacationDaysPerYear
        self.vacationDaysUsed = vacationDaysUsed
        self.hiredAt = hiredAt
    }
}

/// A scheduled working shift.
public struct Shift: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<Shift>

    public var id: ID
    public var salonID: Salon.ID
    public var employeeID: Employee.ID
    public var start: Date
    public var end: Date
    public var note: String?

    public init(id: ID = ID(), salonID: Salon.ID, employeeID: Employee.ID, start: Date, end: Date, note: String? = nil) {
        self.id = id
        self.salonID = salonID
        self.employeeID = employeeID
        self.start = start
        self.end = end
        self.note = note
    }
}

/// A clock-in/clock-out record, optionally validated by GPS proximity.
public struct TimeEntry: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<TimeEntry>

    public var id: ID
    public var employeeID: Employee.ID
    public var clockIn: Date
    public var clockOut: Date?
    public var clockInLocation: GeoCoordinate?
    public var clockOutLocation: GeoCoordinate?
    /// True when the clock-in location was within the salon's geofence.
    public var gpsValidated: Bool

    public init(
        id: ID = ID(),
        employeeID: Employee.ID,
        clockIn: Date,
        clockOut: Date? = nil,
        clockInLocation: GeoCoordinate? = nil,
        clockOutLocation: GeoCoordinate? = nil,
        gpsValidated: Bool = false
    ) {
        self.id = id
        self.employeeID = employeeID
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.clockInLocation = clockInLocation
        self.clockOutLocation = clockOutLocation
        self.gpsValidated = gpsValidated
    }
}

/// A monthly performance goal for an employee.
public struct PerformanceGoal: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<PerformanceGoal>

    public enum Metric: String, Codable, Hashable, Sendable, CaseIterable {
        case revenue
        case appointments
        case retailSales = "retail_sales"
        case rebookRate = "rebook_rate"
        case reviewScore = "review_score"
    }

    public var id: ID
    public var employeeID: Employee.ID
    public var metric: Metric
    public var target: Decimal
    public var progress: Decimal
    public var periodStart: Date
    public var periodEnd: Date

    public init(
        id: ID = ID(),
        employeeID: Employee.ID,
        metric: Metric,
        target: Decimal,
        progress: Decimal = 0,
        periodStart: Date,
        periodEnd: Date
    ) {
        self.id = id
        self.employeeID = employeeID
        self.metric = metric
        self.target = target
        self.progress = progress
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}
