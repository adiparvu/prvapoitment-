import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Shows exactly what cancelling costs before anything is cancelled: the
/// salon's window, the fee retained, and the refund returned — then asks for
/// a reason and makes keeping the appointment the easy choice.
struct CancellationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let appointment: Appointment
    let assessment: CancellationAssessment
    let policies: SalonPolicies
    /// Whether the cancellation request is in flight.
    let isCancelling: Bool
    /// Commits the cancellation. Returns `true` when it succeeded.
    let confirm: @MainActor (String?) async -> Bool

    @State private var reason: String?
    @State private var note = ""

    private static let reasons = [
        "Schedule conflict",
        "Feeling unwell",
        "Found a better time",
        "No longer needed",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PRVSpacing.lg) {
                    assessmentCard
                    breakdownCard
                    reasonCard
                }
                .padding(PRVSpacing.md)
                .padding(.bottom, PRVSpacing.xl)
            }
            .background(Color.prv.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("Cancel Appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PRVBottomBar {
                    VStack(spacing: PRVSpacing.sm) {
                        Button("Keep My Appointment") {
                            PRVHaptics.tap()
                            dismiss()
                        }
                        .buttonStyle(.prvPrimary)

                        Button {
                            commit()
                        } label: {
                            if isCancelling {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(assessment.isFree ? "Cancel Appointment" : "Cancel and Pay \(assessment.fee.formatted)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.prv.danger)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isCancelling)
                        .accessibilityLabel("Confirm cancellation")
                        .accessibilityHint(
                            assessment.isFree
                                ? "No fee applies"
                                : "A fee of \(assessment.fee.formatted) applies"
                        )
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Assessment

    private var assessmentCard: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                HStack(spacing: PRVSpacing.sm) {
                    Image(systemName: assessment.isFree ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(assessment.isFree ? Color.prv.success : Color.prv.warning)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(assessment.headline)
                            .prvStyle(.headline)
                        if let start = appointment.start {
                            Text(BookingFormatting.dateAndTime(start))
                                .prvStyle(.footnote)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Text(assessment.summary)
                    .prvStyle(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(BookingFormatting.cancellationPolicy(policies))
                    .prvStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var breakdownCard: some View {
        PRVGlassCard {
            VStack(spacing: PRVSpacing.xs) {
                BookingSummaryRow(label: "Appointment total", value: assessment.total.formatted)
                BookingSummaryRow(label: "Already paid", value: assessment.amountPaid.formatted)
                BookingSummaryRow(
                    label: "Cancellation fee",
                    value: assessment.fee.isZero ? "None" : "−\(assessment.fee.formatted)",
                    tint: assessment.fee.isZero ? nil : Color.prv.danger
                )
                Divider()
                BookingSummaryRow(
                    label: "Refunded to you",
                    value: assessment.refund.formatted,
                    isProminent: true,
                    tint: assessment.refund.isZero ? nil : Color.prv.success
                )
            }
        }
    }

    // MARK: - Reason

    private var reasonCard: some View {
        PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                Text("Why are you cancelling?")
                    .prvStyle(.headline)
                Text("Optional, but it helps your salon plan.")
                    .prvStyle(.caption)

                PRVFlowLayout(spacing: PRVSpacing.xs) {
                    ForEach(Self.reasons, id: \.self) { option in
                        PRVChip(option, isSelected: reason == option) {
                            reason = reason == option ? nil : option
                        }
                    }
                }

                TextField("Anything else?", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.sentences)
                    .padding(PRVSpacing.sm)
                    .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.sm))
                    .accessibilityLabel("Additional cancellation note")
            }
        }
        .prvAnimation(PRVMotion.quick, value: reason)
    }

    private func commit() {
        PRVHaptics.warning()
        let trimmedNote = note.trimmed
        let combined = [reason, trimmedNote.isBlank ? nil : trimmedNote]
            .compactMap { $0 }
            .joined(separator: " — ")
        Task {
            if await confirm(combined.isBlank ? nil : combined) {
                dismiss()
            }
        }
    }
}

// MARK: - Previews

/// Builds an assessment `hours` before the fixture appointment starts.
private func makePreviewAssessment(hoursBeforeStart: Int, paid: Money) -> CancellationAssessment {
    let appointment = PreviewData.upcomingAppointment
    let start = appointment.start ?? .now
    return CancellationAssessor.assess(
        appointment: appointment,
        policies: PreviewData.salonLumiere.policies,
        amountPaid: paid,
        now: start.addingTimeInterval(-Double(hoursBeforeStart) * 3_600)
    )
}

#Preview("Cancellation — Free") {
    CancellationSheet(
        appointment: PreviewData.upcomingAppointment,
        assessment: makePreviewAssessment(hoursBeforeStart: 72, paid: Money(92.50)),
        policies: PreviewData.salonLumiere.policies,
        isCancelling: false
    ) { _ in true }
}

#Preview("Cancellation — Late") {
    CancellationSheet(
        appointment: PreviewData.upcomingAppointment,
        assessment: makePreviewAssessment(hoursBeforeStart: 3, paid: Money(92.50)),
        policies: PreviewData.salonLumiere.policies,
        isCancelling: false
    ) { _ in true }
    .preferredColorScheme(.dark)
}
