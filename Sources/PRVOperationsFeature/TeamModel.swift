import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

// MARK: - Roster member

/// An employment record joined to the professional profile it belongs to,
/// plus that person's goals for the current period.
///
/// The team repository stores employment (pay, vacation, role) while the salon
/// repository stores the public profile (name, photo, title); the roster needs
/// both, so the model joins them once instead of at every render.
struct TeamMember: Identifiable, Sendable {
    var employee: Employee
    var professional: Professional?
    var goals: [PerformanceGoal]

    var id: Employee.ID { employee.id }

    /// Display name, falling back to the role when no profile is linked yet.
    var displayName: String {
        professional?.displayName ?? employee.role.displayName
    }

    /// Job title from the profile, otherwise the platform role.
    var title: String {
        let profileTitle = professional?.title ?? ""
        return profileTitle.isBlank ? employee.role.displayName : profileTitle
    }

    var photoURL: URL? { professional?.photoURL }

    /// Vacation days taken out of the yearly allowance, as a 0…1 fraction.
    var vacationFraction: Double {
        let total = Double(employee.vacationDaysPerYear)
        guard total > 0 else { return 0 }
        return min(1, Double(employee.vacationDaysUsed) / total)
    }

    /// Vacation days still available this year (never negative).
    var vacationDaysRemaining: Int {
        max(0, employee.vacationDaysPerYear - employee.vacationDaysUsed)
    }
}

// MARK: - Shift draft

/// The editable shape of a shift, used by the add/edit sheet.
///
/// Times are carried as full `Date`s so the pickers can show hour + minute
/// while the model keeps them pinned to the day being edited.
struct ShiftDraft: Identifiable, Hashable, Sendable {
    /// `nil` when creating a new shift.
    var shiftID: Shift.ID?
    var employeeID: Employee.ID
    var start: Date
    var end: Date
    var note: String

    var id: String { shiftID?.description ?? "new-\(employeeID.description)" }

    /// Whether the draft describes an edit rather than a new shift.
    var isEditing: Bool { shiftID != nil }

    /// A shift is valid once it ends after it starts.
    var isValid: Bool { end > start }

    /// Scheduled length, for the sheet's live summary.
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Creates a draft for a new shift on `day`, defaulting to a 9–17 day.
    static func new(
        employeeID: Employee.ID,
        day: Date,
        calendar: Calendar = .current
    ) -> ShiftDraft {
        let start = day.startOfDay(in: calendar).adding(minutes: 9 * 60, calendar: calendar)
        return ShiftDraft(
            shiftID: nil,
            employeeID: employeeID,
            start: start,
            end: start.adding(minutes: 8 * 60, calendar: calendar),
            note: ""
        )
    }

    /// Creates a draft that edits an existing shift.
    static func editing(_ shift: Shift) -> ShiftDraft {
        ShiftDraft(
            shiftID: shift.id,
            employeeID: shift.employeeID,
            start: shift.start,
            end: shift.end,
            note: shift.note ?? ""
        )
    }

    /// Materializes the draft into a persistable shift.
    func shift(salonID: Salon.ID) -> Shift {
        Shift(
            id: shiftID ?? Shift.ID(),
            salonID: salonID,
            employeeID: employeeID,
            start: start,
            end: end,
            note: note.isBlank ? nil : note.trimmed
        )
    }
}

// MARK: - Time entry helpers

extension TimeEntry {
    /// Seconds worked, counting an open entry up to `now`.
    func elapsed(now: Date = .now) -> TimeInterval {
        max(0, (clockOut ?? now).timeIntervalSince(clockIn))
    }

    /// Whether the person is still on the clock.
    var isOpen: Bool { clockOut == nil }
}

// MARK: - Model

/// Screen model behind the Team desk of ``TeamView``.
///
/// One load fans out to the team repository (roster, plus goals and time
/// entries per employee), the salon repository (professional profiles for
/// names and photos), and — only when the session holds `.managePayroll` — the
/// analytics snapshot that the payroll estimate is derived from. The week
/// schedule reloads on its own so paging through weeks never re-fetches the
/// roster.
@Observable
@MainActor
final class TeamModel {
    // MARK: Selection

    /// Monday of the week shown on the schedule board.
    private(set) var weekStart: Date = Date.now.startOfWeek()
    /// The day highlighted in the schedule board's date strip.
    var selectedDay: Date = Date.now.startOfDay()

    // MARK: State

