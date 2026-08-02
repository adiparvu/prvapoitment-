import SwiftUI
import WidgetKit
import PRVDesignSystem
import PRVModels

/// Home-screen widget showing the client's next appointment with a live
/// countdown, in small and medium sizes.
///
/// It reads the JSON snapshot the app publishes into the shared app group —
/// widgets never touch the network — and falls back to an inviting placeholder
/// when nothing is booked or no snapshot exists yet. Tapping deep-links
/// straight to the booking via `prvbeauty://appointment/<uuid>`.
struct NextAppointmentWidget: Widget {
    /// Kind identifier; also the key WidgetKit reloads by.
    static let kind = "com.prv.beauty.widget.next-appointment"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NextAppointmentProvider()) { entry in
            NextAppointmentWidgetView(entry: entry)
                .prvWidgetBackground()
        }
        .configurationDisplayName("Next Appointment")
        .description("Your next visit, with a live countdown.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

/// One rendered moment of the next-appointment widget.
struct NextAppointmentEntry: TimelineEntry {
    let date: Date
    let appointment: PRVWidgetSnapshot.NextAppointment?

    /// Entry used for the redacted placeholder and previews.
    static let placeholder = NextAppointmentEntry(
        date: .now,
        appointment: PRVWidgetSnapshot.preview.nextAppointment
    )

    /// Entry for a client with nothing booked.
    static let empty = NextAppointmentEntry(date: .now, appointment: nil)
}

/// Reads the shared snapshot and schedules the widget's own refresh cadence.
///
/// Countdown text updates itself (`Text(_:style: .relative)`), so the timeline
/// only needs entries at the moments the *content* changes: when the
/// appointment starts, and when it ends and should disappear.
struct NextAppointmentProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextAppointmentEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (NextAppointmentEntry) -> Void) {
        // Gallery previews get the fixture; real snapshots get real data.
        completion(context.isPreview ? .placeholder : Self.currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextAppointmentEntry>) -> Void) {
        let now = Date.now
        let entry = Self.currentEntry(at: now)

        var entries = [entry]
        var refresh = now.addingTimeInterval(30 * 60)

        if let appointment = entry.appointment {
            // Re-render exactly when the visit begins and when it finishes, so
            // the status line and the countdown swap without a stale frame.
            if appointment.start > now {
                entries.append(NextAppointmentEntry(date: appointment.start, appointment: appointment))
            }
            let finish = max(appointment.end, appointment.start.addingTimeInterval(60))
            entries.append(NextAppointmentEntry(date: finish, appointment: nil))
            refresh = min(refresh, finish.addingTimeInterval(60))
        }

        completion(Timeline(entries: entries, policy: .after(refresh)))
    }

    /// Loads the published snapshot, dropping appointments that have already
    /// finished so a stale file never pins a past booking to the home screen.
    private static func currentEntry(at now: Date = .now) -> NextAppointmentEntry {
        let appointment = PRVWidgetSnapshot.load()?.nextAppointment
        guard let appointment, !appointment.hasFinished(at: now) else {
            return NextAppointmentEntry(date: now, appointment: nil)
        }
        return NextAppointmentEntry(date: now, appointment: appointment)
    }
}

// MARK: - Views

/// Routes to the right layout for the widget family.
struct NextAppointmentWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: NextAppointmentEntry

    var body: some View {
        Group {
            if let appointment = entry.appointment {
                switch family {
                case .systemMedium:
                    MediumNextAppointmentView(appointment: appointment, now: entry.date)
                default:
                    SmallNextAppointmentView(appointment: appointment, now: entry.date)
                }
            } else {
                PRVWidgetPlaceholder(
                    systemImage: "sparkles",
                    title: "Nothing booked",
                    message: "Your next great hair day is one tap away."
                )
            }
        }
        .widgetURL(entry.appointment?.deepLinkURL ?? PRVDeepLink.beautyAssistant)
    }
}

/// systemSmall: day, service, salon, countdown — stacked and legible at a
/// glance.
struct SmallNextAppointmentView: View {
    let appointment: PRVWidgetSnapshot.NextAppointment
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
            HStack(spacing: PRVSpacing.xxs) {
                PRVWidgetIcon(systemImage: "calendar", size: 22)
                Text(PRVWidgetFormat.relativeDay(appointment.start, now: now))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            Text(appointment.serviceName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(appointment.salonName)
                .font(.caption)
                .foregroundStyle(Color.prv.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            AppointmentCountdown(appointment: appointment, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next appointment")
        .accessibilityValue(PRVWidgetFormat.spokenAppointment(appointment))
    }
}

/// systemMedium: a date block on the left, the full booking on the right.
struct MediumNextAppointmentView: View {
    let appointment: PRVWidgetSnapshot.NextAppointment
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.md) {
            DateBlock(date: appointment.start)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                HStack(spacing: PRVSpacing.xxs) {
                    Text(appointment.serviceName)
                        .font(.headline)
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if appointment.additionalServiceCount > 0 {
                        Text("+\(appointment.additionalServiceCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.prv.textOnAccent)
                            .padding(.horizontal, PRVSpacing.xxs)
                            .padding(.vertical, 1)
                            .background(Color.prv.accent, in: Capsule())
                    }
                }

                Text(appointment.salonName)
                    .font(.subheadline)
                    .foregroundStyle(Color.prv.textSecondary)
                    .lineLimit(1)

                if let professional = appointment.professionalName {
                    Label(professional, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(Color.prv.textSecondary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: PRVSpacing.xs) {
                    Text(appointment.statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                        .padding(.horizontal, PRVSpacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.prv.accent.opacity(0.14), in: Capsule())

                    Spacer(minLength: 0)

                    AppointmentCountdown(appointment: appointment, now: now)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next appointment")
        .accessibilityValue(PRVWidgetFormat.spokenAppointment(appointment))
    }
}

/// The tall date plaque on the medium layout.
private struct DateBlock: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.abbreviated)))
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.prv.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color.prv.accentGradient)

            VStack(spacing: 1) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.prv.textPrimary)
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.prv.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, PRVSpacing.xxs)
        }
        .frame(width: 62)
        .background(Color.prv.surface, in: PRVRadius.shape(PRVRadius.md))
        .clipShape(PRVRadius.shape(PRVRadius.md))
        .accessibilityHidden(true)
    }
}

/// The auto-updating countdown line: time remaining until the visit, or the
/// service window once it is under way.
private struct AppointmentCountdown: View {
    let appointment: PRVWidgetSnapshot.NextAppointment
    let now: Date

    var body: some View {
        HStack(spacing: PRVSpacing.xxs) {
            Image(systemName: appointment.isUnderway(at: now) ? "scissors" : "clock.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.prv.accent)

            if appointment.isUnderway(at: now) {
                Text("In progress · ends \(appointment.end, style: .time)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.prv.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text(appointment.start, style: .relative)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.prv.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Next Appointment — Small", as: .systemSmall) {
    NextAppointmentWidget()
} timeline: {
    NextAppointmentEntry.placeholder
    NextAppointmentEntry.empty
}

#Preview("Next Appointment — Medium", as: .systemMedium) {
    NextAppointmentWidget()
} timeline: {
    NextAppointmentEntry.placeholder
    NextAppointmentEntry.empty
}
