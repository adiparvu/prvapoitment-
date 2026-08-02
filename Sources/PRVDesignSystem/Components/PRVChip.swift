import SwiftUI

/// A selectable filter chip on Liquid Glass. Unselected chips are glass
/// capsules; selecting one fills it with the brand gradient. Used for
/// category filters, service filters, and quick toggles.
///
/// ```swift
/// PRVChip("Balayage", systemImage: "paintbrush", isSelected: filter == .balayage) {
///     filter = .balayage
/// }
/// ```
public struct PRVChip: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let title: String
    private let systemImage: String?
    private let isSelected: Bool
    private let action: () -> Void

    /// Creates a filter chip.
    /// - Parameters:
    ///   - title: The chip label.
    ///   - systemImage: Optional SF Symbol shown before the label.
    ///   - isSelected: Whether the chip is currently active.
    ///   - action: Called on tap (after a light haptic).
    public init(
        _ title: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button {
            PRVHaptics.tap()
            action()
        } label: {
            HStack(spacing: PRVSpacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.prv.textOnAccent : Color.prv.textPrimary)
            .padding(.vertical, PRVSpacing.xs)
            .padding(.horizontal, PRVSpacing.sm)
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
        .prvAnimation(PRVMotion.quick, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("Chip — Light") {
    @Previewable @State var selected = "Hair"
    PRVFlowLayout(spacing: PRVSpacing.xs) {
        ForEach(["Hair", "Nails", "Makeup", "Lashes", "Barber", "Spa"], id: \.self) { category in
            PRVChip(
                category,
                systemImage: category == "Hair" ? "scissors" : nil,
                isSelected: selected == category
            ) {
                selected = category
            }
        }
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Chip — Dark") {
    @Previewable @State var selected = "Nails"
    PRVFlowLayout(spacing: PRVSpacing.xs) {
        ForEach(["Hair", "Nails", "Makeup", "Lashes", "Barber", "Spa"], id: \.self) { category in
            PRVChip(category, isSelected: selected == category) {
                selected = category
            }
        }
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