    private(set) var phase: OperationsPhase = .loading
    private(set) var salon: Salon?
    private(set) var members: [TeamMember] = []
    private(set) var shifts: [Shift] = []
    private(set) var timeEntries: [Employee.ID: [TimeEntry]] = [:]

    /// Employment record for the signed-in user, when their account is linked
    /// to one. Time tracking is only offered for this record.
    private(set) var currentEmployeeID: Employee.ID?

    private(set) var scheduleError: String?
    private(set) var payrollError: String?
    private(set) var payrollSnapshot: DashboardSnapshot?
    private(set) var isPayrollVisible = false

    /// True while a clock-in/out round trip (including the location fix) runs.
    private(set) var isClocking = false
    /// Explains a missing GPS validation after the last clock action.
    private(set) var locationNotice: String?
    /// Shifts currently being saved or deleted, so rows can refuse a second tap.
    private(set) var pendingShiftIDs: Set<Shift.ID> = []
    private(set) var isSavingShift = false

    /// Transient confirmation banner.
    var toast: PRVToast?
    /// The shift being added or edited, presented as a sheet when non-`nil`.
    var shiftDraft: ShiftDraft?

    /// `true` once a payload has landed; later refreshes keep content on screen.
    private(set) var hasLoadedOnce = false

    private let calendar = Calendar.current

    // MARK: Derived

    /// Currency of the salon being operated (falls back to euro).
    var currency: Currency { salon?.currency ?? .eur }

    /// The seven days shown on the schedule board.
    var weekDays: [Date] {
        (0 ..< 7).map { weekStart.adding(days: $0, calendar: calendar) }
    }

    /// The week window, used for the board's title.
    var weekInterval: DateInterval {
        DateInterval(start: weekStart, end: weekStart.adding(days: 7, calendar: calendar))
    }

    /// The employment record for the signed-in user, if any.
    var currentMember: TeamMember? {
        guard let currentEmployeeID else { return nil }
        return members.first { $0.id == currentEmployeeID }
    }

    /// The open time entry for the signed-in user, if they are on the clock.
    var activeEntry: TimeEntry? {
        guard let currentEmployeeID else { return nil }
        return timeEntries[currentEmployeeID]?.first(where: \.isOpen)
    }

    /// The signed-in user's recent time entries, newest first.
    var currentTimeEntries: [TimeEntry] {
        guard let currentEmployeeID else { return [] }
        return (timeEntries[currentEmployeeID] ?? []).sorted { $0.clockIn > $1.clockIn }
    }

    /// Hours the signed-in user has logged since Monday.
    var hoursThisWeek: TimeInterval {
        currentTimeEntries
            .filter { $0.clockIn >= weekStart && $0.clockIn < weekInterval.end }
            .reduce(0) { $0 + $1.elapsed() }
    }

    /// Shifts on `day`, oldest first.
    func shifts(on day: Date) -> [Shift] {
        shifts
            .filter { $0.start.isSameDay(as: day, calendar: calendar) }
            .sorted { $0.start < $1.start }
    }

    /// Shifts for one employee on `day`.
    func shifts(for employeeID: Employee.ID, on day: Date) -> [Shift] {
        shifts(on: day).filter { $0.employeeID == employeeID }
    }

