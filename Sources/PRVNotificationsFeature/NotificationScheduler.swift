import Foundation
import UserNotifications
import PRVFoundation
import PRVModels

/// Schedules — and reliably cancels — the local reminders that fire before an
/// appointment.
///
/// Two reminders per booking: a calm one the day before (24 hours out) and a
/// time-sensitive one two hours out. Both are `UNCalendarNotificationTrigger`s
/// so they survive app termination, reboots, and time-zone changes, and both
/// carry the same JSON `route` payload a remote push would, so
/// ``PushRegistrar/route(for:)`` handles the tap identically either way.
///
/// Identifiers are derived from the appointment ID, which makes every
/// operation idempotent: re-scheduling replaces, cancelling removes, and a
/// reconciliation pass can sweep reminders whose appointment disappeared.
///
/// ```swift
/// // After booking or rescheduling:
/// await NotificationScheduler.shared.scheduleReminders(for: appointment)
///
/// // After cancelling:
/// NotificationScheduler.shared.cancelReminders(for: appointment.id)
///
/// // After any appointment list refresh:
/// await NotificationScheduler.shared.synchronize(with: appointments)
/// ```
@MainActor
public final class NotificationScheduler {
    /// Shared scheduler. The notification queue is a process-wide resource,
    /// so a single owner keeps identifier bookkeeping honest.
    public static let shared = NotificationScheduler()

    /// How far ahead of the appointment a reminder fires.
    public enum Lead: Int, CaseIterable, Sendable {
        /// The evening-before nudge, 24 hours out.
        case dayBefore = 1_440
        /// The "leave soon" nudge, 2 hours out.
        case twoHours = 120

        /// Minutes before the appointment start.
        public var minutes: Int { rawValue }

        /// Stable suffix used in the notification identifier.
        var identifierSuffix: String {
            switch self {
            case .dayBefore: "24h"
            case .twoHours: "2h"
            }
        }

        /// Time-critical reminders are allowed to break through Focus when the
        /// app carries the time-sensitive entitlement.
        var interruptionLevel: UNNotificationInterruptionLevel {
            switch self {
            case .dayBefore: .active
            case .twoHours: .timeSensitive
            }
        }

        /// Relevance ranking inside a notification summary.
        var relevanceScore: Double {
            switch self {
            case .dayBefore: 0.6
            case .twoHours: 1.0
            }
        }
    }

    /// Prefix shared by every reminder this scheduler owns, so a sweep can
    /// tell PRV reminders apart from anything else in the queue.
    public nonisolated static let identifierPrefix = "prv.appointment."

    /// Thread identifier that groups all of one appointment's reminders in
    /// Notification Centre.
    public nonisolated static func threadIdentifier(for appointmentID: Appointment.ID) -> String {
        identifierPrefix + appointmentID.rawValue.uuidString
    }

    /// Creates a scheduler. Prefer ``shared``; the initializer stays public
    /// for tests that want an isolated instance.
    public init() {}

    // MARK: - Identifiers

    /// The notification identifier for one appointment/lead pair.
    public func identifier(for appointmentID: Appointment.ID, lead: Lead) -> String {
        "\(Self.identifierPrefix)\(appointmentID.rawValue.uuidString).\(lead.identifierSuffix)"
    }

    /// Every identifier this scheduler could own for an appointment.
    public func identifiers(for appointmentID: Appointment.ID) -> [String] {
        Lead.allCases.map { identifier(for: appointmentID, lead: $0) }
    }

    // MARK: - Scheduling

    /// Schedules both reminders for an appointment, replacing any that already
    /// exist.
    ///
    /// Nothing is scheduled — and anything already queued is removed — when
    /// the appointment is cancelled or completed, when it has no start time,
    /// when the user silenced appointment reminders, or when the lead time has
    /// already passed.
    /// - Parameters:
    ///   - appointment: The appointment to remind about.
    ///   - now: Reference time; injectable for tests.
    /// - Returns: The identifiers actually queued.
    @discardableResult
    public func scheduleReminders(
        for appointment: Appointment,
        now: Date = .now
    ) async -> [String] {
        // Re-scheduling is a replace, never an append.
        cancelReminders(for: appointment.id)

        guard NotificationPreferences.isEnabled(.appointmentReminder) else { return [] }
        guard appointment.status.isActive, let start = appointment.start else { return [] }

        var scheduled: [String] = []
        for lead in Lead.allCases {
            let fireDate = start.addingTimeInterval(TimeInterval(-lead.minutes * 60))
            guard fireDate > now else { continue }

            let request = UNNotificationRequest(
                identifier: identifier(for: appointment.id, lead: lead),
                content: content(for: appointment, start: start, lead: lead),
                trigger: Self.trigger(at: fireDate)
            )

            if await Self.add(request) {
                scheduled.append(request.identifier)
            }
        }

        PRVLog.booking.debug(
            "Scheduled \(scheduled.count, privacy: .public) reminder(s) for appointment \(appointment.id.description, privacy: .private)"
        )
        return scheduled
    }

