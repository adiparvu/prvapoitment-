import SwiftUI
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// Renders its content only when the active session holds the required
/// permission; otherwise shows a tasteful locked state.
///
/// This is the platform's RBAC gate (ARCHITECTURE §5): features wrap
/// privileged UI in `RoleGate(requires: .manageInventory) { ... }` instead of
/// branching on raw role names.
public struct RoleGate<Content: View>: View {
    @Environment(UserSession.self) private var session

    private let permission: Permission
    private let content: Content

    /// Creates a gate that shows `content` only when the session's user holds
    /// `permission`, and a locked placeholder otherwise.
    public init(requires permission: Permission, @ViewBuilder content: () -> Content) {
        self.permission = permission
        self.content = content()
    }

    public var body: some View {
        if session.can(permission) {
            content
        } else {
            RoleGateLockedView(permission: permission)
        }
    }
}

/// The locked placeholder shown in place of gated content: a quiet glass card
/// that explains what is locked and how to unlock it, adapted for guests
/// versus signed-in users with insufficient access.
struct RoleGateLockedView: View {
    @Environment(UserSession.self) private var session

    let permission: Permission

    private var hint: String {
        session.isAuthenticated
            ? "Ask a manager to update your role."
            : "Sign in to unlock this."
    }

    var body: some View {
        VStack(spacing: PRVSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.prv.accentGradient)
                    .opacity(0.15)
                    .frame(width: 56, height: 56)
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(Color.prv.accent)
            }
            .accessibilityHidden(true)

            Text("\(permission.gateDescription) is locked")
                .prvStyle(.headline)
                .multilineTextAlignment(.center)

            Text(hint)
                .prvStyle(.footnote)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .prvGlassCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(permission.gateDescription) is locked. \(hint)")
    }
}

// MARK: - Permission copy

extension Permission {
    /// Short human-readable name for what the permission unlocks, used in
    /// locked-state messaging.
    var gateDescription: String {
        switch self {
        case .browse: "Browsing"
        case .book: "Booking"
        case .review: "Writing reviews"
        case .chat: "Messaging"
        case .payOnline: "Online payment"
        case .priorityBooking: "Priority booking"
        case .manageOwnCalendar: "Your calendar"
        case .manageOwnServices: "Your services"
        case .viewOwnEarnings: "Earnings"
        case .viewClients: "Client list"
        case .checkInOut: "Client check-in"
        case .manageCalendar: "The salon calendar"
        case .manageTeam: "Team management"
        case .manageInventory: "Inventory"
        case .viewReports: "Reports"
        case .manageServices: "Service management"
        case .respondToReviews: "Review responses"
        case .manageCRM: "Client records"
        case .manageSalon: "Salon settings"
        case .managePayroll: "Payroll"
        case .manageMarketing: "Marketing"
        case .manageMemberships: "Membership management"
        case .manageFinance: "Finance"
        case .configurePrepayment: "Prepayment settings"
        case .manageMultipleLocations: "Multi-location management"
        case .compareLocations: "Location comparison"
        case .manageRefunds: "Refunds"
        case .moderateReviews: "Review moderation"
        case .manageFeatureFlags: "Feature flags"
        case .developerTools: "Developer tools"
        }
    }
}

// MARK: - Previews

#Preview("Unlocked — client can book") {
    RoleGate(requires: .book) {
        Text("Booking flow goes here")
            .prvStyle(.body)
            .prvGlassCard()
    }
    .padding(PRVSpacing.lg)
    .environment(UserSession.previewClient)
}

#Preview("Locked — client vs. inventory") {
    RoleGate(requires: .manageInventory) {
        Text("Inventory tools")
            .prvStyle(.body)
    }
    .padding(PRVSpacing.lg)
    .environment(UserSession.previewClient)
}

#Preview("Locked — guest") {
    RoleGate(requires: .book) {
        Text("Booking flow")
            .prvStyle(.body)
    }
    .padding(PRVSpacing.lg)
    .environment(UserSession())
}

#Preview("Unlocked — owner dashboard") {
    RoleGate(requires: .manageSalon) {
        Text("Salon settings")
            .prvStyle(.body)
            .prvGlassCard()
    }
    .padding(PRVSpacing.lg)
    .environment(UserSession.previewOwner)
}
