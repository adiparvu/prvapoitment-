import SwiftUI
import PRVDesignSystem
import PRVModels

/// The availability board for one day: an optional "Recommended" row driven
/// by each slot's optimization score, then every bookable time grouped
/// Morning / Afternoon / Evening.
///
/// It is deliberately state-free so both the booking flow's time step and the
/// reschedule sheet render availability identically.
struct SlotBoardView: View {
    /// Current availability query state.
    let phase: SlotsPhase
    /// Top-scoring slots for the "Recommended" row (empty hides the row).
    var recommended: [TimeSlot] = []
    /// The currently chosen slot, if any.
    let selectedSlot: TimeSlot?
    /// Called when the client taps a slot.
    let onSelect: (TimeSlot) -> Void
    /// Called when the client retries after a failure.
    let onRetry: () -> Void
    /// When provided, the empty state offers the waitlist.
    var onJoinWaitlist: (() -> Void)? = nil

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading:
            loadingBoard
        case .failed(let message):
            BookingErrorCard(message: message, retry: onRetry)
        case .loaded(let slots):
            if slots.isEmpty {
                emptyBoard
            } else {
                board(sections: slots.groupedByPeriod())
            }
        }
    }

    // MARK: - Loaded

    private func board(sections: [SlotSection]) -> some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            if !recommended.isEmpty {
                recommendedSection
            }

            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    HStack(spacing: PRVSpacing.xs) {
                        Image(systemName: section.period.symbolName)
                            .font(.footnote)
                            .foregroundStyle(Color.prv.accent)
                            .accessibilityHidden(true)
                        Text(section.period.title)
                            .prvStyle(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: PRVSpacing.xs)
                        Text(section.slots.count == 1 ? "1 time" : "\(section.slots.count) times")
                            .prvStyle(.caption)
                    }

                    PRVFlowLayout(spacing: PRVSpacing.xs) {
                        ForEach(section.slots) { slot in
                            PRVTimeSlotPill(
                                time: slot.start,
                                isSelected: selectedSlot == slot
                            ) {
                                onSelect(slot)
                            }
                        }
                    }
                }
            }
        }
        .prvAnimation(PRVMotion.spring, value: selectedSlot)
    }

    /// The sparkle row: the three slots that fit the salon's day best.
    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.sm) {
            HStack(spacing: PRVSpacing.xs) {
                Image(systemName: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(Color.prv.gold)
                    .accessibilityHidden(true)
                Text("Recommended")
                    .prvStyle(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: PRVSpacing.xs)
                Text("Best fit for the salon's day")
                    .prvStyle(.caption)
                    .lineLimit(1)
            }

            ScrollView(.horizontal) {
                HStack(spacing: PRVSpacing.xs) {
                    ForEach(recommended) { slot in
                        RecommendedSlotPill(
                            slot: slot,
                            isSelected: selectedSlot == slot
                        ) {
                            onSelect(slot)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Loading & empty

    private var loadingBoard: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.lg) {
            ForEach(0..<2, id: \.self) { section in
                VStack(alignment: .leading, spacing: PRVSpacing.sm) {
                    PRVSkeleton(width: 120, height: 18)
                    PRVFlowLayout(spacing: PRVSpacing.xs) {
                        ForEach(0..<(section == 0 ? 6 : 4), id: \.self) { _ in
                            PRVSkeleton(width: 84, height: 34, radius: 17)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading available times")
    }

    @ViewBuilder
    private var emptyBoard: some View {
        if let onJoinWaitlist {
            WaitlistPromptCard(action: onJoinWaitlist)
        } else {
            PRVEmptyState(
                systemImage: "calendar.badge.exclamationmark",
                title: "Fully booked",
                message: "There's nothing left on this day. Try another date."
            )
        }
    }
}

/// A gold-accented slot pill for the "Recommended" row, marked with a sparkle
/// so it reads as a suggestion rather than just another time.
struct RecommendedSlotPill: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let slot: TimeSlot
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            HStack(spacing: PRVSpacing.xxs) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.prv.textOnAccent : Color.prv.gold)
                Text(BookingFormatting.time(slot.start))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.prv.textOnAccent : Color.prv.textPrimary)
            }
            .padding(.vertical, PRVSpacing.xs)
            .padding(.horizontal, PRVSpacing.md)
            .background {
                if isSelected {
                    Capsule().fill(Color.prv.accentGradient)
                } else if reduceTransparency {
                    Capsule().fill(Color.prv.surface)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(Color.prv.gold.opacity(0.55), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .prvAnimation(PRVMotion.quick, value: isSelected)
        .accessibilityLabel("Recommended, \(BookingFormatting.time(slot.start))")
        .accessibilityHint("Fits the salon's schedule best")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Shown when a day has no bookable times: the elegant way out is the
/// waitlist rather than a dead end.
struct WaitlistPromptCard: View {
    let action: () -> Void

    var body: some View {
        PRVGlassCard(radius: PRVRadius.xl, padding: PRVSpacing.lg) {
            VStack(spacing: PRVSpacing.sm) {
                Image(systemName: "hourglass.bottomhalf.filled")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.prv.accentGradient)
                    .accessibilityHidden(true)

                Text("Fully booked this day")
                    .prvStyle(.title2)
                    .multilineTextAlignment(.center)

                Text("Join the waitlist and we'll notify you the moment a spot in your window opens up.")
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Join the Waitlist") {
                    PRVHaptics.impact()
                    action()
                }
                .buttonStyle(.prvPrimary)
                .padding(.top, PRVSpacing.xxs)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
