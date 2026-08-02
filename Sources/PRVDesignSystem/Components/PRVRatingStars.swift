import SwiftUI

/// Gold star ratings, in two flavors:
///
/// - **Display**: read-only, supports fractional ratings at half-star
///   precision — `PRVRatingStars(rating: 4.6)`.
/// - **Interactive**: whole-star input bound to an `Int`, used when writing
///   a review — `PRVRatingStars(selection: $stars)`.
///
/// Both variants are a single VoiceOver element; the interactive one is
/// adjustable with swipe up/down.
public struct PRVRatingStars: View {
    private let maximum: Int
    private let size: CGFloat
    private let spacing: CGFloat
    private let rating: Double
    private let selection: Binding<Int>?

    /// Creates a read-only rating display.
    /// - Parameters:
    ///   - rating: The rating value, e.g. `4.6`. Rendered at half-star precision.
    ///   - maximum: Number of stars. Defaults to 5.
    ///   - size: Point size of each star. Defaults to 13 (inline metadata).
    ///   - spacing: Gap between stars. Defaults to 2.
    public init(rating: Double, maximum: Int = 5, size: CGFloat = 13, spacing: CGFloat = 2) {
        self.rating = rating
        self.maximum = max(1, maximum)
        self.size = size
        self.spacing = spacing
        self.selection = nil
    }

    /// Creates an interactive whole-star input.
    /// - Parameters:
    ///   - selection: Bound star count (0…`maximum`).
    ///   - maximum: Number of stars. Defaults to 5.
    ///   - size: Point size of each star. Defaults to 30 (comfortable tap target).
    ///   - spacing: Gap between stars. Defaults to `PRVSpacing.xs`.
    public init(
        selection: Binding<Int>,
        maximum: Int = 5,
        size: CGFloat = 30,
        spacing: CGFloat = PRVSpacing.xs
    ) {
        self.selection = selection
        self.rating = Double(selection.wrappedValue)
        self.maximum = max(1, maximum)
        self.size = size
        self.spacing = spacing
    }

    public var body: some View {
        if let selection {
            interactiveStars(selection)
        } else {
            displayStars
        }
    }

    // MARK: - Display

    private var displayStars: some View {
        HStack(spacing: spacing) {
            ForEach(1...maximum, id: \.self) { index in
                Image(systemName: symbolName(for: index))
                    .font(.system(size: size))
                    .foregroundStyle(Color.prv.gold)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating.formatted(.number.precision(.fractionLength(0...1)))) out of \(maximum)")
    }

    /// Full, half, or empty symbol for a star position, at half-star precision.
    private func symbolName(for index: Int) -> String {
        let position = Double(index)
        if rating >= position - 0.25 {
            return "star.fill"
        } else if rating >= position - 0.75 {
            return "star.leadinghalf.filled"
        } else {
            return "star"
        }
    }

    // MARK: - Interactive

    private func interactiveStars(_ selection: Binding<Int>) -> some View {
        HStack(spacing: spacing) {
            ForEach(1...maximum, id: \.self) { index in
                Button {
                    PRVHaptics.tap()
                    selection.wrappedValue = index
                } label: {
                    Image(systemName: index <= selection.wrappedValue ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(
                            index <= selection.wrappedValue
                                ? Color.prv.gold
                                : Color.prv.textSecondary.opacity(0.45)
                        )
                        .symbolEffect(.bounce, value: index == selection.wrappedValue)
                }
                .buttonStyle(.plain)
            }
        }
        .prvAnimation(PRVMotion.quick, value: selection.wrappedValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue("\(selection.wrappedValue) of \(maximum) stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                selection.wrappedValue = min(maximum, selection.wrappedValue + 1)
            case .decrement:
                selection.wrappedValue = max(0, selection.wrappedValue - 1)
            @unknown default:
                break
            }
        }
    }
}

#Preview("Rating Stars — Light") {
    @Previewable @State var stars = 4
    VStack(alignment: .leading, spacing: PRVSpacing.lg) {
        HStack(spacing: PRVSpacing.xs) {
            PRVRatingStars(rating: 4.6)
            Text("4.6 (482)").prvStyle(.footnote)
        }
        PRVRatingStars(rating: 2.5)
        PRVRatingStars(selection: $stars)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Rating Stars — Dark") {
    @Previewable @State var stars = 3
    VStack(alignment: .leading, spacing: PRVSpacing.lg) {
        PRVRatingStars(rating: 4.9)
        PRVRatingStars(selection: $stars)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
