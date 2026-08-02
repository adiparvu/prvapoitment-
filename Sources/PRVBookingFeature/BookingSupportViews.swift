import SwiftUI
import PRVDesignSystem
import PRVModels

/// The stepped progress indicator at the top of ``BookingFlowView``: four
/// glass segments that fill with the brand gradient as the client advances.
/// Completed steps are tappable so clients can go back and edit.
struct BookingProgressBar: View {
    let step: BookingStep
    let furthestStep: BookingStep
    let onSelect: (BookingStep) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            HStack(spacing: PRVSpacing.xxs) {
                ForEach(BookingStep.progressSteps, id: \.self) { segment in
                    segmentView(segment)
                }
            }

            HStack(spacing: PRVSpacing.xs) {
                Text(step == .confirmation ? "Confirmed" : "Step \(step.rawValue + 1) of \(BookingStep.progressSteps.count)")
                    .prvStyle(.caption)
                Text("·")
                    .prvStyle(.caption)
                Text(step.shortTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
        }
        .prvAnimation(PRVMotion.morph, value: step)
    }

    private func segmentView(_ segment: BookingStep) -> some View {
        let isReached = segment <= step || step == .confirmation
        let isEditable = segment <= furthestStep && step != .confirmation

        return Button {
            onSelect(segment)
        } label: {
            Capsule()
                .fill(Color.prv.textPrimary.opacity(0.10))
                .frame(height: 5)
                .overlay(alignment: .leading) {
                    if isReached {
                        Capsule().fill(Color.prv.accentGradient)
                    }
                }
                .clipShape(Capsule())
                .contentShape(Rectangle().inset(by: -PRVSpacing.xs))
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .accessibilityLabel(segment.shortTitle)
        .accessibilityValue(isReached ? "Completed" : "Not started")
        .accessibilityHint(isEditable ? "Double tap to edit this step" : "")
        .accessibilityAddTraits(segment == step ? [.isSelected] : [])
    }
}

/// An inline failure card with a retry action, used wherever a section can
/// fail on its own without taking the screen down.
struct BookingErrorCard: View {
    let message: String
    var retryTitle: String = "Try Again"
    let retry: () -> Void

    var body: some View {
        PRVGlassCard {
            VStack(spacing: PRVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.prv.warning)
                    .accessibilityHidden(true)

                Text(message)
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)

                Button(retryTitle) {
                    PRVHaptics.tap()
                    retry()
                }
                .buttonStyle(.prvGlass)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A large, tappable Liquid Glass card used for the flow's exclusive choices
/// (professional, prepayment level). Selection is drawn as a gradient border
/// plus a filled checkmark so it reads without relying on color alone.
struct BookingChoiceCard<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let isSelected: Bool
    private let isEnabled: Bool
    private let action: () -> Void
    private let content: Content

    /// Creates a selectable glass card.
    /// - Parameters:
    ///   - isSelected: Whether this card is the current choice.
    ///   - isEnabled: Whether the card can be chosen. Defaults to `true`.
    ///   - action: Called on tap.
    ///   - content: The card's contents.
    init(
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PRVSpacing.md)
                .background {
                    if reduceTransparency {
                        PRVRadius.shape(PRVRadius.lg).fill(Color.prv.surface)
                    } else {
                        PRVRadius.shape(PRVRadius.lg).fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    PRVRadius.shape(PRVRadius.lg)
                        .strokeBorder(
                            isSelected ? AnyShapeStyle(Color.prv.accentGradient) : AnyShapeStyle(Color.white.opacity(0.12)),
                            lineWidth: isSelected ? 1.6 : 0.5
                        )
                }
                .clipShape(PRVRadius.shape(PRVRadius.lg))
                .prvSoftShadow()
                .contentShape(PRVRadius.shape(PRVRadius.lg))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .prvAnimation(PRVMotion.spring, value: isSelected)
    }
}

/// The trailing selection mark of a ``BookingChoiceCard``.
struct BookingSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.prv.accent : Color.prv.textSecondary.opacity(0.4))
            .symbolEffect(.bounce, value: isSelected)
            .accessibilityHidden(true)
    }
}

/// A label/value line used by the review summary and the cancellation sheet.
struct BookingSummaryRow: View {
    let label: String
    let value: String
    var systemImage: String? = nil
    var isProminent = false
    var tint: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(tint ?? Color.prv.accent)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Text(label)
                .prvStyle(isProminent ? .headline : .subheadline)
            Spacer(minLength: PRVSpacing.xs)
            Text(value)
                .font(isProminent ? .headline : .subheadline.weight(.medium))
                .foregroundStyle(tint ?? Color.prv.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// A compact glass toggle row with a title, explanation, and trailing switch.
struct BookingToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: PRVSpacing.sm) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.accent)
                    .frame(width: 36, height: 36)
                    .background(Color.prv.accent.opacity(0.12), in: PRVRadius.shape(PRVRadius.sm))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.prv.textPrimary)
                    Text(subtitle)
                        .prvStyle(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Color.prv.accent)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
