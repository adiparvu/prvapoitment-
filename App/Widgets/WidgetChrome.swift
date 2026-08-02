import SwiftUI
import WidgetKit
import PRVDesignSystem
import PRVModels

/// Shared chrome for every PRV home-screen widget.
///
/// Widgets cannot use Liquid Glass the way the app does — there is nothing
/// behind them to refract — so the house look is recreated with the same
/// tokens: the canvas colour, a soft brand-gradient wash in the corner, and
/// continuous corner radii. Because both colours are semantic, the result is
/// correct in light and dark without a single branch.
struct PRVWidgetBackground: View {
    var body: some View {
        ZStack {
            Color.prv.canvas
            LinearGradient(
                colors: [
                    Color.prv.accent.opacity(0.20),
                    Color.prv.accentSecondary.opacity(0.10),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

extension View {
    /// Applies the standard PRV widget container background.
    func prvWidgetBackground() -> some View {
        containerBackground(for: .widget) {
            PRVWidgetBackground()
        }
    }

    /// Applies the system accessory background used by Lock Screen and watch
    /// complications.
    func prvAccessoryBackground() -> some View {
        containerBackground(for: .widget) {
            AccessoryWidgetBackground()
        }
    }
}

/// A small tinted symbol tile, the widget-scale echo of the app's glass
/// squircles.
struct PRVWidgetIcon: View {
    let systemImage: String
    var tint: Color = Color.prv.accent
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: PRVRadius.shape(PRVRadius.sm))
            .accessibilityHidden(true)
    }
}

/// The label a widget shows when the app has not published a snapshot yet, or
/// when the client has nothing booked. Never an error — always an invitation.
struct PRVWidgetPlaceholder: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xs) {
            PRVWidgetIcon(systemImage: systemImage)

            Spacer(minLength: 0)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Text(message)
                .font(.caption)
                .foregroundStyle(Color.prv.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

// MARK: - Loyalty tier styling

extension LoyaltyTier {
    /// SF Symbol representing the tier on the loyalty widget.
    var widgetSymbolName: String {
        switch self {
        case .bronze: "leaf.fill"
        case .silver: "sparkle"
        case .gold: "crown.fill"
        case .diamond: "diamond.fill"
        case .black: "hexagon.fill"
        }
    }

    /// Semantic tint for the tier ring and emblem.
    var widgetTint: Color {
        switch self {
        case .bronze: Color.prv.accentSecondary
        case .silver: Color.prv.textSecondary
        case .gold: Color.prv.gold
        case .diamond: Color.prv.accent
        case .black: Color.prv.textPrimary
        }
    }
}

// MARK: - Formatting

/// Date and duration strings shared by the widgets. Kept together so the two
/// widgets never phrase the same moment differently.
enum PRVWidgetFormat {
    /// "Thu 14:00" — the compact when-line under a service name.
    static func dayAndTime(_ date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.abbreviated))
        let time = date.formatted(date: .omitted, time: .shortened)
        return "\(day) \(time)"
    }

    /// "Thursday" / "Today" / "Tomorrow" — the headline day.
    static func relativeDay(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if let week = calendar.date(byAdding: .day, value: 7, to: now), date < week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "14:00 – 16:30" — the service window.
    static func window(start: Date, end: Date) -> String {
        let from = start.formatted(date: .omitted, time: .shortened)
        let to = end.formatted(date: .omitted, time: .shortened)
        return "\(from) – \(to)"
    }

    /// Spoken description used for VoiceOver on the appointment widget.
    static func spokenAppointment(_ appointment: PRVWidgetSnapshot.NextAppointment) -> String {
        var parts = [
            appointment.serviceName,
            "at \(appointment.salonName)",
            relativeDay(appointment.start),
            appointment.start.formatted(date: .omitted, time: .shortened),
        ]
        if let professional = appointment.professionalName {
            parts.append("with \(professional)")
        }
        return parts.joined(separator: ", ")
    }
}
