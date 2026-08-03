import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The salon's command centre.
///
/// A period selector drives every figure on the screen: a KPI grid whose tiles
/// carry trends against the equally sized previous window, a scrubable revenue
/// chart with a dashed forecast, revenue split by service and by team member,
/// today's book as a one-tap timeline, a modelled occupancy heatmap, retail and
/// membership sales, and — for owners who hold `.compareLocations` — a
/// side-by-side roll-up of every location in the organization.
///
/// Data comes exclusively from `@Environment(\.prvDependencies)`; the salon in
/// scope comes from `UserSession.activeSalonID`; cross-feature navigation goes
/// through the shared `AppRouter`.
public struct SalonDashboardView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = SalonDashboardModel()

    private var kpiColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: PRVSpacing.sm)]
    }

    /// Creates the dashboard. All dependencies come from the environment; the
    /// initializer stays empty by contract.
    public init() {}

    public var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                header

                PRVSegmentedGlassControl(
                    selection: $model.period,
                    options: DashboardPeriod.allCases,
                    title: \.title
                )

                switch model.phase {
                case .loading:
                    DashboardSkeleton()
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    content
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Analytics is the dashboard's only outbound action and the only
            // route to the deep-dive report, so it is pinned to the trailing
            // edge and survives both the bar minimizing and a narrow width.
            ToolbarItem(placement: .topBarPinnedTrailing) {
                NavigationLink {
                    AnalyticsView()
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .accessibilityLabel("Open detailed analytics")
            }
        }
        // Eight sections of figures scroll past before this screen ends, and
        // the period control that drives all of them lives in the content — so
        // the navigation bar is the one piece of chrome that can step aside.
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .prvAnimation(PRVMotion.spring, value: model.period)
        .refreshable { await refresh() }
        .task(id: taskIdentity) { await refresh() }
        .prvToast($model.toast)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text(model.salon?.name ?? "Your salon")
                .prvStyle(.title)
                .lineLimit(2)
            Text("\(model.period.caption) · \(model.rangeTitle)")
                .prvStyle(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - States

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "chart.bar.xaxis",
            title: "Reports unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            PRVHaptics.tap()
            reload()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    @ViewBuilder
    private var content: some View {
        kpiGrid
        revenueSection
        serviceSection
        employeeSection
        timelineSection
        occupancySection
        salesSection
        comparisonSection
    }

    // MARK: - KPIs

    private var kpiGrid: some View {
        LazyVGrid(columns: kpiColumns, spacing: PRVSpacing.sm) {
            ForEach(model.kpis) { kpi in
                tile(for: kpi)
            }
        }
    }

    /// A stat tile whose VoiceOver label is replaced with a full sentence — the
    /// tile's default reads deltas without saying what they are measured
    /// against.
    ///
    /// The tile publishes its own accessibility element, so the element has to
    /// be re-created here before relabelling it; otherwise the inner label wins
    /// and `kpi.accessibilityLabel` never reaches VoiceOver.
    private func tile(for kpi: DashboardKPI) -> some View {
        PRVStatTile(
            label: kpi.label,
            value: kpi.value,
            trend: kpi.trend,
            sparkline: kpi.sparkline
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kpi.accessibilityLabel)
    }

    // MARK: - Revenue

    private var revenueSection: some View {
        RevenueChartCard(
            actual: model.revenueSeries,
            forecast: model.forecastSeries,
            currency: model.currency,
            periodCaption: model.period.caption
        )
    }

    private var serviceSection: some View {
        DashboardSection(
            "Revenue by Service",
            subtitle: "Where the money is coming from"
        ) {
            RevenueByServiceChart(metrics: model.revenueByService, currency: model.currency)
        }
    }

    private var employeeSection: some View {
        DashboardSection(
            "Team Leaderboard",
            subtitle: "Revenue per team member this period"
        ) {
            RevenueByEmployeeList(ranking: model.employeeRanking)
        }
    }

    // MARK: - Today

    @ViewBuilder
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader(
                "Today",
                subtitle: timelineSubtitle,
                actionTitle: "Calendar"
            ) {
                PRVHaptics.tap()
                router.selectedTab = .calendar
            }

            if let message = model.timelineError {
                DashboardErrorCard(message: message) { reload() }
            } else if model.todaysAppointments.isEmpty {
                PRVEmptyState(
                    systemImage: "calendar.badge.checkmark",
                    title: "A clear day",
                    message: "Nothing is booked today. A good moment to run a campaign or catch up on stock."
                )
                .prvGlassCard()
            } else {
                TodayTimeline(
                    appointments: model.todaysAppointments,
                    isUpdating: { model.isUpdating($0) },
                    advance: { appointment, status in advance(appointment, to: status) },
                    open: { router.push(.appointment($0.id)) }
                )
            }
        }
    }

    private var timelineSubtitle: String {
        let total = model.todaysAppointments.count
        guard total > 0 else { return "No appointments booked" }
        return "\(total) booked · \(model.openAppointmentCount) still open"
    }

    // MARK: - Occupancy

    private var occupancySection: some View {
        DashboardSection(
            "Occupancy",
            subtitle: "When your chairs are busiest"
        ) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                OccupancyHeatmapChart(cells: model.occupancyCells)
                DashboardFootnote(
                    "Distribution modelled from this period's occupancy rate and daily revenue mix."
                )
            }
        }
    }

    // MARK: - Sales

    private var salesSection: some View {
        DashboardSection(
            "Memberships & Retail",
            subtitle: "Recurring revenue and product sales"
        ) {
            LazyVGrid(columns: kpiColumns, spacing: PRVSpacing.sm) {
                ForEach(model.salesKPIs) { kpi in
                    tile(for: kpi)
                }
            }
        }
    }

    // MARK: - Multi-location

    @ViewBuilder
    private var comparisonSection: some View {
        if model.isComparisonEnabled {
            DashboardSection(
                "All Locations",
                subtitle: "How your salons compare this period"
            ) {
                if let message = model.comparisonError {
                    DashboardErrorCard(message: message) { reload() }
                } else if model.locations.isEmpty {
                    Text("No other locations are reporting in this period yet.")
                        .prvStyle(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .prvGlassCard()
                } else {
                    VStack(spacing: PRVSpacing.md) {
                        ForEach(model.locations) { location in
                            LocationComparisonRow(
                                location: location,
                                isActive: location.id == session.activeSalonID
                            )
                        }
                    }
                    .prvGlassCard()
                }
            }
        }
    }

    // MARK: - Actions

    /// The salon in scope, falling back to the flagship fixture so previews and
    /// demo mode always have something to report on.
    private var salonID: Salon.ID {
        session.activeSalonID ?? PreviewData.salonLumiere.id
    }

    /// Reload whenever the salon or the period changes.
    private var taskIdentity: String {
        "\(salonID.description)-\(model.period.rawValue)"
    }

    private func refresh() async {
        await model.load(
            salonID: salonID,
            canCompareLocations: session.can(.compareLocations),
            ownerID: session.currentUser?.id,
            using: deps
        )
    }

    private func reload() {
        let salonID = salonID
        let canCompare = session.can(.compareLocations)
        let ownerID = session.currentUser?.id
        let deps = deps
        Task {
            await model.load(
                salonID: salonID,
                canCompareLocations: canCompare,
                ownerID: ownerID,
                using: deps
            )
        }
    }

    private func advance(_ appointment: Appointment, to status: AppointmentStatus) {
        let deps = deps
        Task { await model.updateStatus(of: appointment, to: status, using: deps) }
    }
}

