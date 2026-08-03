import SwiftUI

/// A Liquid Glass segmented control: options sit in a glass capsule and the
/// selected segment is highlighted by a gradient pill that glides between
/// segments. Generic over any `Hashable` option type.
///
/// ```swift
/// enum Scope: String, CaseIterable { case upcoming = "Upcoming", past = "Past" }
///
/// PRVSegmentedGlassControl(
///     selection: $scope,
///     options: Scope.allCases,
///     title: \.rawValue
/// )
/// ```
public struct PRVSegmentedGlassControl<Option: Hashable>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var selectionNamespace

    @Binding private var selection: Option
    private let options: [Option]
    private let title: (Option) -> String

    /// Creates a segmented control.
    /// - Parameters:
    ///   - selection: The bound selected option.
    ///   - options: All options, in display order.
    ///   - title: Maps an option to its segment label.
    public init(
        selection: Binding<Option>,
        options: [Option],
        title: @escaping (Option) -> String
    ) {
        self._selection = selection
        self.options = options
        self.title = title
    }

    /// Creates a segmented control whose options map to labels via a key
    /// path, e.g. `title: \.rawValue`.
    public init(
        selection: Binding<Option>,
        options: [Option],
        title: KeyPath<Option, String>
    ) {
        self.init(selection: selection, options: options) { $0[keyPath: title] }
    }

    public var body: some View {
        HStack(spacing: PRVSpacing.xxs) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(PRVSpacing.xxs)
        .background {
            if reduceTransparency {
                Capsule().fill(Color.prv.surface)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .prvAnimation(PRVMotion.spring, value: selection)
    }

    /// Built through `ContentBuilder` so the selection state reads as a plain
    /// local and the segment type-checks on its own instead of as one
    /// expression inside `ForEach`.
    @ContentBuilder
    private func segment(for option: Option) -> some View {
        let isSelected = option == selection
        Button {
            PRVHaptics.tap()
            selection = option
        } label: {
            Text(title(option))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? Color.prv.textOnAccent : Color.prv.textPrimary)
                .padding(.vertical, PRVSpacing.xs)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.prv.accentGradient)
                            .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(option))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

extension PRVSegmentedGlassControl where Option == String {
    /// Creates a segmented control over plain strings, using each string as
    /// its own label.
    public init(selection: Binding<String>, options: [String]) {
        self.init(selection: selection, options: options) { $0 }
    }
}

#Preview("Segmented Control — Light") {
    @Previewable @State var scope = "Upcoming"
    @Previewable @State var period = "Week"
    VStack(spacing: PRVSpacing.lg) {
        PRVSegmentedGlassControl(selection: $scope, options: ["Upcoming", "Past", "Cancelled"])
        PRVSegmentedGlassControl(selection: $period, options: ["Day", "Week", "Month", "Year"])
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Segmented Control — Dark") {
    @Previewable @State var scope = "Past"
    PRVSegmentedGlassControl(selection: $scope, options: ["Upcoming", "Past", "Cancelled"])
        .padding(PRVSpacing.lg)
        .background(Color.prv.canvas)
        .preferredColorScheme(.dark)
}
