import SwiftUI

/// A friendly empty state: a gradient-tinted SF Symbol, a title, a short
/// message, and an optional call to action. Use it whenever a screen or
/// section has nothing to show yet.
///
/// ```swift
/// PRVEmptyState(
///     systemImage: "calendar.badge.plus",
///     title: "No appointments yet",
///     message: "When you book a treatment it will show up here.",
///     actionTitle: "Explore Salons"
/// ) {
///     router.push(.discover)
/// }
/// ```
public struct PRVEmptyState: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    /// Creates an empty state.
    /// - Parameters:
    ///   - systemImage: SF Symbol name illustrating the situation.
    ///   - title: Short headline, e.g. "No appointments yet".
    ///   - message: One or two friendly sentences explaining what to do.
    ///   - actionTitle: Optional CTA label.
    ///   - action: Called when the CTA is tapped.
    public init(
        systemImage: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: PRVSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.prv.accentGradient)
                .padding(PRVSpacing.lg)
                .background(Color.prv.accent.opacity(0.08), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: PRVSpacing.xs) {
                Text(title)
                    .prvStyle(.title2)
                    .multilineTextAlignment(.center)
                Text(message)
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle) {
                    PRVHaptics.impact()
                    action()
                }
                .buttonStyle(.prvPrimary)
                .frame(maxWidth: 280)
                .padding(.top, PRVSpacing.xs)
            }
        }
        .padding(PRVSpacing.xl)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Empty State — Light") {
    PRVEmptyState(
        systemImage: "calendar.badge.plus",
        title: "No appointments yet",
        message: "When you book a treatment it will show up here, with reminders so you never miss it.",
        actionTitle: "Explore Salons"
    ) {}
        .frame(maxHeight: .infinity)
        .background(Color.prv.canvas)
}

#Preview("Empty State — Dark") {
    PRVEmptyState(
        systemImage: "magnifyingglass",
        title: "No results",
        message: "Try a different treatment, or widen your search area."
    )
    .frame(maxHeight: .infinity)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
