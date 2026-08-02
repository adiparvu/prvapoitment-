import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

// MARK: - Status styling

/// Maps appointment statuses onto the semantic palette so the timeline, the
/// pills, and the quick actions all speak with one voice.
extension AppointmentStatus {
    /// Tint used for this status' pill and timeline dot.
    var dashboardTint: Color {
        switch self {
        case .pendingConfirmation: Color.prv.warning
        case .confirmed: Color.prv.accent
        case .checkedIn: Color.prv.gold
        case .inProgress: Color.prv.success
        case .completed: Color.prv.textSecondary
        case .cancelledByClient, .cancelledBySalon, .noShow: Color.prv.danger
        }
    }

    /// SF Symbol shown inside the pill.
    var dashboardSymbol: String {
        switch self {
        case .pendingConfirmation: "hourglass"
        case .confirmed: "checkmark.seal"
        case .checkedIn: "person.badge.clock"
        case .inProgress: "scissors"
        case .completed: "checkmark.circle.fill"
        case .cancelledByClient, .cancelledBySalon: "xmark.circle"
        case .noShow: "person.slash"
        }
    }
}

/// A compact status pill for an appointment.
struct AppointmentStatusPill: View {
    let status: AppointmentStatus

    var body: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: status.dashboardSymbol)
                .font(.caption2.weight(.bold))
            Text(status.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(status.dashboardTint)
        .padding(.vertical, PRVSpacing.xxs)
        .padding(.horizontal, PRVSpacing.xs)
        .background(status.dashboardTint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.displayName)")
    }
}

// MARK: - Timeline

/// Today's book as a vertical timeline with one-tap status progression.
///
/// Each row advances along the front-desk flow — confirm, check in, start,
/// complete — with a success haptic per step, plus a menu for the exceptions
/// (no-show, cancelled by the salon).
struct TodayTimeline: View {
    let appointments: [Appointment]
    let isUpdating: (Appointment.ID) -> Bool
    let advance: (Appointment, AppointmentStatus) -> Void
    let open: (Appointment) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(appointments.enumerated()), id: \.element.id) { index, appointment in
                AppointmentTimelineRow(
                    appointment: appointment,
                    isLast: index == appointments.count - 1,
                    isUpdating: isUpdating(appointment.id),
                    advance: { status in advance(appointment, status) },
                    open: { open(appointment) }
                )
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md)
    }
}

/// One appointment in the timeline: time rail, service summary, status pill,
/// and the quick action that moves it forward.
struct AppointmentTimelineRow: View {
    let appointment: Appointment
    let isLast: Bool
    let isUpdating: Bool
    let advance: (AppointmentStatus) -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            timeColumn
            rail
            details
        }
        .padding(.vertical, PRVSpacing.xs)
        .contentShape(Rectangle())
        .prvAnimation(PRVMotion.spring, value: appointment.status)
    }

    // MARK: Rail

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(appointment.start.map(DashboardFormat.time) ?? "--:--")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)
                .monospacedDigit()
            if let end = appointment.end {
                Text(DashboardFormat.time(end))
                    .prvStyle(.caption)
                    .monospacedDigit()
            }
        }
        .frame(width: 54, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(appointment.status.dashboardTint)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            if !isLast {
                Rectangle()
                    .fill(Color.prv.separator.opacity(0.5))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 10)
        .accessibilityHidden(true)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            Button(action: {
                PRVHaptics.tap()
                open()
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(serviceSummary)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let subtitle {
                        Text(subtitle)
                            .prvStyle(.footnote)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(serviceSummary), \(subtitle ?? "")")
            .accessibilityHint("Opens the appointment")

            HStack(spacing: PRVSpacing.xs) {
                AppointmentStatusPill(status: appointment.status)

                PRVPriceLabel(appointment.totalPrice.formatted)

                Spacer(minLength: PRVSpacing.xxs)

                actions
            }
        }
    }

    private var serviceSummary: String {
        let names = appointment.items.map(\.serviceName)
        guard let first = names.first else { return "Appointment" }
        return names.count > 1 ? "\(first) +\(names.count - 1)" : first
    }

    private var subtitle: String? {
        let professionals = appointment.items.compactMap(\.professionalName)
        let duration = appointment.items.reduce(0) { $0 + $1.durationMinutes }
        let durationLabel = "\(duration) min"
        guard let professional = professionals.first else { return durationLabel }
        return "\(professional) · \(durationLabel)"
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if isUpdating {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Updating status")
        } else {
            HStack(spacing: PRVSpacing.xxs) {
                if let next = SalonDashboardModel.nextStatus(after: appointment.status),
                   let title = SalonDashboardModel.actionTitle(for: appointment.status) {
                    Button {
                        PRVHaptics.impact()
                        advance(next)
                    } label: {
                        Text(title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.prv.textOnAccent)
                            .padding(.vertical, PRVSpacing.xxs + 2)
                            .padding(.horizontal, PRVSpacing.sm)
                            .background(Color.prv.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(serviceSummary)")
                }

                if appointment.status.isActive {
                    Menu {
                        Button("Mark as no-show", systemImage: "person.slash") {
                            PRVHaptics.warning()
                            advance(.noShow)
                        }
                        Button("Cancel appointment", systemImage: "xmark.circle", role: .destructive) {
                            PRVHaptics.warning()
                            advance(.cancelledBySalon)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.body)
                            .foregroundStyle(Color.prv.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More actions for \(serviceSummary)")
                }
            }
        }
    }
}
