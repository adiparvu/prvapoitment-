import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The studio operations hub, and the module's root view.
///
/// A Liquid Glass segmented header switches between the three desks — Team,
/// Inventory, and Marketing — embedding ``InventoryView`` and ``MarketingView``
/// so the whole back office lives behind one tab. Each desk is also usable on
/// its own through its public initializer.
///
/// Data comes exclusively from `@Environment(\.prvDependencies)`; the salon in
/// scope comes from `UserSession.activeSalonID`; privileged blocks are gated on
/// `session.can(_:)` rather than on role names.
public struct TeamView: View {
    @State private var section: OperationsSection = .team

    /// Creates the operations hub. All dependencies come from the environment;
    /// the initializer stays empty by contract.
    public init() {}

    public var body: some View {
        VStack(spacing: PRVSpacing.md) {
            PRVSegmentedGlassControl(
                selection: $section,
                options: OperationsSection.allCases,
                title: \.title
            )
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.top, PRVSpacing.xs)
            .accessibilityLabel("Operations desk")

            switch section {
            case .team:
                TeamDeskView()
            case .inventory:
                InventoryView(isEmbedded: true)
            case .marketing:
                MarketingView(isEmbedded: true)
            }
        }
        .background(Color.prv.canvas)
        .navigationTitle("Studio")
        .navigationBarTitleDisplayMode(.large)
        // The desk switcher is fixed chrome above three long working scrolls,
        // so the bar is the only thing that can give them height back on the
        // way down. The desks defer to the hub here — see `isEmbedded`.
        .toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)
        .prvAnimation(PRVMotion.morph, value: section)
    }
}

// MARK: - Team desk