    /// Removes both reminders for an appointment, pending and already
    /// delivered. Call this the moment a booking is cancelled.
    public func cancelReminders(for appointmentID: Appointment.ID) {
        let ids = identifiers(for: appointmentID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Removes every reminder this scheduler owns, leaving notifications from
    /// other sources untouched. Used on sign-out and when the client silences
    /// appointment reminders.
    public func cancelAllReminders() async {
        let ids = await pendingReminderIdentifiers()
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Reconciles the notification queue with the authoritative appointment
    /// list: schedules what should exist, cancels what should not, and sweeps
    /// reminders whose appointment is no longer in the list at all (deleted
    /// server-side, or belonging to a signed-out account).
    /// - Parameters:
    ///   - appointments: Every appointment currently known for the user.
    ///   - now: Reference time; injectable for tests.
    public func synchronize(with appointments: [Appointment], now: Date = .now) async {
        let expected = Set(
            appointments
                .filter { $0.status.isActive }
                .flatMap { identifiers(for: $0.id) }
        )

        let orphans = await pendingReminderIdentifiers().filter { !expected.contains($0) }
        if !orphans.isEmpty {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: orphans)
        }

        for appointment in appointments {
            await scheduleReminders(for: appointment, now: now)
        }
    }

    /// Identifiers of the reminders this scheduler currently has queued.
    public func pendingReminderIdentifiers() async -> [String] {
        let prefix = Self.identifierPrefix
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(
                    returning: requests
                        .map(\.identifier)
                        .filter { $0.hasPrefix(prefix) }
                )
            }
        }
    }

    // MARK: - Content

    /// Builds the reminder body. Copy is warm and specific — the service, the
    /// salon, the time, and who the client is seeing.
    private func content(
        for appointment: Appointment,
        start: Date,
        lead: Lead
    ) -> UNMutableNotificationContent {
        let service = appointment.items
            .sorted { $0.start < $1.start }
            .first?
            .serviceName ?? "Your appointment"
        let professional = appointment.items.compactMap(\.professionalName).first
        let time = start.formatted(date: .omitted, time: .shortened)

        let content = UNMutableNotificationContent()
        switch lead {
        case .dayBefore:
            content.title = "Tomorrow: \(service)"
            content.body = professional.map {
                "\(appointment.salonName) at \(time) with \($0)."
            } ?? "\(appointment.salonName) at \(time)."
        case .twoHours:
            content.title = "\(service) in 2 hours"
            content.body = "\(appointment.salonName) at \(time). Time to head over."
        }

        content.sound = .default
        content.categoryIdentifier = PushRegistrar.appointmentCategoryIdentifier
        content.threadIdentifier = Self.threadIdentifier(for: appointment.id)
        content.interruptionLevel = lead.interruptionLevel
        content.relevanceScore = lead.relevanceScore

        // Same payload shape a remote push carries, so taps route through
        // exactly one code path.
        if let payload = PushRegistrar.routePayload(for: .appointment(appointment.id)) {
            content.userInfo = [PushRegistrar.routePayloadKey: payload]
        }

        return content
    }

    // MARK: - UserNotifications bridging

    /// Calendar triggers survive reboots and follow the user's time zone,
    /// which interval triggers do not.
    private nonisolated static func trigger(at date: Date) -> UNCalendarNotificationTrigger {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    /// Adds a request, mapping failure to `false` — a reminder that cannot be
    /// queued is logged, never surfaced.
    private static func add(_ request: UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    PRVLog.booking.error(
                        "Failed to schedule reminder: \(String(describing: error), privacy: .public)"
                    )
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }
}
