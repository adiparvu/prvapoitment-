import SwiftUI
import PRVDesignSystem
import PRVModels

/// One notification, rendered as a floating glass row: a tinted squircle
/// carrying the kind's SF Symbol, the title and body, the relative time, and —
/// while unread — a gradient dot pinned to the icon.
///
/// Unread rows carry more weight (semibold title, full-contrast body) so the
/// feed reads at a glance without any colour-only signal.
struct NotificationRow: View {
    let notification: PRVNotification

    private var isUnread: Bool { !notification.isRead }

    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            NotificationKindIcon(kind: notification.kind, isUnread: isUnread)

            VStack(alignment: .leading, spacing: PRVSpacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: PRVSpacing.xs) {
                    Text(notification.title)
                        .font(.body.weight(isUnread ? .semibold : .medium))
                        .foregroundStyle(Color.prv.textPrimary)
                        .lineLimit(2)

                    Spacer(minLength: PRVSpacing.xxs)

                    Text(NotificationFormat.recency(notification.createdAt))
                        .prvStyle(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Text(notification.body)
                    .font(.subheadline)
                    .foregroundStyle(isUnread ? Color.prv.textPrimary.opacity(0.85) : Color.prv.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let route = notification.route {
                    HStack(spacing: PRVSpacing.xxs) {
                        Text(route.notificationActionTitle)
                            .font(.footnote.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Color.prv.accent)
                    .padding(.top, 1)
                }
            }
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.sm)
        .contentShape(PRVRadius.shape(PRVRadius.lg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if isUnread { parts.append("Unread") }
        parts.append(notification.kind.displayName)
        parts.append(notification.title)
        parts.append(notification.body)
        parts.append(NotificationFormat.spokenTimestamp(notification.createdAt))
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        notification.route.map { "Marks as read and \($0.notificationActionTitle.lowercased())" }
            ?? "Marks as read"
    }
}

/// The tinted glass squircle carrying a notification kind's SF Symbol, with
/// the unread dot pinned to its top trailing corner.
struct NotificationKindIcon: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let kind: PRVNotification.Kind
    var isUnread: Bool = false

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.body.weight(.semibold))
            .foregroundStyle(kind.tint)
            .frame(width: 40, height: 40)
            .background {
                if reduceTransparency {
                    PRVRadius.shape(PRVRadius.sm).fill(kind.tint.opacity(0.22))
                } else {
                    PRVRadius.shape(PRVRadius.sm)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            PRVRadius.shape(PRVRadius.sm).fill(kind.tint.opacity(0.16))
                        }
                }
            }
            .clipShape(PRVRadius.shape(PRVRadius.sm))
            .overlay {
                PRVRadius.shape(PRVRadius.sm)
                    .strokeBorder(kind.tint.opacity(0.28), lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if isUnread {
                    Circle()
                        .fill(Color.prv.accentGradient)
                        .frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(Color.prv.canvas, lineWidth: 2) }
                        .offset(x: 3, y: -3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Sticky header above each time bucket, with the bucket's unread count.
///
/// It pins to the top of the feed while its rows scroll underneath, so it
/// carries its own canvas backdrop rather than letting glass cards slide
/// through the words.
struct NotificationSectionHeader: View {
    let group: NotificationGroup

    var body: some View {
        HStack(spacing: PRVSpacing.xs) {
            Image(systemName: group.section.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.prv.accent)
                .accessibilityHidden(true)

            Text(group.section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.prv.textPrimary)
                .accessibilityAddTraits(.isHeader)

            if group.unreadCount > 0 {
                PRVBadge(count: group.unreadCount, tint: Color.prv.accent)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PRVSpacing.md)
        .padding(.vertical, PRVSpacing.xs)
        .background(Color.prv.canvas)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            group.unreadCount > 0
                ? "\(group.section.title), \(group.unreadCount) unread"
                : group.section.title
        )
    }
}

/// Shimmering stand-in for a notification row while the feed loads.
struct NotificationRowSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: PRVSpacing.sm) {
            PRVSkeleton(width: 40, height: 40, radius: PRVRadius.sm)

            VStack(alignment: .leading, spacing: PRVSpacing.xs) {
                PRVSkeleton(width: 170, height: 15)
                PRVSkeleton(height: 12)
                PRVSkeleton(width: 210, height: 12)
            }

            Spacer(minLength: PRVSpacing.xs)

            PRVSkeleton(width: 34, height: 11)
        }
        .prvGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.sm)
        .accessibilityHidden(true)
    }
}

