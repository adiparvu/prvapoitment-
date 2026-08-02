import SwiftUI
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Shared, deterministic display formatting for the shell's appointment
/// surfaces (the salon schedule and the single-booking destination).
/// Pure functions only — no state, no side effects.
enum AppointmentFormat {
    /// Localized short time, e.g. `"2:30 PM"`.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Weekday, day, and month, e.g. `"Thursday, 14 August"`.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// The window a booking occupies, e.g. `"2:30 PM – 4:00 PM"`.
    static func window(_ appointment: Appointment) -> String {
        guard let start = appointment.start else { return "Time to be confirmed" }
        guard let end = appointment.end else { return time(start) }
        return "\(time(start)) – \(time(end))"
    }

    /// Compact duration, e.g. `90` → `"1 h 30 min"`, `45` → `"45 min"`.
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        switch (hours, remainder) {
        case (0, _): return "\(remainder) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(remainder) min"
        }
    }

    /// The services in a booking as one line, e.g. `"Balayage, Gloss"`.
    static func services(_ appointment: Appointment) -> String {
        let names = appointment.items.map(\.serviceName)
        return names.isEmpty ? "Appointment" : names.joined(separator: ", ")
    }

    /// The professionals working a booking, de-duplicated and in order.
    static func professionals(_ appointment: Appointment) -> String? {
        var seen: Set<String> = []
        let names = appointment.items.compactMap(\.professionalName).filter { seen.insert($0).inserted }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Maps transport errors to warm, actionable copy — never raw codes.
    static func friendlyMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Pull to refresh to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. Check your connection and pull to refresh."
        case .rateLimited:
            "Too many requests. Give it a moment and pull to refresh."
        case .unauthorized, .forbidden:
            "You no longer have access to this booking. Sign in again to continue."
        case .notFound:
            "This booking isn't available any more."
        case .conflict, .server, .decoding:
            "We couldn't load this right now. Pull to refresh to try again."
        }
    }
}

// MARK: - Status styling

extension AppointmentStatus {
    /// Semantic tint for this status, shared by the pill and the schedule rail.
    var shellTint: Color {
        switch self {
        case .pendingConfirmation: Color.prv.warning
        case .confirmed: Color.prv.accent
        case .checkedIn: Color.prv.gold
        case .inProgress: Color.prv.success
        case .completed: Color.prv.textSecondary
        case .cancelledByClient, .cancelledBySalon, .noShow: Color.prv.danger
        }
    }

    /// SF Symbol shown inside the pill.
    var shellSymbol: String {
        switch self {
        case .pendingConfirmation: "hourglass"
        case .confirmed: "checkmark.seal"
        case .checkedIn: "person.badge.clock"
        case .inProgress: "scissors"
        case .completed: "checkmark.circle.fill"
        case .cancelledByClient, .cancelledBySalon: "xmark.circle"
        case .noShow: "person.slash"
        }
    }
}

/// A compact status pill for a booking.
struct AppointmentStatusPill: View {
    let status: AppointmentStatus

    var body: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: status.shellSymbol)
                .font(.caption2.weight(.bold))
            Text(status.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(status.shellTint)
        .padding(.vertical, PRVSpacing.xxs)
        .padding(.horizontal, PRVSpacing.xs)
        .background(status.shellTint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.displayName)")
    }
}

/// The shell's standard failure card: what went wrong plus a retry.
struct AppointmentErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        PRVGlassCard {
            VStack(spacing: PRVSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.prv.warning)
                    .accessibilityHidden(true)

                Text(message)
                    .prvStyle(.subheadline)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    PRVHaptics.tap()
                    retry()
                }
                .buttonStyle(.prvGlass)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Previews

#Preview("Status pills") {
    VStack(alignment: .leading, spacing: PRVSpacing.sm) {
        ForEach(AppointmentStatus.allCases, id: \.self) { status in
            AppointmentStatusPill(status: status)
        }
        AppointmentErrorCard(message: "We couldn't load this right now.") {}
    }
    .padding(PRVSpacing.lg)
    .background(Color.prv.canvas)
}
