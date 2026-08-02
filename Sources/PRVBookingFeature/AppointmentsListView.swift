import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// The client's bookings: upcoming visits with a live countdown and the
/// actions that matter (reschedule, cancel with a transparent fee
/// assessment, message the salon), and past visits ready to be rebooked,
/// reviewed, or invoiced.
///
/// ```swift
/// NavigationStack { AppointmentsListView() }
/// ```
public struct AppointmentsListView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    @State private var model = AppointmentsListModel()

    /// Creates the bookings list. Dependencies come from the environment.
    public init() {}

    public var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(spacing: PRVSpacing.md) {
                PRVSegmentedGlassControl(
                    selection: $model.scope,
                    options: AppointmentScope.allCases,
                    title: \.rawValue
                )
                .padding(.horizontal, PRVSpacing.md)

                content
                    .padding(.horizontal, PRVSpacing.md)
            }
            .padding(.top, PRVSpacing.xs)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Bookings")
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) { await refresh() }
        .sheet(item: $model.sheet) { route in
            sheet(for: route)
        }
        .prvToast($model.toast)
        .prvAnimation(PRVMotion.spring, value: model.scope)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: PRVSpacing.md) {
                ForEach(0..<3, id: \.self) { _ in
                    AppointmentCardSkeleton()
                }
            }
        case .failed(let message):
            BookingErrorCard(message: message) {
                Task { await refresh() }
            }
            .padding(.top, PRVSpacing.lg)
        case .loaded:
            if model.visibleAppointments.isEmpty {
                emptyState
                    .padding(.top, PRVSpacing.lg)
            } else {
                LazyVStack(spacing: PRVSpacing.md) {
                    ForEach(model.visibleAppointments) { appointment in
                        card(for: appointment)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func card(for appointment: Appointment) -> some View {
        switch model.scope {
        case .upcoming:
            UpcomingAppointmentCard(
                appointment: appointment,
                salon: model.salon(for: appointment),
                isBusy: model.isBusy(appointment),
                onOpen: { router.push(.appointment(appointment.id)) },
                onReschedule: {
                    model.sheet = AppointmentSheetRoute(kind: .reschedule, appointment: appointment)
                },
                onCancel: {
                    model.sheet = AppointmentSheetRoute(kind: .cancel, appointment: appointment)
                },
                onMessage: { openConversation(for: appointment) }
            )
        case .past:
            PastAppointmentCard(
                appointment: appointment,
                invoice: model.invoice(for: appointment),
                hasOrder: model.order(for: appointment) != nil,
                onRebook: {
                    router.push(.booking(
                        salonID: appointment.salonID,
                        serviceIDs: model.serviceIDs(of: appointment)
                    ))
                },
                onReview: { router.push(.reviews(salonID: appointment.salonID)) },
                onInvoice: { openInvoice(for: appointment) }
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.scope {
        case .upcoming:
            PRVEmptyState(
                systemImage: "calendar.badge.plus",
                title: "Nothing on the books",
                message: "When you book a treatment it shows up here, with reminders so you never miss it.",
                actionTitle: "Explore Salons"
            ) {
                router.selectedTab = .discover
            }
        case .past:
            PRVEmptyState(
                systemImage: "clock.arrow.circlepath",
                title: "No visits yet",
                message: "Your history lives here — rebook a favourite in one tap once you've been."
            )
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheet(for route: AppointmentSheetRoute) -> some View {
        switch route.kind {
        case .reschedule:
            RescheduleSheet(
                appointment: route.appointment,
                isSaving: model.isBusy(route.appointment)
            ) { slot in
                await model.reschedule(route.appointment, to: slot, using: deps)
            }
        case .cancel:
            CancellationSheet(
                appointment: route.appointment,
                assessment: model.cancellationAssessment(for: route.appointment),
                policies: model.salon(for: route.appointment)?.policies ?? SalonPolicies(),
                amountPaid: model.amountPaid(for: route.appointment),
                isCancelling: model.isBusy(route.appointment)
            ) { reason in
                await model.cancel(route.appointment, reason: reason, using: deps)
            }
        }
    }

    // MARK: - Actions

    private func refresh() async {
        await model.load(for: session.currentUser, using: deps)
    }

    /// Opens the client's thread with the salon, falling back to the Chat tab
    /// when no conversation exists yet.
    private func openConversation(for appointment: Appointment) {
        guard let user = session.currentUser else {
            model.toast = .warning("Sign in to message this salon.")
            return
        }
        Task {
            if let conversationID = await model.conversationID(
                withSalon: appointment.salonID,
                userID: user.id,
                using: deps
            ) {
                router.push(.conversation(conversationID))
            } else {
                model.toast = .info("Start a conversation with \(appointment.salonName) from the Chat tab.")
                router.selectedTab = .chat
            }
        }
    }

    /// Opens the invoice PDF when the salon issued one, otherwise the order.
    private func openInvoice(for appointment: Appointment) {
        if let url = model.invoice(for: appointment)?.pdfURL {
            openURL(url)
        } else if let order = model.order(for: appointment) {
            router.present(.checkout(order.id))
        } else {
            model.toast = .info("No invoice has been issued for this visit yet.")
        }
    }
}

/// Shimmering placeholder matching an appointment card's silhouette.
struct AppointmentCardSkeleton: View {
    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack {
                    PRVSkeleton(width: 150, height: 18)
                    Spacer()
                    PRVSkeleton(width: 70, height: 18, radius: 9)
                }
                PRVSkeleton(height: 14)
                PRVSkeleton(width: 200, height: 14)
                Divider()
                HStack(spacing: PRVSpacing.xs) {
                    PRVSkeleton(height: 40, radius: PRVRadius.sm)
                    PRVSkeleton(height: 40, radius: PRVRadius.sm)
                    PRVSkeleton(height: 40, radius: PRVRadius.sm)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Bookings — Client") {
    NavigationStack {
        AppointmentsListView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .appointments))
}

#Preview("Bookings — Empty") {
    NavigationStack {
        AppointmentsListView()
    }
    .environment(UserSession())
    .environment(AppRouter(selectedTab: .appointments))
}

#Preview("Bookings — Dark") {
    NavigationStack {
        AppointmentsListView()
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .appointments))
    .preferredColorScheme(.dark)
}
