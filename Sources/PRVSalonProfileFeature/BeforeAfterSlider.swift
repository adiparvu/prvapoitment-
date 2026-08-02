import SwiftUI
import PRVDesignSystem

/// An interactive before/after comparison: the "after" image sits beneath
/// the "before" image, which is revealed from the leading edge up to a
/// draggable divider with a glass handle. VoiceOver users adjust the
/// divider with swipe up/down.
struct BeforeAfterSlider: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let beforeURL: URL?
    let afterURL: URL
    var caption: String?

    /// Position of the divider, 0 (all after) … 1 (all before).
    @State private var fraction: CGFloat = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            comparison
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(PRVRadius.shape(PRVRadius.lg))
                .overlay {
                    PRVRadius.shape(PRVRadius.lg)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }

            if let caption {
                Text(caption)
                    .prvStyle(.footnote)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Comparison canvas

    private var comparison: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let dividerX = width * fraction

            ZStack(alignment: .leading) {
                PRVAsyncImage(url: afterURL)
                    .frame(width: width, height: proxy.size.height)
                    .clipped()

                PRVAsyncImage(url: beforeURL)
                    .frame(width: width, height: proxy.size.height)
                    .clipped()
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: dividerX)
                    }

                cornerLabels

                divider(height: proxy.size.height)
                    .position(x: dividerX, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        fraction = min(1, max(0, value.location.x / max(width, 1)))
                    }
                    .onEnded { _ in
                        PRVHaptics.tap()
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Before and after comparison")
        .accessibilityValue("\(Int(fraction * 100)) percent before")
        .accessibilityHint("Swipe up or down to move the divider")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                fraction = min(1, fraction + 0.1)
            case .decrement:
                fraction = max(0, fraction - 0.1)
            @unknown default:
                break
            }
        }
    }

    /// The divider line with its glass drag handle.
    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.25), radius: 2)

            Image(systemName: "arrow.left.and.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.prv.textPrimary)
                .frame(width: 34, height: 34)
                .background {
                    if reduceTransparency {
                        Circle().fill(Color.prv.surfaceElevated)
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                }
                .prvSoftShadow()
        }
    }

    /// "Before" / "After" markers that fade out as the divider crowds them.
    private var cornerLabels: some View {
        VStack {
            HStack {
                cornerLabel("Before")
                    .opacity(fraction > 0.18 ? 1 : 0)
                Spacer()
                cornerLabel("After")
                    .opacity(fraction < 0.82 ? 1 : 0)
            }
            Spacer()
        }
        .padding(PRVSpacing.xs)
        .prvAnimation(PRVMotion.quick, value: fraction > 0.18)
        .prvAnimation(PRVMotion.quick, value: fraction < 0.82)
        .accessibilityHidden(true)
    }

    private func cornerLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.prv.textOnAccent)
            .padding(.vertical, 3)
            .padding(.horizontal, PRVSpacing.xs)
            .background(.black.opacity(0.45), in: Capsule())
    }
}

#Preview("Before / After") {
    BeforeAfterSlider(
        beforeURL: URL(string: "https://picsum.photos/seed/before/600/450"),
        afterURL: URL(string: "https://picsum.photos/seed/after/600/450")!,
        caption: "Balayage color correction — full session"
    )
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}
