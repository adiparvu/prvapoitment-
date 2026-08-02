import SwiftUI

/// A small capsule badge for counts ("3", "99+") and short statuses
/// ("New", "VIP"). Count badges hide themselves automatically at zero.
///
/// ```swift
/// PRVBadge(count: unreadCount)              // red, hides at 0
/// PRVBadge("VIP", tint: Color.prv.gold)     // status badge
/// ```
public struct PRVBadge: View {
    private let text: String?
    private let tint: Color

    /// Creates a numeric count badge. Counts above 99 render as "99+";
    /// zero or negative counts render nothing.
    /// - Parameters:
    ///   - count: The number to display.
    ///   - tint: Badge fill. Defaults to `Color.prv.danger` (notification red).
    public init(count: Int, tint: Color = Color.prv.danger) {
        self.text = count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
        self.tint = tint
    }

    /// Creates a short status badge.
    /// - Parameters:
    ///   - text: The status label, e.g. "New".
    ///   - tint: Badge fill. Defaults to `Color.prv.accent`.
    public init(_ text: String, tint: Color = Color.prv.accent) {
        self.text = text.isEmpty ? nil : text
        self.tint = tint
    }

    public var body: some View {
        if let text {
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.prv.textOnAccent)
                .padding(.vertical, 3)
                .padding(.horizontal, PRVSpacing.xxs + 2)
                .frame(minWidth: 20)
                .background(tint, in: Capsule())
                .accessibilityLabel(text)
        }
    }
}

#Preview("Badge — Light") {
    HStack(spacing: PRVSpacing.md) {
        PRVBadge(count: 3)
        PRVBadge(count: 128)
        PRVBadge(count: 0)                       // renders nothing
        PRVBadge("New")
        PRVBadge("VIP", tint: Color.prv.gold)
        PRVBadge("Confirmed", tint: Color.prv.success)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}

#Preview("Badge — Dark") {
    HStack(spacing: PRVSpacing.md) {
        PRVBadge(count: 7)
        PRVBadge("New")
        PRVBadge("VIP", tint: Color.prv.gold)
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}