/// The Team desk: personal time clock, roster, week schedule, time off, and —
/// for owners — a payroll estimate.
struct TeamDeskView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model = TeamModel()

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: PRVSpacing.xl) {
                switch model.phase {
                case .loading:
                    OperationsSkeleton(rows: 3, label: "Loading your team")
                case .failed(let message):
                    failureState(message)
                case .loaded:
                    content
                }
            }
            .padding(.horizontal, PRVSpacing.lg)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        // The schedule board's shifts are cards in this scroll view, not `List`
        // rows — the container is what lets them answer a swipe while the desk
        // keeps its glass-card layout.
        .swipeActionsContainer()
        .background(Color.prv.canvas)
        .refreshable { await refreshAll() }
        .task(id: rosterIdentity) { await loadRoster() }
        .task(id: scheduleIdentity) { await loadSchedule() }
        .prvToast($model.toast)
        .prvAnimation(PRVMotion.gentle, value: model.phase)
        .sheet(item: $model.shiftDraft) { draft in
            ShiftEditorSheet(
                draft: draft,
                members: model.members,
                existingShifts: model.shifts,
                isSaving: model.isSavingShift,
                save: { edited in
                    await model.saveShift(edited, salonID: salonID, using: deps)
                }
            )
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        clockSection

        if model.members.isEmpty {
            PRVEmptyState(
                systemImage: "person.2.badge.gearshape",
                title: "No team yet",
                message: "Once staff are added to this salon they'll appear here with their schedule, goals, and time off.",
                actionTitle: "Refresh"
            ) {
                reloadRoster()
            }
        } else {
            rosterSection
            ShiftBoardView(
                model: model,
                canManage: canManageTeam,
                delete: { shift in
                    Task { await model.deleteShift(shift, using: deps) }
                },
                retry: { reloadSchedule() }
            )
            timeOffSection
            if model.isPayrollVisible {
                PayrollSummaryCard(
                    estimates: model.payroll,
                    total: model.payrollTotal,
                    period: model.payrollPeriod,
                    errorMessage: model.payrollError,
                    retry: { reloadRoster() }
                )
            } else {
                OperationsLockedNotice(
                    title: "Payroll is restricted",
                    message: "Estimated pay is only visible to team members with payroll permission."
                )
            }
        }
    }

    // MARK: Clock

    @ViewBuilder
    private var clockSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            ClockInCard(
                member: model.currentMember,
                activeEntry: model.activeEntry,
                hoursThisWeek: model.hoursThisWeek,
                isBusy: model.isClocking,
                locationNotice: model.locationNotice,
                dismissNotice: { model.dismissLocationNotice() },
                toggle: {
                    PRVHaptics.impact()
                    Task { await model.toggleClock(using: deps) }
                }
            )

            if model.currentMember != nil {
                historyBlock
            }
        }
    }

    private var historyBlock: some View {
        OperationsBlock("Recent Hours", subtitle: "Your last time entries") {
            if model.currentTimeEntries.isEmpty {
                Text("No hours logged yet. Clock in above to start your first entry.")
                    .prvStyle(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .prvGlassCard()
            } else {
                VStack(spacing: PRVSpacing.sm) {
                    ForEach(recentEntries) { entry in
                        TimeEntryRow(entry: entry)
                        if entry.id != recentEntries.last?.id {
                            Divider().overlay(Color.prv.separator.opacity(0.5))
                        }
                    }
                }
                .prvGlassCard()
            }
        }
    }

    /// The most recent entries shown in the history block.
    private var recentEntries: [TimeEntry] {
        Array(model.currentTimeEntries.prefix(6))
    }

    // MARK: Roster

    private var rosterSection: some View {
        OperationsBlock(
            "Team",
            subtitle: "\(model.members.count) on the roster"
        ) {
            VStack(spacing: PRVSpacing.md) {
                ForEach(model.members) { member in
                    EmployeeCard(
                        member: member,
                        currency: model.currency,
                        canRevealPay: session.can(.managePayroll),
                        isCurrentUser: member.id == model.currentEmployeeID,
                        openProfile: openProfile(for: member)
                    )
                }
            }
        }
    }

    // MARK: Time off

    private var timeOffSection: some View {
        OperationsBlock(
            "Time Off",
            subtitle: "Vacation used against this year's allowance"
        ) {
            VStack(spacing: PRVSpacing.md) {
                ForEach(model.members) { member in
                    VacationRow(member: member)
                    if member.id != model.members.last?.id {
                        Divider().overlay(Color.prv.separator.opacity(0.5))
                    }
                }
            }
            .prvGlassCard()
        }
    }

    // MARK: States

    private func failureState(_ message: String) -> some View {
        PRVEmptyState(
            systemImage: "person.2.slash",
            title: "Team unavailable",
            message: message,
            actionTitle: "Try Again"
        ) {
            reloadRoster()
        }
        .padding(.top, PRVSpacing.xxl)
    }

    // MARK: Actions

    /// The salon in scope, falling back to the flagship fixture so previews and
    /// demo mode always have a studio to operate.
    private var salonID: Salon.ID {
        session.activeSalonID ?? PreviewData.salonLumiere.id
    }

    private var canManageTeam: Bool { session.can(.manageTeam) }

    /// Cross-feature navigation to a team member's public profile. Routed
    /// through the shared `AppRouter` — the hub never imports another feature.
    private func openProfile(for member: TeamMember) -> (() -> Void)? {
        guard let professional = member.professional else { return nil }
        return { router.push(.professional(professional.id)) }
    }

    private var rosterIdentity: String { salonID.description }

    private var scheduleIdentity: String {
        "\(salonID.description)-\(model.weekStart.timeIntervalSince1970)"
    }

    private func loadRoster() async {
        await model.load(
            salonID: salonID,
            userID: session.currentUser?.id,
            canViewPayroll: session.can(.managePayroll),
            using: deps
        )
    }

    private func loadSchedule() async {
        await model.loadSchedule(salonID: salonID, using: deps)
    }

    private func refreshAll() async {
        await loadRoster()
        await loadSchedule()
    }

    private func reloadRoster() {
        PRVHaptics.tap()
        Task { await loadRoster() }
    }

    private func reloadSchedule() {
        PRVHaptics.tap()
        Task { await loadSchedule() }
    }
}

// MARK: - Previews

#Preview("Studio — Owner") {
    NavigationStack {
        TeamView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .operations))
}

#Preview("Studio — Dark") {
    NavigationStack {
        TeamView()
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .operations))
    .preferredColorScheme(.dark)
}

#Preview("Team desk — Employee") {
    NavigationStack {
        TeamDeskView()
            .navigationTitle("Team")
    }
    .environment(UserSession.previewSalonEmployee)
    .environment(AppRouter(selectedTab: .operations))
}
