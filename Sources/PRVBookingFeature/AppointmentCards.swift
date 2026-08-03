import SwiftUI
import PRVDesignSystem
import PRVModels

/// Visual mapping for appointment statuses, so badges read consistently
/// wherever an appointment appears.
enum AppointmentStatusStyle {
    /// Badge tint for a status.
    static func tint(_ status: AppointmentStatus) -> Color {
        switch status {
        case .pendingConfirmation: Color.prv.warning
        case .confirmed: Color.prv.success
        case .checkedIn, .inProgress: Color.prv.accent
        case .completed: Color.prv.textSecondary
        case .cancelledByClient, .cancelledBySalon, .noShow: Color.prv.danger
        }
    }
}

/// A compact glass action used on appointment cards — icon above a short
/// label, so three actions fit comfortably at any Dynamic Type size.
struct AppointmentActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = Color.prv.textPrimary
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            VStack(spacing: PRVSpacing.xxs) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, PRVSpacing.xs)
            .prvGlassEffect(interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(title)
    }
}

/// An upcoming visit: live countdown, status, what and with whom, and the
/// three things clients actually do — move it, cancel it, or ask a question.
struct UpcomingAppointmentCard: View {
    @Environment(\.appearsActive) private var appearsActive

    let appointment: Appointment
    let salon: Salon?
    let isBusy: Bool
    let onOpen: () -> Void
    let onReschedule: () -> Void
    let onCancel: () -> Void
    let onMessage: () -> Void

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                        header
                        details
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Opens the appointment")

                Divider()

                HStack(spacing: PRVSpacing.xs) {
                    AppointmentActionButton(
                        title: "Reschedule",
                        systemImage: "calendar.badge.clock",
                        isBusy: isBusy,
                        action: onReschedule
                    )
                    AppointmentActionButton(
                        title: "Cancel",
                        systemImage: "xmark.circle",
                        tint: Color.prv.danger,
                        action: onCancel
                    )
                    AppointmentActionButton(
                        title: "Message",
                        systemImage: "bubble.left.and.text.bubble.right",
                        action: onMessage
                    )
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appointment.salonName)
                    .prvStyle(.headline)
                if let address = salon?.address.oneLine {
                    Text(address)
                        .prvStyle(.caption)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: PRVSpacing.xs)

            PRVBadge(
                appointment.status.displayName,
                tint: AppointmentStatusStyle.tint(appointment.status)
            )
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            if let start = appointment.start {
                HStack(spacing: PRVSpacing.xs) {
                    Image(systemName: "calendar")
                        .font(.footnote)
                        .foregroundStyle(Color.prv.accent)
                        .accessibilityHidden(true)
                    Text(BookingFormatting.dateAndTime(start))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)

                    Spacer(minLength: PRVSpacing.xs)

                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if let countdown = BookingFormatting.countdown(to: start, from: context.date) {
                            Text(countdown)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.prv.accent)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    // The countdown is the only thing on the card that keeps
                    // moving, so it recedes while its window is inactive (iPad
                    // multi-window and Stage Manager) — two PRV windows side by
                    // side then tick in one place instead of competing. The
                    // card's accessibility label still reads the countdown, so
                    // VoiceOver is unaffected.
                    .opacity(appearsActive ? 1 : 0.7)
                    .prvAnimation(PRVMotion.gentle, value: appearsActive)
                }
            }

            Text(appointment.items.map(\.serviceName).joined(separator: " + "))
                .prvStyle(.subheadline)
                .lineLimit(2)

            HStack(spacing: PRVSpacing.sm) {
                if let professional = appointment.items.first?.professionalName {
                    Label(professional, systemImage: "person.crop.circle")
                        .prvStyle(.caption)
                }
                if appointment.isGroupBooking {
                    Label(
                        "Group of \(appointment.additionalClientIDs.count + 1)",
                        systemImage: "person.2.fill"
                    )
                    .prvStyle(.caption)
                }
                if let rule = appointment.recurrence {
                    Label(BookingFormatting.recurrence(rule), systemImage: "repeat")
                        .prvStyle(.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                PRVPriceLabel(appointment.totalPrice.formatted)
            }
        }
    }

    private var accessibilityLabel: String {
        var label = "\(appointment.salonName), \(appointment.status.displayName)"
        if let start = appointment.start {
            label += ", \(BookingFormatting.dateAndTime(start))"
            if let countdown = BookingFormatting.countdown(to: start) {
                label += ", \(countdown)"
            }
        }
        label += ", \(appointment.items.map(\.serviceName).joined(separator: ", "))"
        return label
    }
}

/// A past visit: what happened, what it cost, and the three follow-ups —
/// book it again, review it, or pull the invoice.
struct PastAppointmentCard: View {
    let appointment: Appointment
    let invoice: Invoice?
    let hasOrder: Bool
    let onRebook: () -> Void
    let onReview: () -> Void
    let onInvoice: () -> Void

    var body: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack(alignment: .top, spacing: PRVSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appointment.salonName)
                            .prvStyle(.headline)
                        if let start = appointment.start {
                            Text("\(BookingFormatting.shortDay(start)) · \(BookingFormatting.relative(start))")
                                .prvStyle(.caption)
                        }
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    PRVBadge(
                        appointment.status.displayName,
                        tint: AppointmentStatusStyle.tint(appointment.status)
                    )
                }

                HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                    Text(appointment.items.map(\.serviceName).joined(separator: " + "))
                        .prvStyle(.subheadline)
                        .lineLimit(2)
                    Spacer(minLength: PRVSpacing.xs)
                    PRVPriceLabel(appointment.totalPrice.formatted)
                }

                if appointment.status == .completed {
                    reviewPrompt
                }

                Divider()

                HStack(spacing: PRVSpacing.xs) {
                    AppointmentActionButton(
                        title: "Book Again",
                        systemImage: "arrow.clockwise",
                        tint: Color.prv.accent,
                        action: onRebook
                    )
                    AppointmentActionButton(
                        title: "Review",
                        systemImage: "star",
                        action: onReview
                    )
                    if hasOrder {
                        AppointmentActionButton(
                            title: invoice.map { "Invoice \($0.number)" } ?? "Invoice",
                            systemImage: "doc.text",
                            action: onInvoice
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A gentle nudge to review a completed visit.
    private var reviewPrompt: some View {
        Button(action: onReview) {
            HStack(spacing: PRVSpacing.xs) {
                Image(systemName: "star.bubble.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.prv.gold)
                    .accessibilityHidden(true)
                Text("How was it? Your review helps other clients.")
                    .prvStyle(.caption)
                Spacer(minLength: PRVSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(PRVSpacing.sm)
            .background(Color.prv.gold.opacity(0.12), in: PRVRadius.shape(PRVRadius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write a review for \(appointment.salonName)")
    }
}
