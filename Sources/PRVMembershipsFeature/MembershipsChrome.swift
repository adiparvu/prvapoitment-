import SwiftUI
import PRVDesignSystem
import PRVModels

// MARK: - Card chassis

/// The shared card chassis for this module: a full-bleed gradient header
/// sitting directly on a Liquid Glass body, clipped to one continuous corner
/// curve.
///
/// `prvGlassCard` pads its content, which is exactly wrong for a header that
/// must run edge to edge — so this composes the same treatment (material,
/// hairline, layered shadow, Reduce Transparency fallback) around two stacked
/// regions instead of one padded one.
struct GradientHeaderCard<Header: View, Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let gradient: LinearGradient
    private let radius: CGFloat
    private let header: Header
    private let content: Content

    /// Creates a gradient-headed glass card.
    /// - Parameters:
    ///   - gradient: Wash behind the header region.
    ///   - radius: Continuous corner radius. Defaults to `PRVRadius.xl`.
    ///   - header: Content laid on the gradient.
    ///   - content: Content laid on glass beneath it.
    init(
        gradient: LinearGradient,
        radius: CGFloat = PRVRadius.xl,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.gradient = gradient
        self.radius = radius
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(PRVSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(gradient)

            content
                .padding(PRVSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if reduceTransparency {
                        Color.prv.surface
                    } else {
                        Rectangle().fill(.ultraThinMaterial)
                    }
                }
        }
        .clipShape(PRVRadius.shape(radius))
        .overlay {
            PRVRadius.shape(radius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .prvSoftShadow()
    }
}

// MARK: - Medallion

/// A gradient disc carrying a single SF Symbol — the tier emblem on
/// membership cards and the theme mark on package cards.
struct GradientMedallion: View {
    /// SF Symbol drawn inside the disc.
    let systemName: String
    /// Gradient filling the disc.
    let gradient: LinearGradient
    /// Disc diameter in points.
    var size: CGFloat = 44
    /// Symbol colour, chosen to read on `gradient`.
    var symbolColor: Color = Color.prv.textOnAccent

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(symbolColor)
            .frame(width: size, height: size)
            .background(gradient, in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

extension LinearGradient {
    /// A translucent white scrim for emblems that sit *on* a coloured
    /// gradient, where filling them with that same gradient would make them
    /// vanish. Frosted glass, not paint.
    static var membershipScrim: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.30), .white.opacity(0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Savings badge

/// A green savings capsule for package cards, e.g. "Save €80 · 15%".
struct SavingsBadge: View {
    /// How much cheaper the bundle is than its parts.
    let savings: Money
    /// The same figure as a percentage, when it is worth stating.
    let percent: Int?

    var body: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: "tag.fill")
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(Color.prv.textOnAccent)
        .padding(.vertical, PRVSpacing.xxs)
        .padding(.horizontal, PRVSpacing.xs)
        .background(Color.prv.success, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        guard let percent else { return "Save \(savings.formatted)" }
        return "Save \(savings.formatted) · \(percent)%"
    }

    private var accessibilityLabel: String {
        guard let percent else { return "Save \(savings.formatted)" }
        return "Save \(savings.formatted), \(percent) percent off"
    }
}

// MARK: - Inline failure

/// A section-level failure card: warm copy plus a retry, used when one part
/// of a screen fails while the rest is perfectly usable.
struct InlineFailureCard: View {
    /// SF Symbol illustrating the failure.
    var systemImage = "exclamationmark.triangle.fill"
    /// Human, actionable explanation.
    let message: String
    /// Retry label.
    var actionTitle = "Try Again"
    /// Called when the retry is tapped.
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Color.prv.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                Text(message)
                    .prvStyle(.footnote)
                    .fixedSize(horizontal: false, vertical: true)

                Button(actionTitle) {
                    PRVHaptics.tap()
                    action()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .buttonStyle(.plain)
                .accessibilityLabel("\(actionTitle). \(message)")
            }

            Spacer(minLength: 0)
        }
        .prvGlassCard()
    }
}

// MARK: - Detail rows

/// A compact icon + label + value row used inside detail sheets and the
/// fine-print cards ("Billed monthly", "Redeem within 6 months").
struct DetailFactRow: View {
    /// SF Symbol for the fact.
    let systemImage: String
    /// What the fact is about.
    let title: String
    /// The fact itself, when it deserves its own trailing column.
    var value: String?
    /// Icon tint.
    var tint: Color = Color.prv.accent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.sm) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.prv.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let value {
                Spacer(minLength: PRVSpacing.xs)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.prv.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Chrome — Light") {
    ScrollView {
        VStack(spacing: PRVSpacing.lg) {
            GradientHeaderCard(gradient: MembershipTierStyle.style(for: .gold).gradient) {
                HStack(spacing: PRVSpacing.sm) {
                    GradientMedallion(
                        systemName: "crown.fill",
                        gradient: Color.prv.accentGradient,
                        symbolColor: Color.prv.textOnAccent
                    )
                    Text("Gold")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.prv.textOnAccent)
                }
            } content: {
                VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                    Text("Lumière Gold").prvStyle(.headline)
                    DetailFactRow(systemImage: "calendar", title: "Billed monthly", value: "€89.00")
                }
            }

            SavingsBadge(savings: Money(80), percent: 15)

            InlineFailureCard(message: "We couldn't load your memberships just now.") {}
        }
        .padding(PRVSpacing.lg)
    }
    .background(Color.prv.canvas)
}

#Preview("Chrome — Dark") {
    VStack(spacing: PRVSpacing.lg) {
        GradientHeaderCard(gradient: MembershipTierStyle.style(for: .black).gradient) {
            GradientMedallion(
                systemName: "seal.fill",
                gradient: MembershipTierStyle.style(for: .black).gradient,
                symbolColor: Color.prv.gold
            )
        } content: {
            Text("Black").prvStyle(.headline)
        }
        InlineFailureCard(message: "You appear to be offline.") {}
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
