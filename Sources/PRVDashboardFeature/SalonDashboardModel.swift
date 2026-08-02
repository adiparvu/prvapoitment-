import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model behind ``SalonDashboardView``.
///
/// One load fans out concurrently to the analytics repository (current window
/// *and* the equally sized previous window, which is what makes every KPI tile
/// show a trend), today's appointment book, and — for multi-location owners —
/// the organization roll-up. Side sections keep their own error strings so a
/// failing roll-up never hides the headline numbers.
@Observable
@MainActor
final class SalonDashboardModel {
    // MARK: Selection

    /// The window driving every figure on screen. Changing it reloads.
    var period: DashboardPeriod = .week

    // MARK: State

    private(set) var phase: DashboardPhase = .loading
    private(set) var snapshot: DashboardSnapshot?
    private(set) var previousSnapshot: DashboardSnapshot?
    private(set) var salon: Salon?

    /// Today's book, earliest first — independent of the reporting window.
    private(set) var todaysAppointments: [Appointment] = []
    private(set) var timelineError: String?

    /// Organization roll-up, populated only for users with `.compareLocations`.
    private(set) var locations: [LocationPerformance] = []
    private(set) var comparisonError: String?
    private(set) var isComparisonEnabled = false

    /// Appointments with a status change in flight, so their row can show a
    /// progress indicator and refuse a second tap.
    private(set) var pendingStatusChanges: Set<Appointment.ID> = []

    /// Transient confirmation banner.
    var toast: PRVToast?

    /// `true` once a payload has landed; later refreshes keep figures on screen
    /// instead of flashing skeletons.
    private(set) var hasLoadedOnce = false

    // MARK: Derived

    /// Currency of the salon being reported on (falls back to euro).
    var currency: Currency { salon?.currency ?? .eur }

    /// Headline KPI tiles for the current window.
    var kpis: [DashboardKPI] {
        guard let snapshot else { return [] }
        return DashboardMetrics.kpis(for: snapshot, previous: previousSnapshot, period: period)
    }

    /// Membership and retail tiles.
    var salesKPIs: [DashboardKPI] {
        guard let snapshot else { return [] }
        return DashboardMetrics.salesKPIs(for: snapshot, previous: previousSnapshot, period: period)
    }

    /// Actual revenue points, oldest first.
    var revenueSeries: [MetricPoint] {
        (snapshot?.revenueSeries ?? []).sorted { $0.date < $1.date }
    }

    /// Dashed forecast continuation of ``revenueSeries``.
    var forecastSeries: [MetricPoint] {
        guard let snapshot else { return [] }
        return DashboardMetrics.forecastSeries(for: snapshot)
    }

    /// Revenue split by service, highest first.
    var revenueByService: [NamedMetric] {
        (snapshot?.revenueByService ?? []).sorted { $0.value > $1.value }
    }

    /// Revenue leaderboard by team member.
    var employeeRanking: [DashboardMetrics.EmployeeRank] {
        guard let snapshot else { return [] }
        return DashboardMetrics.employeeRanking(for: snapshot, currency: currency)
    }

    /// Modelled occupancy grid for the window.
    var occupancyCells: [OccupancyHeatmap.Cell] {
        guard let snapshot else { return [] }
        return OccupancyHeatmap.cells(for: snapshot)
    }

    /// Human title for the window, e.g. `1 Jul – 7 Jul 2026`.
    var rangeTitle: String {
        DashboardFormat.rangeTitle(period.range())
    }

    /// Appointments still to happen today that need an action from the front
    /// desk (arrivals to check in, treatments to close out).
    var openAppointmentCount: Int {
        todaysAppointments.count { $0.status.isActive }
    }

    // MARK: Loading