/// Inline failure surface with a retry affordance.
struct NotificationErrorCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        PRVGlassCard(radius: PRVRadius.lg, padding: PRVSpacing.md) {
            VStack(spacing: PRVSpacing.sm) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
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
    }
}

// MARK: - Previews

#Preview("Notification Rows — Light") {
    ScrollView {
        VStack(spacing: PRVSpacing.xs) {
            NotificationRow(notification: PreviewNotifications.reminder)
            NotificationRow(notification: PreviewNotifications.reward)
            NotificationRow(notification: PreviewNotifications.cancelled)
            NotificationRow(notification: PreviewNotifications.promotion)
            NotificationRowSkeleton()
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
}

#Preview("Notification Rows — Dark") {
    ScrollView {
        VStack(spacing: PRVSpacing.xs) {
            NotificationRow(notification: PreviewNotifications.reminder)
            NotificationRow(notification: PreviewNotifications.waitlist)
            NotificationRow(notification: PreviewNotifications.reward)
        }
        .padding(PRVSpacing.md)
    }
    .background(Color.prv.canvas)
    .preferredColorScheme(.dark)
}

/// Deterministic fixtures for this module's previews. Domain fixtures come
/// from `PreviewData`; only the notification envelopes are local.
enum PreviewNotifications {
    static let reminder = PRVNotification(
        userID: PreviewData.client.id,
        kind: .appointmentReminder,
        title: "Balayage & Gloss on Thursday",
        body: "Your appointment at Maison Lumière is in 3 days at 14:00 with Amélie Dubois.",
        route: .appointment(PreviewData.upcomingAppointment.id),
        createdAt: Date.now.addingTimeInterval(-60 * 24)
    )

    static let reward = PRVNotification(
        userID: PreviewData.client.id,
        kind: .loyaltyReward,
        title: "You reached Gold",
        body: "Priority booking, a birthday ritual, and 15% off colour are now unlocked.",
        route: .loyalty,
        isRead: true,
        createdAt: Date.now.addingTimeInterval(-60 * 60 * 30)
    )

    static let cancelled = PRVNotification(
        userID: PreviewData.client.id,
        kind: .appointmentCancelled,
        title: "Velvet Nails cancelled your visit",
        body: "Noor is unwell. Your prepayment has been refunded in full.",
        route: .salon(PreviewData.salonVelvet.id),
        createdAt: Date.now.addingTimeInterval(-60 * 60 * 24 * 4)
    )

    static let promotion = PRVNotification(
        userID: PreviewData.client.id,
        kind: .promotion,
        title: "Winter gloss, 20% off",
        body: "Maison Lumière is running a seasonal gloss offer until the end of the month.",
        route: .packages(salonID: PreviewData.salonLumiere.id),
        isRead: true,
        createdAt: Date.now.addingTimeInterval(-60 * 60 * 24 * 12)
    )

    static let waitlist = PRVNotification(
        userID: PreviewData.client.id,
        kind: .waitlistSlotOpened,
        title: "A slot just opened",
        body: "Saturday 11:00 with Amélie is free. It usually goes within the hour.",
        route: .booking(
            salonID: PreviewData.salonLumiere.id,
            serviceIDs: [PreviewData.serviceBalayage.id]
        ),
        createdAt: Date.now.addingTimeInterval(-60 * 8)
    )

    static let all: [PRVNotification] = [reminder, waitlist, reward, cancelled, promotion]
}
