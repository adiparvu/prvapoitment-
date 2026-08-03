import SwiftUI

/// A floating Liquid Glass container for screen-level calls to action —
/// the "Book Now" bar. Attach it with the `.prvBottomBar { }` modifier,
/// which pins it inside the bottom safe area so it stays above the home
/// indicator and rises with the keyboard.
///
/// ```swift
/// ScrollView { … }
///     .prvBottomBar {
///         HStack {
///             PRVPriceLabel("€196.50", emphasis: .prominent)
///             Spacer()
///             Button("Book Now") { model.book() }
///                 .buttonStyle(.prvPrimary)
///                 .frame(maxWidth: 180)
///         }
///     }
/// ```
///
/// The bar is the loudest chrome on any screen, so it recedes while its
/// window is inactive (iPad multi-window and Stage Manager) — two PRV windows
/// side by side then show one obvious call to action instead of competing
/// gradients. On iPhone the window is always active and nothing changes.
public struct PRVBottomBar<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.appearsActive) private var appearsActive

    private let content: Content

    /// Creates a floating bottom bar wrapping the given content.
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(PRVSpacing.md)
            .background {
                if reduceTransparency {
                    PRVRadius.shape(PRVRadius.xl).fill(Color.prv.surfaceElevated)
                } else {
                    PRVRadius.shape(PRVRadius.xl).fill(.regularMaterial)
                }
            }
            .overlay {
                PRVRadius.shape(PRVRadius.xl)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            }
            .prvSoftShadow()
            .opacity(appearsActive ? 1 : 0.7)
            .prvAnimation(PRVMotion.gentle, value: appearsActive)
            .padding(.horizontal, PRVSpacing.md)
            .padding(.bottom, PRVSpacing.xs)
    }
}

extension View {
    /// Pins a floating ``PRVBottomBar`` to the bottom safe area of this
    /// view. Content behind it keeps scrolling; the bar stays clear of the
    /// home indicator and moves up when the keyboard appears.
    public func prvBottomBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            PRVBottomBar(content: content)
        }
    }
}

#Preview("Bottom Bar — Light") {
    ScrollView {
        VStack(spacing: PRVSpacing.sm) {
            ForEach(0..<12, id: \.self) { index in
                PRVGlassCard {
                    Text("Treatment option \(index + 1)")
                        .prvStyle(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .prvBottomBar {
        HStack(spacing: PRVSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total").prvStyle(.caption)
                PRVPriceLabel("€196.50", emphasis: .prominent)
            }
            Spacer()
            Button("Book Now") {}
                .buttonStyle(.prvPrimary)
                .frame(maxWidth: 160)
        }
    }
}

#Preview("Bottom Bar — Dark") {
    Color.prv.canvas
        .ignoresSafeArea()
        .prvBottomBar {
            Button("Confirm Booking") {}
                .buttonStyle(.prvPrimary)
        }
        .preferredColorScheme(.dark)
}
