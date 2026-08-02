import Foundation
import PRVFoundation
import PRVModels

/// The three time buckets the notification centre groups into.
///
/// Buckets are computed from the calendar rather than from raw intervals so
/// "Today" always means today in the user's own time zone.
enum NotificationSection: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case today
    case thisWeek
    case earlier

    var id: Int { rawValue }

    /// Header title shown above the section.
    var title: String {
        switch self {
        case .today: "Today"
        case .thisWeek: "This Week"
        case .earlier: "Earlier"
        }
    }

    /// SF Symbol accompanying the header.
    var symbolName: String {
        switch self {
        case .today: "sun.max.fill"
        case .thisWeek: "calendar"
        case .earlier: "archivebox.fill"
        }
    }
}

/// One rendered section of the notification centre.
struct NotificationGroup: Identifiable, Hashable, Sendable {
    let section: NotificationSection
    var items: [PRVNotification]

    var id: Int { section.id }

    /// Unread notifications inside this bucket, for the header count.
    var unreadCount: Int { items.count(where: { !$0.isRead }) }
}

/// Date bucketing and human-facing time strings for the notification centre.
///
/// Pure, `nonisolated`, and fully deterministic given an explicit `now` — so
/// the grouping rules can be unit tested without freezing the clock.
enum NotificationFormat {
    /// The bucket a notification belongs to.
    /// - Parameters:
    ///   - date: When the notification was created.
    ///   - now: The reference "now".
    ///   - calendar: Calendar used for day/week boundaries.
    static func section(
        for date: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> NotificationSection {
        // Clock skew can produce timestamps slightly in the future; they read
        // as the freshest thing the user has.
        if date > now || date.isSameDay(as: now, calendar: calendar) { return .today }

        let weekStart = calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)

        return date >= weekStart ? .thisWeek : .earlier
    }

    /// Buckets notifications into Today / This Week / Earlier, newest first
    /// within each bucket. Empty buckets are dropped entirely.
    static func grouped(
        _ notifications: [PRVNotification],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [NotificationGroup] {
        let sorted = notifications.sorted { $0.createdAt > $1.createdAt }
        let buckets = Dictionary(grouping: sorted) {
            section(for: $0.createdAt, now: now, calendar: calendar)
        }
        return NotificationSection.allCases.compactMap { section in
            guard let items = buckets[section], !items.isEmpty else { return nil }
            return NotificationGroup(section: section, items: items)
        }
    }

    /// Compact recency shown at the trailing edge of a row: "Just now",
    /// "3 hr ago", then an absolute date once past a week.
    static func recency(_ date: Date, now: Date = .now) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Just now" }
        if elapsed < 60 * 60 * 24 * 7 {
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Fully spelled-out timestamp for VoiceOver, where abbreviations read
    /// poorly ("3 hr ago" → "3 hours ago").
    static func spokenTimestamp(_ date: Date, now: Date = .now) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 60 * 60 * 24 * 7 {
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Route affordances

extension AppRoute {
    /// The call-to-action shown on a notification row that carries a deep
    /// link, e.g. "View appointment".
    var notificationActionTitle: String {
        switch self {
        case .salon: "View salon"
        case .professional: "View professional"
        case .service: "View service"
        case .booking: "Book now"
        case .appointment: "View appointment"
        case .checkout: "Complete payment"
        case .conversation: "Open chat"
        case .beautyAssistant: "Ask the assistant"
        case .wallet: "Open wallet"
        case .loyalty: "View rewards"
        case .memberships: "View memberships"
        case .packages: "View packages"
        case .giftCards: "View gift cards"
        case .notifications: "View notifications"
        case .reviews: "View reviews"
        case .clientRecord: "Open client"
        case .settings: "Open settings"
        }
    }
}
