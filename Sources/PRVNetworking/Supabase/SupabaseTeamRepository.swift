import Foundation
import PRVFoundation
import PRVModels

/// The live ``TeamRepository``, backed by the `employees`, `shifts`,
/// `time_entries`, and `performance_goals` tables.
///
/// The read/write asymmetry the product needs is already law in `0002_rls.sql`:
/// an employee sees their own record, their own shifts, and their own time
/// sheet; a manager holding `manageTeam` sees the roster; clocking in is a
/// personal act (`time_entries_insert_self` requires `checkInOut`) while
/// correcting a time sheet is a managerial one. None of that is re-implemented
/// here — a caller sees and writes exactly what the policies grant.
public struct SupabaseTeamRepository: TeamRepository, Sendable {
    private let client: SupabaseClient
    private let geofenceRadiusMetres: Double

    /// Widest set of rows any list endpoint returns.
    private static let listLimit = 200

    /// Creates the repository.
    ///
    /// - Parameters:
    ///   - client: The shared Supabase transport.
    ///   - geofenceRadiusMetres: How far from the salon's stored coordinate a
    ///     clock-in may be and still count as validated. The schema carries no
    ///     per-salon geofence, so this is the platform-wide default; it is an
    ///     initializer parameter rather than a constant so an operator running
    ///     large sites can widen it without a new build.
    public init(client: SupabaseClient, geofenceRadiusMetres: Double = 250) {
        self.client = client
        self.geofenceRadiusMetres = max(0, geofenceRadiusMetres)
    }

    // MARK: - Roster

    /// The salon's current employees, longest-serving first.
    ///
    /// Terminated employees are excluded. `Employee` has no `terminatedAt`
    /// property, so a former colleague returned here would be indistinguishable
    /// from a current one on every screen that shows the roster; the partial
    /// index `employees_salon_idx` exists for exactly this filter.
    public func employees(salonID: Salon.ID) async throws -> [Employee] {
        let request = PostgRESTQuery("employees")
            .filter(.equals("salon_id", salonID.rawValue))
            .filter(.isNull("terminated_at"))
            .order("hired_at")
            .limited(to: Self.listLimit)
        let rows: [EmployeeRow] = try await client.select(request)
        return try rows.map(Self.makeEmployee)
    }

    // MARK: - Scheduling

    /// Every shift in the calendar week containing `weekContaining`.
    ///
    /// The week is resolved with the device's calendar, so it starts on whatever
    /// weekday the user's locale says it does and the returned rows line up with
    /// the columns the roster grid draws. The window is half-open —
    /// `[weekStart, weekStart + 7 days)` — matching the analytics contract.
    public func shifts(salonID: Salon.ID, weekContaining: Date) async throws -> [Shift] {
        let week = Self.week(containing: weekContaining)
        let request = PostgRESTQuery("shifts")
            .filter(.equals("salon_id", salonID.rawValue))
            .filter(.atLeast("starts_at", SupabaseTimestamp.string(from: week.start)))
            .filter(.lessThan("starts_at", SupabaseTimestamp.string(from: week.end)))
            .order("starts_at")
            .limited(to: Self.listLimit)
        let rows: [ShiftRow] = try await client.select(request)
        return try rows.map(Self.makeShift)
    }

    /// Creates or replaces a shift, returning it as stored.
    ///
    /// The upsert resolves on the primary key, so the same call serves the "add
    /// shift" sheet and every later drag — which is what
    /// `InMemoryBackend.saveShift(_:)` does with its array. `note` is written
    /// even when empty, so clearing it clears the column.
    public func saveShift(_ shift: Shift) async throws -> Shift {
        let payload = ShiftUpsert(
            id: shift.id.rawValue,
            salonID: shift.salonID.rawValue,
            employeeID: shift.employeeID.rawValue,
            startsAt: SupabaseTimestamp.string(from: shift.start),
            endsAt: SupabaseTimestamp.string(from: shift.end),
            note: SupabaseNullableColumn(shift.note)
        )
        let row: ShiftRow = try await client.upsert(
            into: "shifts",
            values: payload,
            onConflict: "id"
        )
        return try Self.makeShift(row)
    }

    /// Removes a shift.
    ///
    /// A shift that is already gone — or belongs to a salon the caller cannot
    /// see, which RLS makes the same thing — deletes nothing and is not an
    /// error, matching `InMemoryBackend`'s `removeAll(where:)`.
    public func deleteShift(id: Shift.ID) async throws {
        try await client.deleteRows(from: "shifts", filters: [.equals("id", id.rawValue)])
    }

    // MARK: - Time sheet

