import ActivityKit
import SwiftUI
import WidgetKit
import PRVDesignSystem

/// The booking Live Activity: a Lock Screen banner and the full Dynamic
/// Island treatment for an appointment that is imminent or under way.
///
/// The countdown is a `Text(timerInterval:)`, so it ticks without the app
/// pushing updates — the app only sends a new `ContentState` when something
/// *meaningful* changes (the salon confirms, the client checks in, the
/// professional runs late). Every surface links to
/// `prvbeauty://appointment/<uuid>`.
struct BookingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BookingActivityAttributes.self) { context in
            BookingLockScreenBanner(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(Color.prv.canvas.opacity(0.92))
            .activitySystemActionForegroundColor(Color.prv.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: PRVSpacing.xs) {
                        Image(systemName: "scissors")
                            .font(.title3)
                            .foregroundStyle(Color.prv.accentGradient)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.attributes.serviceName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.prv.textPrimary)
                                .lineLimit(1)
                            Text(context.attributes.salonName)
                                .font(.caption2)
                                .foregroundStyle(Color.prv.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(
                            timerInterval: context.state.activeCountdownRange(),
                            countsDown: true,
                            showsHours: true
                        )
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Color.prv.accent)
                        .frame(maxWidth: 84)

                        Text(context.state.isUnderway() ? "remaining" : "until start")
                            .font(.caption2)
                            .foregroundStyle(Color.prv.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.prv.textSecondary)
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Link(destination: context.attributes.deepLinkURL) {
                        HStack(spacing: PRVSpacing.xs) {
                            Image(systemName: "person.fill")
                                .font(.caption)
                            Text("With \(context.state.professionalName)")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: PRVSpacing.xs)
                            Text("View booking")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(Color.prv.accent)
                        .padding(.top, PRVSpacing.xxs)
                    }
                    .accessibilityLabel("View booking with \(context.state.professionalName)")
                }
            } compactLeading: {
                Image(systemName: "scissors")
                    .foregroundStyle(Color.prv.accent)
                    .accessibilityLabel("PRV Beauty appointment")
            } compactTrailing: {
                Text(
                    timerInterval: context.state.activeCountdownRange(),
                    countsDown: true,
                    showsHours: false
                )
                .monospacedDigit()
                .foregroundStyle(Color.prv.accent)
                .frame(maxWidth: 52)
                .accessibilityLabel("Time remaining")
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.prv.accentGradient)
                    .accessibilityLabel("PRV Beauty appointment")
            }
            .widgetURL(context.attributes.deepLinkURL)
            .keylineTint(Color.prv.accent)
        }
    }
}

// MARK: - Lock Screen

/// The Lock Screen / banner presentation: the service and salon on the left,
/// a live countdown on the right, and a link into the booking.
struct BookingLockScreenBanner: View {
    let attributes: BookingActivityAttributes
    let state: BookingActivityAttributes.ContentState

    var body: some View {
        Link(destination: attributes.deepLinkURL) {
            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                HStack(alignment: .top, spacing: PRVSpacing.sm) {
                    PRVWidgetIcon(systemImage: "scissors", size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(attributes.serviceName)
                            .font(.headline)
                            .foregroundStyle(Color.prv.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(attributes.salonName)
                            .font(.subheadline)
                            .foregroundStyle(Color.prv.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: PRVSpacing.xs)

                    VStack(alignment: .trailing, spacing: 0) {
                        Text(
                            timerInterval: state.activeCountdownRange(),
                            countsDown: true,
                            showsHours: true
                        )
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Color.prv.accent)
                        .frame(maxWidth: 96)

                        Text(state.isUnderway() ? "remaining" : "until start")
                            .font(.caption2)
                            .foregroundStyle(Color.prv.textSecondary)
                    }
                }

                HStack(spacing: PRVSpacing.xs) {
                    Text(state.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.prv.accent)
                        .padding(.horizontal, PRVSpacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.prv.accent.opacity(0.14), in: Capsule())

                    Label(state.professionalName, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(Color.prv.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: PRVSpacing.xxs)

                    Text(PRVWidgetFormat.window(start: state.start, end: state.end))
                        .font(.caption)
                        .foregroundStyle(Color.prv.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(PRVSpacing.md)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(attributes.serviceName) at \(attributes.salonName)")
        .accessibilityValue(
            "\(state.statusText), with \(state.professionalName), \(PRVWidgetFormat.window(start: state.start, end: state.end))"
        )
        .accessibilityHint("Opens the booking")
    }
}

// MARK: - Previews

extension BookingActivityAttributes {
    /// Fixture used by the Live Activity previews.
    fileprivate static var preview: BookingActivityAttributes {
        BookingActivityAttributes(
            salonName: "Maison Lumière",
            serviceName: "Balayage & Gloss",
            appointmentID: UUID()
        )
    }
}

extension BookingActivityAttributes.ContentState {
    /// Confirmed, starting in 40 minutes.
    fileprivate static var previewUpcoming: BookingActivityAttributes.ContentState {
        BookingActivityAttributes.ContentState(
            statusText: "Confirmed",
            professionalName: "Amélie Dubois",
            start: Date.now.addingTimeInterval(60 * 40),
            end: Date.now.addingTimeInterval(60 * 40 + 150 * 60)
        )
    }

    /// Under way, with the chair time counting down.
    fileprivate static var previewUnderway: BookingActivityAttributes.ContentState {
        BookingActivityAttributes.ContentState(
            statusText: "In progress",
            professionalName: "Amélie Dubois",
            start: Date.now.addingTimeInterval(-30 * 60),
            end: Date.now.addingTimeInterval(120 * 60)
        )
    }
}

#Preview("Live Activity — Lock Screen", as: .content, using: BookingActivityAttributes.preview) {
    BookingLiveActivity()
} contentStates: {
    BookingActivityAttributes.ContentState.previewUpcoming
    BookingActivityAttributes.ContentState.previewUnderway
}

#Preview("Live Activity — Island Expanded", as: .dynamicIsland(.expanded), using: BookingActivityAttributes.preview) {
    BookingLiveActivity()
} contentStates: {
    BookingActivityAttributes.ContentState.previewUpcoming
    BookingActivityAttributes.ContentState.previewUnderway
}

#Preview("Live Activity — Island Compact", as: .dynamicIsland(.compact), using: BookingActivityAttributes.preview) {
    BookingLiveActivity()
} contentStates: {
    BookingActivityAttributes.ContentState.previewUpcoming
}

#Preview("Live Activity — Island Minimal", as: .dynamicIsland(.minimal), using: BookingActivityAttributes.preview) {
    BookingLiveActivity()
} contentStates: {
    BookingActivityAttributes.ContentState.previewUnderway
}
