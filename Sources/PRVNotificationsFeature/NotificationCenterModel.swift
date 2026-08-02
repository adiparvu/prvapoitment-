import Foundation
import Observation
import PRVDesignSystem
import PRVFoundation
import PRVModels
import PRVNetworking

/// Screen model behind ``NotificationCenterView``.
///
/// Owns the fetched feed, its Today / This Week / Earlier grouping, and the
/// read-state mutations. Reads are applied **optimistically** — the dot
/// disappears the instant the row is tapped — and rolled back with a toast if
/// the repository rejects the write, so the list never lies about what the
/// server knows.
///
/// The grouping is recomputed only when the feed changes, never inside
/// `body`, keeping scrolling at 120 fps on long histories.
@Observable
@MainActor
final class NotificationCenterModel {
    /// Loading lifecycle of the feed.
    enum Phase: Equatable {
        /// First fetch in flight; the screen shows shimmering rows.
        case loading
        /// The feed is on screen (possibly empty).
        case loaded
        /// The first fetch failed with human-readable copy.
        case failed(String)
    }

    private(set) var phase: Phase = .loading

    /// The full feed, newest first.
    private(set) var notifications: [PRVNotification] = []

    /// The feed bucketed into Today / This Week / Earlier.
    private(set) var groups: [NotificationGroup] = []

    /// Unread total, driving the "Mark All Read" affordance and the app badge.
    private(set) var unreadCount = 0

    /// Set after the first successful load; later refreshes keep content on
    /// screen instead of flashing skeletons.
    private(set) var hasLoadedOnce = false

    /// Transient feedback surface.
    var toast: PRVToast?

    /// Whether the per-kind preferences sheet is showing.
    var isShowingPreferences = false

    /// Whether the loaded feed has nothing in it.
    var isEmpty: Bool { notifications.isEmpty }

    // MARK: - Loading

    /// Loads the feed for a user and reconciles local appointment reminders in
    /// the same pass.
    ///
    /// Reminder reconciliation lives here because this module owns the
    /// notification queue: whenever the client looks at their notifications,
    /// the locally scheduled reminders are brought back in line with the
    /// authoritative appointment list (cancelled bookings stop nagging,
    /// rescheduled ones move).
    /// - Parameters:
    ///   - user: The signed-in user, or `nil` for guests.
    ///   - deps: Repository container from the environment.
    func load(for user: User?, using deps: PRVDependencies) async {
        guard let user else {
            notifications = []
            groups = []
            unreadCount = 0
            phase = .loaded
            hasLoadedOnce = true
            return
        }

        if !hasLoadedOnce { phase = .loading }

        async let feedTask = deps.notifications.notifications(userID: user.id)
        async let appointmentsTask = deps.appointments.appointments(clientID: user.id)

        do {
            apply(try await feedTask)
            phase = .loaded
            await PushRegistrar.setBadgeCount(unreadCount)
        } catch {
            let message = Self.friendlyMessage(for: error)
            if notifications.isEmpty {
                phase = .failed(message)
            } else {
                // Keep the stale feed visible; a refresh failure is a nudge,
                // not a wall.
                toast = .error(message)
            }
        }

        // Best-effort: a reminder sweep must never block or fail the screen.
        if let appointments = try? await appointmentsTask {
            await NotificationScheduler.shared.synchronize(with: appointments)
        }

        hasLoadedOnce = true
    }

    // MARK: - Mutations

    /// Marks one notification read, optimistically.
    /// - Parameters:
    ///   - notification: The tapped or swiped notification.
    ///   - deps: Repository container from the environment.
    func markRead(_ notification: PRVNotification, using deps: PRVDependencies) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }),
              !notifications[index].isRead
        else { return }

        notifications[index].isRead = true
        rebuild()

        do {
            try await deps.notifications.markRead(id: notification.id)
            await PushRegistrar.setBadgeCount(unreadCount)
        } catch {
            // Re-resolve the index: the feed may have been refreshed while the
            // write was in flight.
            if let current = notifications.firstIndex(where: { $0.id == notification.id }) {
                notifications[current].isRead = false
                rebuild()
            }
            toast = .error("We couldn't update that notification. Try again.")
        }
    }

    /// Marks the whole feed read, optimistically, restoring the previous state
    /// if the write fails.
    func markAllRead(for user: User?, using deps: PRVDependencies) async {
        guard let user, unreadCount > 0 else { return }

        let previous = notifications
        for index in notifications.indices {
            notifications[index].isRead = true
        }
        rebuild()

        do {
            try await deps.notifications.markAllRead(userID: user.id)
            toast = .success("All caught up")
            await PushRegistrar.setBadgeCount(0)
        } catch {
            notifications = previous
            rebuild()
            toast = .error("We couldn't mark everything as read.")
        }
    }

    // MARK: - Derivation

    /// Replaces the feed and recomputes everything derived from it.
    private func apply(_ fetched: [PRVNotification]) {
        notifications = fetched.sorted { $0.createdAt > $1.createdAt }
        rebuild()
    }

    /// Recomputes grouping and the unread total. Called on every mutation so
    /// `body` only ever reads finished values.
    private func rebuild() {
        groups = NotificationFormat.grouped(notifications)
        unreadCount = notifications.count(where: { !$0.isRead })
    }

    // MARK: - Errors

    /// Maps transport errors to warm, actionable copy — never raw codes.
    nonisolated static func friendlyMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Pull to refresh to try again."
        }
        return switch apiError {
        case .offline, .network:
            "You appear to be offline. Check your connection and pull to refresh."
        case .rateLimited:
            "Too many requests. Give it a moment and pull to refresh."
        case .unauthorized, .forbidden:
            "Please sign in again to see your notifications."
        case .notFound, .conflict, .server, .decoding:
            "We couldn't load your notifications right now. Pull to refresh to try again."
        }
    }
}
