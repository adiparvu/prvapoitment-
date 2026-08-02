import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels

/// Step 3 — the day and time. A date strip drives availability, slots are
/// grouped by part of day with a recommended row on top, and the visit can be
/// turned into a recurring ritual or a group booking right here.
struct TimeSelectionStepView: View {
    let model: BookingFlowModel
    /// Re-runs the availability query (retry after a failure).
    let reloadSlots: () -> Void

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                PRVSectionHeader(
                    "Pick a day",
                    subtitle: model.selectedProfessional.map { "With \($0.displayName)" } ?? "With any available artist"
                )
                .padding(.horizontal, PRVSpacing.xxs)

                PRVDateStrip(selection: $model.selectedDay, days: 30)
                    .padding(.horizontal, -PRVSpacing.md)
            }

            SlotBoardView(
                phase: model.slotsPhase,
                recommended: model.recommendedSlots,
                selectedSlot: model.selectedSlot,
                onSelect: { model.select($0) },
                onRetry: reloadSlots,
                onJoinWaitlist: { model.isWaitlistPresented = true }
            )

            recurrenceCard
            groupCard
        }
        .prvAnimation(PRVMotion.gentle, value: model.slotsPhase)
    }

    // MARK: - Recurrence

    private var recurrenceCard: some View {
        @Bindable var model = model

        return PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                BookingToggleRow(
                    title: "Make it a ritual",
                    subtitle: "Repeat this visit automatically at your cadence.",
                    systemImage: "repeat",
                    isOn: $model.isRecurring
                )

                if model.isRecurring {
                    Divider()

                    PRVFlowLayout(spacing: PRVSpacing.xs) {
                        ForEach(RecurrenceRule.Frequency.allCases, id: \.self) { frequency in
                            PRVChip(
                                BookingFormatting.frequency(frequency),
                                isSelected: model.recurrenceFrequency == frequency
                            ) {
                                model.recurrenceFrequency = frequency
                            }
                        }
                    }

                    Toggle("Until I cancel", isOn: $model.isRecurrenceOngoing)
                        .font(.subheadline.weight(.medium))
                        .tint(Color.prv.accent)
                        .accessibilityHint("Keeps repeating with no end date")

                    if !model.isRecurrenceOngoing {
                        HStack(spacing: PRVSpacing.sm) {
                            Text("Number of visits")
                                .prvStyle(.subheadline)
                            Spacer(minLength: PRVSpacing.xs)
                            PRVQuantityStepper(
                                value: $model.recurrenceOccurrences,
                                in: 2...24,
                                label: "Number of visits"
                            )
                        }
                    }
                }
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.isRecurring)
        .prvAnimation(PRVMotion.quick, value: model.isRecurrenceOngoing)
    }

    // MARK: - Group booking

    private var groupCard: some View {
        @Bindable var model = model

        return PRVGlassCard {
            VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                BookingToggleRow(
                    title: "Book for a group",
                    subtitle: "Reserve seats for friends joining you at the same time.",
                    systemImage: "person.2.fill",
                    isOn: $model.isGroupBooking
                )

                if model.isGroupBooking {
                    Divider()

                    HStack(spacing: PRVSpacing.sm) {
                        Text("Guests joining you")
                            .prvStyle(.subheadline)
                        Spacer(minLength: PRVSpacing.xs)
                        PRVQuantityStepper(value: $model.guestCount, in: 1...7, label: "Guests")
                    }

                    Text("Each guest gets their own invitation to confirm their treatment.")
                        .prvStyle(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .prvAnimation(PRVMotion.spring, value: model.isGroupBooking)
    }
}
