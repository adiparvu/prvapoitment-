import SwiftUI
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// One booking, opened straight from its identifier — the destination behind
/// `AppRoute.appointment`, which widgets, Live Activities, push notifications,
/// and `prvbeauty://appointment/<uuid>` all point at.
///
/// It resolves the booking with `AppointmentRepository.appointment(id:)` so the
/// link lands on the visit it names instead of a generic list.
struct AppointmentDetailView: View {
    @Environment(\.prvDependencies) private var deps
    @Environment(UserSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var model: AppointmentDetailModel

    /// Creates the detail screen for one booking.
    /// - Parameter appointmentID: The booking to open.
    init(appointmentID: Appointment.ID) {
        _model = State(initialValue: AppointmentDetailModel(appointmentID: appointmentID))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PRVSpacing.md) {
                switch model.phase {
                case .loading:
                    skeleton
                case .failed(let message):
                    AppointmentErrorCard(message: message) {
                        Task { await refresh() }
                    }
                case .loaded:
                    if let appointment = model.appointment {
                        header(for: appointment)
                        services(for: appointment)
                        notes(for: appointment)
                        actions(for: appointment)
                    }
                }
            }
            .padding(.horizontal, PRVSpacing.md)
            .padding(.top, PRVSpacing.xs)
            .padding(.bottom, PRVSpacing.xxl)
        }
        .background(Color.prv.canvas)
        .scrollIndicators(.hidden)
        .navigationTitle("Booking")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .prvAnimation(PRVMotion.gentle, value: model.phase)
    }

    // MARK: - Header

    /// Who, when, and where it stands.
    private func header(for appointment: Appointment) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(alignment: .top, spacing: PRVSpacing.sm) {
                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    Text(appointment.salonName)
                        .prvStyle(.title2)
                    if let start = appointment.start {
                        Text(AppointmentFormat.day(start))
                            .prvStyle(.subheadline)
                    }
                }
                Spacer(minLength: 0)
                AppointmentStatusPill(status: appointment.status)
            }

            Label(AppointmentFormat.window(appointment), systemImage: "clock")
                .prvStyle(.callout)

            if let countdown = model.countdown {
                Label(countdown, systemImage: "hourglass")
                    .prvStyle(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Services

    /// Every treatment in the booking with its artist, length, and price.
    private func services(for appointment: Appointment) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSectionHeader("Treatments")

            ForEach(appointment.items) { item in
                VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                        Text(item.serviceName)
                            .prvStyle(.headline)
                        Spacer(minLength: 0)
                        Text(item.price.formatted)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.prv.textPrimary)
                            .monospacedDigit()
                    }

                    Text(itemDetail(for: item))
                        .prvStyle(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                if item.id != appointment.items.last?.id {
                    Divider()
                }
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("Total")
                    .prvStyle(.headline)
                Spacer(minLength: 0)
                PRVPriceLabel(appointment.totalPrice.formatted, emphasis: .prominent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.lg)
    }

    /// Time, length, and artist for one treatment.
    private func itemDetail(for item: AppointmentItem) -> String {
        let timing = "\(AppointmentFormat.time(item.start)) · \(AppointmentFormat.duration(item.durationMinutes))"
        guard let professional = item.professionalName else { return timing }
        return "\(timing) · with \(professional)"
    }

    // MARK: - Notes

    /// The client's request always shows; salon-only notes stay behind the
    /// `viewClients` permission.
    @ViewBuilder
    private func notes(for appointment: Appointment) -> some View {
        let internalNotes = session.can(.viewClients) ? appointment.internalNotes : nil

        if appointment.clientNotes?.isBlank == false || internalNotes?.isBlank == false {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                PRVSectionHeader("Notes")

                if let clientNotes = appointment.clientNotes, !clientNotes.isBlank {
                    noteBlock(title: "From the client", text: clientNotes)
                }

                if let internalNotes, !internalNotes.isBlank {
                    noteBlock(title: "Salon only", text: internalNotes)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.lg)
        }
    }

    private func noteBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            Text(title)
                .prvStyle(.caption)
            Text(text)
                .prvStyle(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    /// Everything else lives behind an existing route, so the detail screen
    /// only has to hand off.
    private func actions(for appointment: Appointment) -> some View {
        VStack(spacing: PRVSpacing.sm) {
            Button("View Salon") {
                PRVHaptics.tap()
                router.push(.salon(appointment.salonID))
            }
            .buttonStyle(.prvGlass)
            .accessibilityHint("Opens \(appointment.salonName)")

            if let orderID = appointment.orderID {
                Button("View Payment") {
                    PRVHaptics.tap()
                    router.present(.checkout(orderID))
                }
                .buttonStyle(.prvGlass)
                .accessibilityHint("Opens the order for this booking")
            }
        }
    }

    // MARK: - Loading

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            PRVSkeleton(width: 200, height: 24)
            PRVSkeleton(width: 150, height: 16)
            PRVSkeleton(height: 14)
            PRVSkeleton(height: 14)
        }
        .prvGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg)
        .accessibilityHidden(true)
    }

    private func refresh() async {
        await model.load(using: deps)
    }
}

// MARK: - Model

/// Screen model behind ``AppointmentDetailView``: resolves one booking by
/// identifier so a deep link can land on it directly.
@Observable
@MainActor
final class AppointmentDetailModel {
    /// Lifecycle of the booking's load.
    enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    /// The booking being shown.
    let appointmentID: Appointment.ID

    private(set) var phase: Phase = .loading
    private(set) var appointment: Appointment?

    /// Creates the model for one booking.
    init(appointmentID: Appointment.ID) {
        self.appointmentID = appointmentID
    }

    /// A human countdown to the visit, e.g. `"in 3 days"`. `nil` once it has
    /// started or passed.
    var countdown: String? {
        guard let start = appointment?.start, appointment?.status.isActive == true else { return nil }
        let seconds = start.timeIntervalSinceNow
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Starting now" }
        if minutes < 60 { return "In \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "In \(hours) h" : "In \(hours) h \(remainder) min"
        }
        let days = hours / 24
        return days == 1 ? "Tomorrow" : "In \(days) days"
    }

    /// Loads (or refreshes) the booking. Safe to call again to retry.
    /// - Parameter deps: Repository container from the environment.
    func load(using deps: PRVDependencies) async {
        if appointment == nil { phase = .loading }

        do {
            appointment = try await deps.appointments.appointment(id: appointmentID)
            phase = .loaded
        } catch {
            phase = .failed(AppointmentFormat.friendlyMessage(for: error))
        }
    }
}

// MARK: - Previews

#Preview("Booking — Client") {
    NavigationStack {
        AppointmentDetailView(appointmentID: PreviewData.upcomingAppointment.id)
    }
    .environment(UserSession.previewClient)
    .environment(AppRouter(selectedTab: .appointments))
}

#Preview("Booking — Salon") {
    NavigationStack {
        AppointmentDetailView(appointmentID: PreviewData.upcomingAppointment.id)
    }
    .environment(UserSession.previewOwner)
    .environment(AppRouter(selectedTab: .calendar))
    .preferredColorScheme(.dark)
}