    /// Loads (or refreshes) every dashboard section.
    /// - Parameters:
    ///   - salonID: The salon being reported on.
    ///   - canCompareLocations: Whether the session holds `.compareLocations`.
    ///   - ownerID: Signed-in user, used as the organization key fallback.
    ///   - deps: Repository container from the environment.
    func load(
        salonID: Salon.ID,
        canCompareLocations: Bool,
        ownerID: User.ID?,
        using deps: PRVDependencies
    ) async {
        if !hasLoadedOnce { phase = .loading }
        isComparisonEnabled = canCompareLocations

        let range = period.range()
        let previousRange = period.previousRange()

        async let currentTask = deps.analytics.dashboard(
            salonID: salonID,
            periodStart: range.start,
            periodEnd: range.end
        )
        async let previousTask = deps.analytics.dashboard(
            salonID: salonID,
            periodStart: previousRange.start,
            periodEnd: previousRange.end
        )
        async let salonTask = deps.salons.salon(id: salonID)
        async let bookTask = deps.appointments.appointments(salonID: salonID, on: .now)

        // The salon record is chrome (name, currency, organization) — a failure
        // there must never sink the numbers.
        salon = try? await salonTask

        do {
            snapshot = try await currentTask
            // The comparison window is optional: without it tiles simply drop
            // their trend rather than failing the screen.
            previousSnapshot = try? await previousTask
            phase = .loaded
        } catch {
            previousSnapshot = nil
            phase = .failed(DashboardCopy.friendlyMessage(for: error))
        }

        do {
            timelineError = nil
            todaysAppointments = try await bookTask
                .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
        } catch {
            todaysAppointments = []
            timelineError = DashboardCopy.friendlyMessage(for: error)
        }

        if canCompareLocations {
            await loadComparison(salonID: salonID, ownerID: ownerID, range: range, using: deps)
        } else {
            locations = []
            comparisonError = nil
        }

        hasLoadedOnce = true
    }

    /// Loads the organization roll-up and resolves each location's name.
    ///
    /// The organization key comes from the active salon. Locations that have
    /// not been grouped into an `Organization` record yet fall back to the
    /// owner's own identifier, which the backend accepts as an equivalent key.
    private func loadComparison(
        salonID: Salon.ID,
        ownerID: User.ID?,
        range: DateInterval,
        using deps: PRVDependencies
    ) async {
        guard let organizationID = salon?.organizationID ?? ownerID.map({ Organization.ID($0.rawValue) }) else {
            locations = []
            comparisonError = nil
            return
        }

        do {
            let snapshots = try await deps.analytics.organizationDashboard(
                organizationID: organizationID,
                periodStart: range.start,
                periodEnd: range.end
            )
            var names: [Salon.ID: String] = [:]
            if let salon { names[salon.id] = salon.name }
            for snapshot in snapshots where names[snapshot.salonID] == nil {
                if let record = try? await deps.salons.salon(id: snapshot.salonID) {
                    names[record.id] = record.name
                }
            }
            locations = LocationPerformance.ranking(from: snapshots, names: names)
            comparisonError = nil
        } catch {
            locations = []
            comparisonError = DashboardCopy.friendlyMessage(for: error)
        }
    }

    // MARK: Appointment status

    /// The next status in the front-desk flow, or `nil` once the appointment
    /// has reached a terminal state.
    nonisolated static func nextStatus(after status: AppointmentStatus) -> AppointmentStatus? {
        switch status {
        case .pendingConfirmation: .confirmed
        case .confirmed: .checkedIn
        case .checkedIn: .inProgress
        case .inProgress: .completed
        case .completed, .cancelledByClient, .cancelledBySalon, .noShow: nil
        }
    }

    /// Verb shown on the quick-action button for a status.
    nonisolated static func actionTitle(for status: AppointmentStatus) -> String? {
        switch status {
        case .pendingConfirmation: "Confirm"
        case .confirmed: "Check in"
        case .checkedIn: "Start"
        case .inProgress: "Complete"
        case .completed, .cancelledByClient, .cancelledBySalon, .noShow: nil
        }
    }

    /// Whether a status change for this appointment is already in flight.
    func isUpdating(_ appointmentID: Appointment.ID) -> Bool {
        pendingStatusChanges.contains(appointmentID)
    }

    /// Moves an appointment to `status`, updating the timeline in place.
    ///
    /// Success fires a success haptic and a confirmation toast; failure warns
    /// and leaves the previous status untouched so the book never lies.
    func updateStatus(
        of appointment: Appointment,
        to status: AppointmentStatus,
        using deps: PRVDependencies
    ) async {
        guard !pendingStatusChanges.contains(appointment.id) else { return }
        pendingStatusChanges.insert(appointment.id)
        defer { pendingStatusChanges.remove(appointment.id) }

        do {
            let updated = try await deps.appointments.updateStatus(
                appointmentID: appointment.id,
                status: status
            )
            if let index = todaysAppointments.firstIndex(where: { $0.id == updated.id }) {
                todaysAppointments[index] = updated
            }
            PRVHaptics.success()
            toast = .success("\(clientLabel(for: updated)) — \(status.displayName.lowercased())")
        } catch {
            PRVHaptics.warning()
            toast = .warning(DashboardCopy.friendlyMessage(for: error))
        }
    }

    /// The label used in confirmations: the first booked service, which is what
    /// the front desk recognizes at a glance.
    private func clientLabel(for appointment: Appointment) -> String {
        appointment.items.first?.serviceName ?? "Appointment"
    }
}
