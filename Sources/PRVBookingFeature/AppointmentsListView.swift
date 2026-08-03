import SwiftUI
import PRVBookingKit
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
        // Bookings are glass cards in a `LazyVStack`, not list rows, so the
        // scroll view itself hosts swipe actions: every upcoming visit now
        // carries the same actions its buttons do, one gesture away, without
        // surrendering the card layout to a `List`.
        .swipeActionsContainer()
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Bookings")
        .refreshable { await refresh() }
        .task(id: session.currentUser?.id) { await refresh() }
        .sheet(item: $model.sheet) { route in
            sheet(for: route)
        }
        .confirmationDialog(
            "Cancel this appointment?",
            item: $model.appointmentPendingCancellation
        ) { appointment in
            cancellationActions(for: appointment)
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

    /// One row of the list. Built with `@ContentBuilder`: a switch over two
    /// cards that each take six closures, instantiated once per visit inside
    /// `ForEach`, makes this the screen's heaviest type-check site.
    @ContentBuilder
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                trailingActions(for: appointment)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                messageAction(for: appointment)
            }
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

    // MARK: - Swipe actions

    /// Reschedule and cancel, mirroring the card's own buttons for clients who
    /// reach for a swipe first. Full swipe stays off — neither moving nor
    /// cancelling a visit should fire from an overshoot — and while a mutation
    /// is in flight the row offers nothing, so a second request can never race
    /// the first.
    @ContentBuilder
    private func trailingActions(for appointment: Appointment) -> some View {
        if !model.isBusy(appointment) {
            Button(role: .destructive) {
                PRVHaptics.tap()
                model.appointmentPendingCancellation = appointment
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }

            Button {
                PRVHaptics.tap()
                model.sheet = AppointmentSheetRoute(kind: .reschedule, appointment: appointment)
            } label: {
                Label("Reschedule", systemImage: "calendar.badge.clock")
            }
            .tint(Color.prv.accent)
        }
    }

    /// Messaging the salon is the one row action that costs nothing to trigger,
    /// so it takes the leading edge and leaves the trailing edge to the two
    /// that change a booking.
    private func messageAction(for appointment: Appointment) -> some View {
        Button {
            PRVHaptics.tap()
            openConversation(for: appointment)
        } label: {
            Label("Message", systemImage: "bubble.left.and.text.bubble.right")
        }
        .tint(Color.prv.accent)
    }

    /// The swipe-to-cancel prompt. Its destructive button carries the exact
    /// fee — the same words the cancellation sheet's confirm button uses — so
    /// money is never hidden behind a gesture, and whenever there is a fee the
    /// full breakdown stays one tap away.
    @ContentBuilder
    private func cancellationActions(for appointment: Appointment) -> some View {
        let assessment = model.cancellationAssessment(for: appointment)
        let confirmTitle: String = assessment.isFree
            ? "Cancel Appointment"
            : "Cancel and Pay \(assessment.fee.formatted)"

        Button(confirmTitle, role: .destructive) {
            PRVHaptics.warning()
            Task { await model.cancel(appointment, reason: nil, using: deps) }
        }

        if !assessment.isFree {
            Button("Review Cancellation Terms…") {
                model.sheet = AppointmentSheetRoute(kind: .cancel, appointment: appointment)
            }
        }

        Button("Keep Appointment", role: .cancel) {}
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

    /// Built with `@ContentBuilder`: both branches are full sheets with their
    /// own trailing closures, so they type-check on their own rather than as
    /// one expression inside `.sheet(item:)`.
    @ContentBuilder
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
