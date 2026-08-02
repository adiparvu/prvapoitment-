import SwiftUI

/// A glass quantity stepper (− value +) used for add-ons, group-booking
/// party size, and inventory adjustments. Values are clamped to `range`;
/// buttons disable at the bounds. VoiceOver users adjust with swipe
/// up/down on the single combined element.
///
/// ```swift
/// PRVQuantityStepper(value: $guests, in: 1...8)
/// ```
public struct PRVQuantityStepper: View {
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let label: String

    /// Creates a quantity stepper.
    /// - Parameters:
    ///   - value: Bound quantity, clamped to `range`.
    ///   - range: Allowed values. Defaults to `1...99`.
    ///   - label: VoiceOver name for the control. Defaults to "Quantity".
    public init(
        value: Binding<Int>,
        in range: ClosedRange<Int> = 1...99,
        label: String = "Quantity"
    ) {
        self._value = value
        self.range = range
        self.label = label
    }

    public var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            stepButton(systemImage: "minus", enabled: value > range.lowerBound) {
                adjust(by: -1)
            }

            Text("\(value)")
                .font(.headline)
                .foregroundStyle(Color.prv.textPrimary)
                .monospacedDigit()
                .frame(minWidth: 32)
                .contentTransition(.numericText())
                .prvAnimation(PRVMotion.quick, value: value)

            stepButton(systemImage: "plus", enabled: value < range.upperBound) {
                adjust(by: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: 1)
            case .decrement: adjust(by: -1)
            @unknown default: break
            }
        }
    }

    private func stepButton(
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.prv.textPrimary)
                .frame(width: 32, height: 32)
                .prvGlassEffect(interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func adjust(by delta: Int) {
        let newValue = min(max(value + delta, range.lowerBound), range.upperBound)
        guard newValue != value else { return }
        PRVHaptics.impact()
        value = newValue
    }
}

#Preview("Quantity Stepper — Light") {
    @Previewable @State var quantity = 2
    @Previewable @State var guests = 8
    VStack(spacing: PRVSpacing.lg) {
        PRVQuantityStepper(value: $quantity)
        PRVQuantityStepper(value: $guests, in: 1...8, label: "Guests")   // at upper bound
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Quantity Stepper — Dark") {
    @Previewable @State var quantity = 1
    PRVQuantityStepper(value: $quantity)
        .padding(PRVSpacing.lg)
        .background(Color.prv.canvas)
        .preferredColorScheme(.dark)
}