    /// An employee's time entries, most recent first.
    public func timeEntries(employeeID: Employee.ID) async throws -> [TimeEntry] {
        let request = PostgRESTQuery("time_entries")
            .filter(.equals("employee_id", employeeID.rawValue))
            .order("clock_in", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [TimeEntryRow] = try await client.select(request)
        return try rows.map(Self.makeTimeEntry)
    }

    /// Starts a shift, recording where it was started from.
    ///
    /// `clock_in` is never sent: `time_entries.clock_in` defaults to `now()` and
    /// the database is the single clock, which is what stops a device with a
    /// skewed clock from paying itself for time it did not work. The partial
    /// unique index `time_entries_open_key` allows one open entry per employee,
    /// so clocking in twice raises `23505` and surfaces as
    /// ``APIError/conflict(_:)`` rather than silently opening a second shift.
    public func clockIn(employeeID: Employee.ID, location: GeoCoordinate?) async throws -> TimeEntry {
        let validated = try await isInsideGeofence(employeeID: employeeID, location: location)
        let payload = TimeEntryInsert(
            employeeID: employeeID.rawValue,
            clockInLatitude: location?.latitude,
            clockInLongitude: location?.longitude,
            gpsValidated: validated
        )
        let row: TimeEntryRow = try await client.insert(into: "time_entries", values: payload)
        return try Self.makeTimeEntry(row)
    }

    /// Ends a shift, recording where it was ended from.
    ///
    /// PostgREST has no way to write `now()` in an `UPDATE` payload, so unlike
    /// `clock_in` the closing instant is sent from the device. The
    /// `time_entries_span_ordered` constraint still refuses a clock-out that
    /// precedes its clock-in, which is the failure a skewed device clock would
    /// otherwise produce, and it surfaces as ``APIError/conflict(_:)``.
    ///
    /// `gps_validated` is deliberately left alone: it records whether the shift
    /// was *started* on site, which is the fact a payroll dispute turns on, and
    /// re-deriving it here would let a walk home overwrite it.
    public func clockOut(entryID: TimeEntry.ID, location: GeoCoordinate?) async throws -> TimeEntry {
        let payload = ClockOutUpdate(
            clockOut: SupabaseTimestamp.string(from: .now),
            clockOutLatitude: SupabaseNullableColumn(location?.latitude),
            clockOutLongitude: SupabaseNullableColumn(location?.longitude)
        )
        let row: TimeEntryRow = try await client.update(
            "time_entries",
            values: payload,
            filters: [.equals("id", entryID.rawValue)]
        )
        return try Self.makeTimeEntry(row)
    }

    // MARK: - Goals

    /// An employee's performance goals, most recent period first.
    public func goals(employeeID: Employee.ID) async throws -> [PerformanceGoal] {
        let request = PostgRESTQuery("performance_goals")
            .filter(.equals("employee_id", employeeID.rawValue))
            .order("period_start", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [PerformanceGoalRow] = try await client.select(request)
        return try rows.map(Self.makeGoal)
    }

    // MARK: - Geofence

    /// Whether a clock-in fix is close enough to the salon to count as validated.
    ///
    /// `TimeEntry.gpsValidated` documents itself as "the clock-in location was
    /// within the salon's geofence", so it is derived rather than set to "a fix
    /// was supplied": one embedded read resolves the salon's stored coordinate
    /// and the great-circle distance decides. No fix, no readable salon
    /// coordinate, or a fix outside ``geofenceRadiusMetres`` all read as
    /// unvalidated — the conservative answer for a payroll record, and the one a
    /// manager can then override on the time sheet.
    private func isInsideGeofence(employeeID: Employee.ID, location: GeoCoordinate?) async throws -> Bool {
        guard let location else { return false }
        let rows: [EmployeeSalonRow] = try await client.select(
            PostgRESTQuery("employees")
                .selecting("salons(latitude,longitude)")
                .filter(.equals("id", employeeID.rawValue))
                .limited(to: 1)
        )
        guard let salon = rows.first?.salons?.first else { return false }
        let centre = GeoCoordinate(latitude: salon.latitude, longitude: salon.longitude)
        return Self.distanceMetres(from: location, to: centre) <= geofenceRadiusMetres
    }

    /// Great-circle distance in metres.
    ///
    /// Implemented here rather than with `CLLocation` so the networking layer
    /// stays free of CoreLocation and of its main-thread-affine types.
    private static func distanceMetres(from origin: GeoCoordinate, to target: GeoCoordinate) -> Double {
        let earthRadius = 6_371_008.8
        let phi1 = origin.latitude * .pi / 180
        let phi2 = target.latitude * .pi / 180
        let deltaPhi = (target.latitude - origin.latitude) * .pi / 180
        let deltaLambda = (target.longitude - origin.longitude) * .pi / 180
        let haversine = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadius * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }

    // MARK: - Weeks

    /// The half-open week containing `day`, in the device's calendar.
    private static func week(
        containing day: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start
            ?? day.startOfDay(in: calendar)
        return (start, start.adding(days: 7, calendar: calendar))
    }

    // MARK: - Row mapping

    private static func makeEmployee(_ row: EmployeeRow) throws -> Employee {
        let currency = Currency(rawValue: row.currency.trimmed) ?? .eur
        return Employee(
            id: Employee.ID(row.id),
            salonID: Salon.ID(row.salonID),
            professionalID: Professional.ID(row.professionalID),
            userID: row.userID.map { User.ID($0) },
            role: UserRole(rawValue: row.role) ?? .salonEmployee,
            compensation: Employee.CompensationModel(rawValue: row.compensation) ?? .hybrid,
            monthlySalary: row.monthlySalaryAmount.map { Money($0, currency) },
            hourlyRate: row.hourlyRateAmount.map { Money($0, currency) },
            commissionPercent: row.commissionPercent,
            vacationDaysPerYear: row.vacationDaysPerYear,
            vacationDaysUsed: row.vacationDaysUsed,
            hiredAt: try SupabaseTimestamp.date(from: row.hiredAt)
        )
    }

    private static func makeShift(_ row: ShiftRow) throws -> Shift {
        Shift(
            id: Shift.ID(row.id),
            salonID: Salon.ID(row.salonID),
            employeeID: Employee.ID(row.employeeID),
            start: try SupabaseTimestamp.date(from: row.startsAt),
            end: try SupabaseTimestamp.date(from: row.endsAt),
            note: row.note
        )
    }

    private static func makeTimeEntry(_ row: TimeEntryRow) throws -> TimeEntry {
        TimeEntry(
            id: TimeEntry.ID(row.id),
            employeeID: Employee.ID(row.employeeID),
            clockIn: try SupabaseTimestamp.date(from: row.clockIn),
            clockOut: SupabaseTimestamp.optionalDate(from: row.clockOut),
            clockInLocation: coordinate(row.clockInLatitude, row.clockInLongitude),
            clockOutLocation: coordinate(row.clockOutLatitude, row.clockOutLongitude),
            gpsValidated: row.gpsValidated
        )
    }

    private static func makeGoal(_ row: PerformanceGoalRow) throws -> PerformanceGoal {
        PerformanceGoal(
            id: PerformanceGoal.ID(row.id),
            employeeID: Employee.ID(row.employeeID),
            metric: PerformanceGoal.Metric(rawValue: row.metric) ?? .revenue,
            target: row.target,
            progress: row.progress,
            periodStart: try SupabaseTimestamp.date(from: row.periodStart),
            periodEnd: try SupabaseTimestamp.date(from: row.periodEnd)
        )
    }

    /// A coordinate, or `nil` when either half of the pair is missing.
    ///
    /// The `time_entries_clock_in_coordinate_pair` constraints keep latitude and
    /// longitude null together, so this only ever collapses a genuinely absent
    /// fix.
    private static func coordinate(_ latitude: Double?, _ longitude: Double?) -> GeoCoordinate? {
        guard let latitude, let longitude else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Rows

extension SupabaseTeamRepository {
    /// An `employees` row.
    fileprivate struct EmployeeRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let professionalID: UUID
        let userID: UUID?
        let role: String
        let compensation: String
        let monthlySalaryAmount: Decimal?
        let hourlyRateAmount: Decimal?
        let currency: String
        let commissionPercent: Int
        let vacationDaysPerYear: Int
        let vacationDaysUsed: Int
        let hiredAt: String
    }

    /// An `employees` row reduced to the salon coordinate a geofence check needs.
    fileprivate struct EmployeeSalonRow: Decodable, Sendable {
        let salons: SupabaseEmbedded<SalonCoordinateRow>?
    }

    /// The `salons` columns embedded in a geofence lookup.
    fileprivate struct SalonCoordinateRow: Decodable, Sendable {
        let latitude: Double
        let longitude: Double
    }

    /// A `shifts` row.
    fileprivate struct ShiftRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let employeeID: UUID
        let startsAt: String
        let endsAt: String
        let note: String?
    }

    /// A `time_entries` row.
    fileprivate struct TimeEntryRow: Decodable, Sendable {
        let id: UUID
        let employeeID: UUID
        let clockIn: String
        let clockOut: String?
        let clockInLatitude: Double?
        let clockInLongitude: Double?
        let clockOutLatitude: Double?
        let clockOutLongitude: Double?
        let gpsValidated: Bool
    }

    /// A `performance_goals` row.
    fileprivate struct PerformanceGoalRow: Decodable, Sendable {
        let id: UUID
        let employeeID: UUID
        let metric: String
        let target: Decimal
        let progress: Decimal
        let periodStart: String
        let periodEnd: String
    }
}

// MARK: - Payloads

extension SupabaseTeamRepository {
    /// A whole shift, merged onto the primary key.
    fileprivate struct ShiftUpsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let employeeID: UUID
        let startsAt: String
        let endsAt: String
        let note: SupabaseNullableColumn<String>
    }

    /// A new open time entry. `clock_in` is left to the database.
    fileprivate struct TimeEntryInsert: Encodable, Sendable {
        let employeeID: UUID
        let clockInLatitude: Double?
        let clockInLongitude: Double?
        let gpsValidated: Bool
    }

    /// Closes an open time entry.
    fileprivate struct ClockOutUpdate: Encodable, Sendable {
        let clockOut: String
        let clockOutLatitude: SupabaseNullableColumn<Double>
        let clockOutLongitude: SupabaseNullableColumn<Double>
    }
}
