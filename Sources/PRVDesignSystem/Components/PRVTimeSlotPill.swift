import SwiftUI

/// A tappable time-slot pill for booking flows. Selected slots fill with
/// the brand gradient; unavailable slots are dimmed and non-interactive.
/// Lay slots out with ``PRVFlowLayout`` or a grid.
///
/// ```swift
/// PRVTimeSlotPill(
///     time: slot.start,
///     isSelected: model.selectedSlot == slot,
///     isAvailable: slot.isAvailable
/// ) {
///     model.selectedSlot = slot
/// }
/// ```
public struct PRVTimeSlotPill: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let label: String
    private let isSelected: Bool
    private let isAvailable: Bool
    private let action: () -> Void

    /// Creates a slot pill from a `Date`, formatted as a localized short time.
    /// - Parameters:
    ///   - time: The slot's start time.
    ///   - isSelected: Whether this slot is the current choice.
    ///   - isAvailable: Whether the slot can be booked. Defaults to `true`.
    ///   - action: Called on tap (after a light haptic).
    public init(
        time: Date,
        isSelected: Bool = false,
        isAvailable: Bool = true,
        action: @escaping () -> Void
    ) {
        self.init(
            label: time.formatted(date: .omitted, time: .shortened),
            isSelected: isSelected,
            isAvailable: isAvailable,
            action: action
        )
    }

    /// Creates a slot pill from a pre-formatted label, e.g. `"9:30 AM"`.
    public init(
        label: String,
        isSelected: Bool = false,
        isAvailable: Bool = true,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.isSelected = isSelected
        self.isAvailable = isAvailable
        self.action = action
    }

    public var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .strikethrough(!isAvailable)
                .foregroundStyle(foreground)
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
                        Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
        .prvAnimation(PRVMotion.quick, value: isSelected)
        .accessibilityLabel(label)
        .accessibilityHint(isAvailable ? "" : "Unavailable")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var foreground: Color {
        if isSelected { return Color.prv.textOnAccent }
        return isAvailable ? Color.prv.textPrimary : Color.prv.textSecondary
    }
}

#Preview("Time Slot — Light") {
    @Previewable @State var selected = "10:30"
    PRVFlowLayout(spacing: PRVSpacing.xs) {
        ForEach(["9:00", "9:30", "10:00", "10:30", "11:00", "11:30", "12:00", "14:00"], id: \.self) { slot in
            PRVTimeSlotPill(
                label: slot,
                isSelected: selected == slot,
                isAvailable: slot != "11:00"
            ) {
                selected = slot
            }
        }
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Time Slot — Dark") {
    HStack(spacing: PRVSpacing.xs) {
        PRVTimeSlotPill(time: .now, isSelected: true) {}
        PRVTimeSlotPill(time: .now.addingTimeInterval(1_800)) {}
        PRVTimeSlotPill(time: .now.addingTimeInterval(3_600), isAvailable: false) {}
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