// MARK: - Location comparison row

/// One location in the organization roll-up, with its share of group revenue.
struct LocationComparisonRow: View {
    let location: LocationPerformance
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(spacing: PRVSpacing.xs) {
                Text(location.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(1)

                if isActive {
                    PRVBadge("Active", tint: Color.prv.accent)
                }

                Spacer(minLength: PRVSpacing.xxs)

                Text(location.revenue.formatted)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
            }

            HStack(spacing: PRVSpacing.xs) {
                PRVTag("\(location.appointmentCount) appts", systemImage: "calendar")
                PRVTag(DashboardFormat.percent(location.occupancyRate), systemImage: "chair.lounge")
                PRVTag(location.averageTicket.formatted, systemImage: "creditcard")
            }

            Capsule()
                .fill(Color.prv.separator.opacity(0.35))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Color.prv.accentGradient)
                            .frame(width: max(0, proxy.size.width * location.share))
                    }
                }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "\(location.name)\(isActive ? ", currently active" : ""). "
        label += "Revenue \(location.revenue.formatted), "
        label += "\(location.appointmentCount) appointments, "
        label += "occupancy \(DashboardFormat.percent(location.occupancyRate)), "
        label += "average ticket \(location.averageTicket.formatted), "
        label += "\(DashboardFormat.percent(location.share)) of group revenue."
        return label
    }
}

// MARK: - Previews

#Preview("Dashboard — Owner") {
    NavigationStack {
        SalonDashboardView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .dashboard))
}

#Preview("Dashboard — Dark") {
    NavigationStack {
        SalonDashboardView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .dashboard))
    .preferredColorScheme(.dark)
}

#Preview("Dashboard — Multi-location") {
    NavigationStack {
        SalonDashboardView()
    }
    .environment(UserSession.previewMultiSalonOwner)
    .environment(AppRouter(selectedTab: .dashboard))
}
