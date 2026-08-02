import SwiftUI

/// A screen-section header: a prominent title, an optional subtitle, and an
/// optional trailing action ("See All"). The title is exposed to VoiceOver
/// as a header for fast rotor navigation.
///
/// ```swift
/// PRVSectionHeader("Top Rated Near You", actionTitle: "See All") {
///     router.push(.discover)
/// }
/// ```
public struct PRVSectionHeader: View {
    private let title: String
    private let subtitle: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    /// Creates a section header.
    /// - Parameters:
    ///   - title: Section title.
    ///   - subtitle: Optional supporting line beneath the title.
    ///   - actionTitle: Optional trailing action label, e.g. "See All".
    ///   - action: Called when the trailing action is tapped.
    public init(
        _ title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.sm) {
            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                Text(title)
                    .prvStyle(.title2)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .prvStyle(.footnote)
                }
            }

            Spacer(minLength: PRVSpacing.xs)

            if let actionTitle, let action {
                Button {
                    PRVHaptics.tap()
                    action()
                } label: {
                    HStack(spacing: PRVSpacing.xxs) {
                        Text(actionTitle)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.prv.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(actionTitle), \(title)")
            }
        }
    }
}

#Preview("Section Header — Light") {
    VStack(spacing: PRVSpacing.xl) {
        PRVSectionHeader("Top Rated Near You", actionTitle: "See All") {}
        PRVSectionHeader(
            "Your Favorites",
            subtitle: "Salons you keep coming back to",
            actionTitle: "See All"
        ) {}
        PRVSectionHeader("Recent Bookings")
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Section Header — Dark") {
    VStack(spacing: PRVSpacing.xl) {
        PRVSectionHeader("Top Rated Near You", actionTitle: "See All") {}
        PRVSectionHeader("Recent Bookings")
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
