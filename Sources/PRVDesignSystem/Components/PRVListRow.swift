import SwiftUI

/// The standard PRV list row: leading icon or avatar, title + optional
/// subtitle, and a trailing accessory. Fully generic, with convenience
/// initializers for the common shapes:
///
/// ```swift
/// // Icon row with default chevron:
/// PRVListRow(title: "Payment Methods", subtitle: "Visa ··4242", systemImage: "creditcard")
///
/// // Custom leading + trailing:
/// PRVListRow(title: client.name, subtitle: "Last visit 2w ago") {
///     PRVAvatar(name: client.name)
/// } trailing: {
///     PRVBadge("VIP", tint: Color.prv.gold)
/// }
/// ```
public struct PRVListRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let leading: Leading
    private let trailing: Trailing

    /// Creates a row with fully custom leading and trailing views.
    /// - Parameters:
    ///   - title: Primary line.
    ///   - subtitle: Optional secondary line.
    ///   - leading: Leading accessory (avatar, icon…).
    ///   - trailing: Trailing accessory (chevron, badge, toggle…).
    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: PRVSpacing.sm) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.prv.textPrimary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .prvStyle(.subheadline)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: PRVSpacing.xs)

            trailing
        }
        .padding(.vertical, PRVSpacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension PRVListRow where Trailing == PRVListRowChevron {
    /// Creates a row with a custom leading view and the default disclosure
    /// chevron.
    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(title: title, subtitle: subtitle, leading: leading) {
            PRVListRowChevron()
        }
    }
}

extension PRVListRow where Leading == PRVListRowIcon, Trailing == PRVListRowChevron {
    /// Creates the most common row: tinted SF Symbol tile, texts, chevron.
    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = Color.prv.accent
    ) {
        self.init(title: title, subtitle: subtitle) {
            PRVListRowIcon(systemImage: systemImage, tint: tint)
        } trailing: {
            PRVListRowChevron()
        }
    }
}

extension PRVListRow where Leading == EmptyView, Trailing == PRVListRowChevron {
    /// Creates a text-only row with a disclosure chevron.
    public init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) {
            EmptyView()
        } trailing: {
            PRVListRowChevron()
        }
    }
}

/// The standard trailing disclosure chevron used by ``PRVListRow``.
public struct PRVListRowChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.prv.textSecondary.opacity(0.6))
            .accessibilityHidden(true)
    }
}

/// A tinted SF Symbol tile used as the default leading view of ``PRVListRow``.
public struct PRVListRowIcon: View {
    private let systemImage: String
    private let tint: Color

    /// Creates an icon tile.
    /// - Parameters:
    ///   - systemImage: SF Symbol name.
    ///   - tint: Icon and background tint. Defaults to the brand accent.
    public init(systemImage: String, tint: Color = Color.prv.accent) {
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.12), in: PRVRadius.shape(PRVRadius.sm))
            .accessibilityHidden(true)
    }
}

#Preview("List Row — Light") {
    VStack(spacing: PRVSpacing.xs) {
        PRVListRow(
            title: "Payment Methods",
            subtitle: "Visa ··4242",
            systemImage: "creditcard"
        )
        PRVListRow(
            title: "Notifications",
            systemImage: "bell.badge",
            tint: Color.prv.warning
        )
        PRVListRow(title: "Sofia Laurent", subtitle: "Last visit 2 weeks ago") {
            PRVAvatar(name: "Sofia Laurent")
        } trailing: {
            PRVBadge("VIP", tint: Color.prv.gold)
        }
        PRVListRow(title: "Privacy Policy")
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("List Row — Dark") {
    VStack(spacing: PRVSpacing.xs) {
        PRVListRow(
            title: "Payment Methods",
            subtitle: "Visa ··4242",
            systemImage: "creditcard"
        )
        PRVListRow(title: "Sofia Laurent", subtitle: "Last visit 2 weeks ago") {
            PRVAvatar(name: "Sofia Laurent")
        } trailing: {
            PRVBadge(count: 2)
        }
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
