import SwiftUI
import PRVDesignSystem
import PRVModels

/// The final moment of the flow: an animated seal, the visit in full, and the
/// three things a client wants next — pay, save it to their calendar, share it.
struct BookingConfirmationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let confirmation: BookingConfirmation
    /// Opens checkout for the outstanding prepayment.
    let onPayNow: () -> Void
    /// Leaves the flow for the client's bookings list.
    let onDone: () -> Void
    /// Surfaces calendar feedback on the flow's single toast layer.
    let onMessage: (PRVToast) -> Void

    @State private var isSealed = false
    @State private var isAddingToCalendar = false

    var body: some View {
        VStack(spacing: PRVSpacing.lg) {
            seal
                .padding(.top, PRVSpacing.md)

            VStack(spacing: PRVSpacing.xs) {
                Text("You're booked")
                    .prvStyle(.largeTitle)
                    .multilineTextAlignment(.center)
                Text(confirmation.appointment.status == .confirmed
                     ? "\(confirmation.salon.name) has confirmed your visit."
                     : "\(confirmation.salon.name) will confirm your visit shortly.")
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("booking.confirmation")

            detailsCard
            actions
        }
        .frame(maxWidth: .infinity)
        .onAppear { isSealed = true }
    }

    // MARK: - Seal

    private var seal: some View {
        ZStack {
            Circle()
                .fill(Color.prv.accent.opacity(0.10))

            Circle()
                .strokeBorder(Color.prv.gold.opacity(0.35), lineWidth: 1)
                .padding(-PRVSpacing.xs)
                .scaleEffect(isSealed ? 1 : 0.85)
                .opacity(isSealed ? 1 : 0)

            Circle()
                .trim(from: 0, to: isSealed ? 1 : 0)
                .stroke(
                    Color.prv.accentGradient,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: "checkmark")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(Color.prv.accentGradient)
                .scaleEffect(isSealed ? 1 : 0.3)
                .opacity(isSealed ? 1 : 0)
        }
        .frame(width: 132, height: 132)
        .prvAnimation(reduceMotion ? PRVMotion.quick : PRVMotion.gentle, value: isSealed)
        .accessibilityHidden(true)
    }

    // MARK: - Details

    private var detailsCard: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                ForEach(confirmation.appointment.items) { item in
                    BookingSummaryRow(
                        label: item.serviceName,
                        value: item.price.formatted,
                        systemImage: "sparkles"
                    )
                }

                Divider()

                if let start = confirmation.start {
                    BookingSummaryRow(
                        label: "When",
                        value: BookingFormatting.dateAndTime(start),
                        systemImage: "calendar"
                    )
                }
                BookingSummaryRow(
                    label: "Artist",
                    value: confirmation.professionalName ?? "Any available",
                    systemImage: "person.crop.circle"
                )
                BookingSummaryRow(
                    label: "Where",
                    value: confirmation.salon.address.oneLine,
                    systemImage: "mappin.and.ellipse"
                )
                if let rule = confirmation.appointment.recurrence {
                    BookingSummaryRow(
                        label: "Repeats",
                        value: BookingFormatting.recurrence(rule),
                        systemImage: "repeat"
                    )
                }

                Divider()

                BookingSummaryRow(
                    label: "Total",
                    value: confirmation.order.total.formatted,
                    isProminent: true
                )
                BookingSummaryRow(
                    label: confirmation.amountDueNow.isZero ? "Due at the salon" : "Due now",
                    value: confirmation.amountDueNow.isZero
                        ? confirmation.order.total.formatted
                        : confirmation.amountDueNow.formatted,
                    systemImage: confirmation.amountDueNow.isZero ? "banknote" : "creditcard"
                )
                if confirmation.order.pointsEarned > 0 {
                    BookingSummaryRow(
                        label: "Reward points",
                        value: "+\(confirmation.order.pointsEarned)",
                        systemImage: "sparkle",
                        tint: Color.prv.gold
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: PRVSpacing.sm) {
            if !confirmation.amountDueNow.isZero {
                Button("Pay \(confirmation.amountDueNow.formatted)") {
                    PRVHaptics.impact()
                    onPayNow()
                }
                .buttonStyle(.prvPrimary)
                .accessibilityHint("Opens secure checkout")
            }

            HStack(spacing: PRVSpacing.sm) {
                Button {
                    Task { await addToCalendar() }
                } label: {
                    if isAddingToCalendar {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Add to Calendar", systemImage: "calendar.badge.plus")
                    }
                }
                .buttonStyle(.prvGlass)
                .disabled(isAddingToCalendar || confirmation.start == nil)
                .accessibilityLabel("Add to calendar")

                ShareLink(item: confirmation.shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.prvGlass)
                .accessibilityLabel("Share this booking")
            }

            Button("View my bookings") {
                PRVHaptics.tap()
                onDone()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.prv.accent)
            .padding(.top, PRVSpacing.xxs)
            .accessibilityIdentifier("booking.viewMyBookings")
        }
    }

    /// Saves the visit to the system calendar, reporting the outcome upward.
    private func addToCalendar() async {
        guard let start = confirmation.start else { return }
        let end = confirmation.end ?? start.addingTimeInterval(3_600)
        isAddingToCalendar = true
        defer { isAddingToCalendar = false }
        do {
            try await BookingCalendar.add(
                title: confirmation.calendarTitle,
                start: start,
                end: end,
                location: confirmation.salon.address.oneLine,
                notes: confirmation.appointment.clientNotes
            )
            PRVHaptics.success()
            onMessage(.success("Saved to your calendar"))
        } catch let error as BookingCalendarError {
            PRVHaptics.warning()
            onMessage(.warning(error.message))
        } catch {
            PRVHaptics.error()
            onMessage(.error("Couldn't add this to your calendar."))
        }
    }
}

// MARK: - Previews

/// A confirmation built from the preview fixtures.
private func makePreviewConfirmation() -> BookingConfirmation {
    BookingConfirmation(
        appointment: PreviewData.upcomingAppointment,
        order: Order(
            salonID: PreviewData.salonLumiere.id,
            clientID: PreviewData.client.id,
            appointmentID: PreviewData.upcomingAppointment.id,
            lines: [
                OrderLine(
                    kind: .service,
                    title: PreviewData.serviceBalayage.name,
                    unitPrice: PreviewData.serviceBalayage.price
                ),
            ],
            status: .awaitingPayment,
            pointsEarned: 370
        ),
        salon: PreviewData.salonLumiere,
        amountDueNow: Money(92.50),
        professionalName: PreviewData.stylistAmelie.displayName
    )
}

#Preview("Confirmation — Light") {
    ScrollView {
        BookingConfirmationView(
            confirmation: makePreviewConfirmation(),
            onPayNow: {},
            onDone: {},
            onMessage: { _ in }
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}

#Preview("Confirmation — Dark") {
    ScrollView {
        BookingConfirmationView(
            confirmation: makePreviewConfirmation(),
            onPayNow: {},
            onDone: {},
            onMessage: { _ in }
        )
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