    /// Scheduled hours for the whole salon on `day`.
    func scheduledHours(on day: Date) -> TimeInterval {
        shifts(on: day).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Display name for an employee, used in toasts and the schedule board.
    func name(for employeeID: Employee.ID) -> String {
        members.first { $0.id == employeeID }?.displayName ?? "Team member"
    }

    /// The payroll estimate table, empty when the session can't see payroll.
    var payroll: [PayrollEstimate] {
        guard isPayrollVisible, let payrollSnapshot else { return [] }
        return PayrollEstimator.estimates(
            members: members,
            snapshot: payrollSnapshot,
            timeEntries: timeEntries,
            currency: currency,
            period: payrollPeriod
        )
    }

    /// The window payroll is estimated over: this calendar month, to date.
    var payrollPeriod: DateInterval {
        let now = Date.now
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? now.startOfDay(in: calendar)
        return DateInterval(start: start, end: now.startOfDay(in: calendar).adding(days: 1, calendar: calendar))
    }

    /// Sum of every estimated payout in the period.
    var payrollTotal: Money {
        payroll.reduce(Money.zero(currency)) { $0 + $1.total }
    }

    // MARK: Loading

    /// Loads the roster, per-person goals and time entries, and — when
    /// permitted — the analytics snapshot behind the payroll estimate.
    /// - Parameters:
    ///   - salonID: The salon being operated.
    ///   - userID: Signed-in user, used to find their own employment record.
    ///   - canViewPayroll: Whether the session holds `.managePayroll`.
    ///   - deps: Repository container from the environment.
    func load(
        salonID: Salon.ID,
        userID: User.ID?,
        canViewPayroll: Bool,
        using deps: PRVDependencies
    ) async {
        if !hasLoadedOnce { phase = .loading }
        isPayrollVisible = canViewPayroll

        async let salonTask = deps.salons.salon(id: salonID)
        async let employeesTask = deps.team.employees(salonID: salonID)
        async let professionalsTask = deps.salons.professionals(salonID: salonID)

        // The salon record is chrome (name, currency) — never fail the roster
        // because of it.
        salon = try? await salonTask

        do {
            let employees = try await employeesTask
            let professionals = (try? await professionalsTask) ?? []
            let profilesByID = Dictionary(
                professionals.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            let details = await Self.loadDetails(for: employees, using: deps)

            members = employees
                .map { employee in
                    TeamMember(
                        employee: employee,
                        professional: profilesByID[employee.professionalID],
                        goals: details.goals[employee.id] ?? []
                    )
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            timeEntries = details.entries
            currentEmployeeID = Self.resolveCurrentEmployee(
                userID: userID,
                employees: employees,
                professionals: professionals
            )
            phase = .loaded
        } catch {
            phase = .failed(OperationsCopy.loadMessage(for: error, subject: "your team"))
        }

        if canViewPayroll {
            await loadPayroll(salonID: salonID, using: deps)
        } else {
            payrollSnapshot = nil
            payrollError = nil
        }

        hasLoadedOnce = true
    }

    /// Loads the shifts for the week currently on the board.
    func loadSchedule(salonID: Salon.ID, using deps: PRVDependencies) async {
        do {
            shifts = try await deps.team.shifts(salonID: salonID, weekContaining: weekStart)
                .filter { $0.start < weekInterval.end && $0.end > weekInterval.start }
            scheduleError = nil
        } catch {
            shifts = []
            scheduleError = OperationsCopy.loadMessage(for: error, subject: "the schedule")
        }
    }

    private func loadPayroll(salonID: Salon.ID, using deps: PRVDependencies) async {
        do {
            payrollSnapshot = try await deps.analytics.dashboard(
                salonID: salonID,
                periodStart: payrollPeriod.start,
                periodEnd: payrollPeriod.end
            )
            payrollError = nil
        } catch {
            payrollSnapshot = nil
            payrollError = OperationsCopy.loadMessage(for: error, subject: "payroll figures")
        }
    }

    /// Fetches goals and time entries for every employee concurrently.
    ///
    /// Both are per-person endpoints; a failure for one person degrades to an
    /// empty list rather than sinking the roster.
    private nonisolated static func loadDetails(
        for employees: [Employee],
        using deps: PRVDependencies
    ) async -> (goals: [Employee.ID: [PerformanceGoal]], entries: [Employee.ID: [TimeEntry]]) {
        await withTaskGroup(
            of: (Employee.ID, [PerformanceGoal], [TimeEntry]).self
        ) { group in
            for employee in employees {
                group.addTask {
                    async let goals = deps.team.goals(employeeID: employee.id)
                    async let entries = deps.team.timeEntries(employeeID: employee.id)
                    return (employee.id, (try? await goals) ?? [], (try? await entries) ?? [])
                }
            }

            var goals: [Employee.ID: [PerformanceGoal]] = [:]
            var entries: [Employee.ID: [TimeEntry]] = [:]
            for await (id, employeeGoals, employeeEntries) in group {
                goals[id] = employeeGoals
                entries[id] = employeeEntries
            }
            return (goals, entries)
        }
    }

    /// Finds the signed-in user's employment record.
    ///
    /// Employment rows may point at the account directly (`userID`) or only at
    /// the professional profile, which in turn points at the account. Managers
    /// and owners frequently have neither, and deliberately get no clock card
    /// rather than someone else's.
    private nonisolated static func resolveCurrentEmployee(
        userID: User.ID?,
        employees: [Employee],
        professionals: [Professional]
    ) -> Employee.ID? {
        guard let userID else { return nil }
        if let direct = employees.first(where: { $0.userID == userID }) {
            return direct.id
        }
        let profileIDs = Set(professionals.filter { $0.userID == userID }.map(\.id))
        return employees.first { profileIDs.contains($0.professionalID) }?.id
    }

    // MARK: Week paging

    /// Moves the schedule board a whole week forward or back.
    func shiftWeek(by weeks: Int) {
        weekStart = weekStart.adding(days: weeks * 7, calendar: calendar)
        selectedDay = weekStart
    }

    /// Returns the board to the current week.
    func goToCurrentWeek() {
        weekStart = Date.now.startOfWeek(calendar: calendar)
        selectedDay = Date.now.startOfDay(in: calendar)
    }

    /// Whether the board is showing the week that contains today.
    var isShowingCurrentWeek: Bool {
        weekStart.isSameDay(as: Date.now.startOfWeek(calendar: calendar), calendar: calendar)
    }

    // MARK: Shift editing

    /// Opens the sheet to add a shift for `employeeID` on the selected day.
    func addShift(for employeeID: Employee.ID) {
        PRVHaptics.tap()
        shiftDraft = .new(employeeID: employeeID, day: selectedDay, calendar: calendar)
    }

    /// Opens the sheet to edit an existing shift.
    func editShift(_ shift: Shift) {
        PRVHaptics.tap()
        shiftDraft = .editing(shift)
    }

    /// Persists a draft and folds the result into the board.
    /// - Returns: `true` when the shift was saved.
    @discardableResult
    func saveShift(_ draft: ShiftDraft, salonID: Salon.ID, using deps: PRVDependencies) async -> Bool {
        guard draft.isValid, !isSavingShift else { return false }
        isSavingShift = true
        defer { isSavingShift = false }

        do {
            let saved = try await deps.team.saveShift(draft.shift(salonID: salonID))
            if let index = shifts.firstIndex(where: { $0.id == saved.id }) {
                shifts[index] = saved
            } else {
                shifts.append(saved)
            }
            // Follow the shift if it was moved out of the week on screen, so the
            // board always shows what was just saved.
            let day = saved.start.startOfDay(in: calendar)
            if day < weekStart || day >= weekInterval.end {
                weekStart = day.startOfWeek(calendar: calendar)
            }
            selectedDay = day
            PRVHaptics.success()
            toast = .success(
                "\(name(for: saved.employeeID)) · \(OperationsFormat.window(saved.start, saved.end))"
            )
            return true
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "save this shift"))
            return false
        }
    }

    /// Removes a shift from the schedule.
    func deleteShift(_ shift: Shift, using deps: PRVDependencies) async {
        guard !pendingShiftIDs.contains(shift.id) else { return }
        pendingShiftIDs.insert(shift.id)
        defer { pendingShiftIDs.remove(shift.id) }

        do {
            try await deps.team.deleteShift(id: shift.id)
            shifts.removeAll { $0.id == shift.id }
            toast = .success("Shift removed for \(name(for: shift.employeeID))")
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "remove this shift"))
        }
    }

    // MARK: Time tracking

    /// Clocks the signed-in user in or out, attaching a one-shot coordinate so
    /// the backend can validate the entry against the salon's geofence.
    func toggleClock(using deps: PRVDependencies) async {
        guard let employeeID = currentEmployeeID, !isClocking else { return }
        isClocking = true
        defer { isClocking = false }

        let fix = await OperationsLocation.oneShot()

        do {
            if let active = activeEntry {
                let updated = try await deps.team.clockOut(entryID: active.id, location: fix.coordinate)
                replace(updated, for: employeeID)
                PRVHaptics.success()
                toast = .success("Clocked out · \(OperationsFormat.duration(updated.elapsed()))")
            } else {
                let entry = try await deps.team.clockIn(employeeID: employeeID, location: fix.coordinate)
                replace(entry, for: employeeID)
                PRVHaptics.success()
                toast = .success("Clocked in at \(OperationsFormat.time(entry.clockIn))")
            }
            locationNotice = fix.explanation
        } catch {
            PRVHaptics.warning()
            toast = .warning(OperationsCopy.saveMessage(for: error, action: "update your time entry"))
        }
    }

    /// Dismisses the "not GPS-verified" caption.
    func dismissLocationNotice() {
        locationNotice = nil
    }

    private func replace(_ entry: TimeEntry, for employeeID: Employee.ID) {
        var entries = timeEntries[employeeID] ?? []
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        timeEntries[employeeID] = entries.sorted { $0.clockIn > $1.clockIn }
    }
}

// MARK: - Week helpers

extension Date {
    /// The first day of the week containing this date, at midnight.
    func startOfWeek(calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: self)?.start ?? startOfDay(in: calendar)
    }
}
