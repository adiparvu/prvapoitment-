import ActivityKit
import Foundation

/// Live Activity contract for an in-flight booking.
///
/// This file is compiled into **both** the app target and the widget
/// extension: the app starts, updates, and ends activities, the widget
/// extension renders them. Nothing here may depend on networking — only
/// Foundation and ActivityKit — so the two targets always agree byte-for-byte
/// on the encoded payload.
///
/// ```swift
/// let attributes = BookingActivityAttributes(
///     salonName: "Maison Lumière",
///     serviceName: "Balayage & Gloss",
///     appointmentID: appointment.id.rawValue
/// )
/// BookingLiveActivityController.start(
///     attributes: attributes,
///     state: .init(
///         statusText: "Confirmed",
///         professionalName: "Amélie Dubois",
///         start: start,
///         end: end
///     )
/// )
/// ```
public struct BookingActivityAttributes: ActivityAttributes {
    /// The part of the activity that changes over its lifetime: the human
    /// status, who is performing the service, and the window the countdown
    /// runs against.
    public struct ContentState: Codable, Hashable, Sendable {
        /// Short, human status shown as the activity's headline chip —
        /// "Confirmed", "Checked in", "In progress", "Running 10 min late".
        public var statusText: String
        /// Display name of the professional performing the service.
        public var professionalName: String
        /// When the appointment begins.
        public var start: Date
        /// When the appointment is expected to end.
        public var end: Date

        /// Creates a content state.
        /// - Parameters:
        ///   - statusText: Short human status ("Confirmed", "In progress").
        ///   - professionalName: Who is performing the service.
        ///   - start: Appointment start.
        ///   - end: Appointment end.
        public init(
            statusText: String,
            professionalName: String,
            start: Date,
            end: Date
        ) {
            self.statusText = statusText
            self.professionalName = professionalName
            self.start = start
            self.end = end
        }

        /// Whether the appointment is currently under way at `now`.
        public func isUnderway(at now: Date = .now) -> Bool {
            now >= start && now < resolvedEnd
        }

        /// Whether the appointment has finished at `now`.
        public func hasFinished(at now: Date = .now) -> Bool {
            now >= resolvedEnd
        }

        /// A range ending at the appointment start, for a
        /// `Text(timerInterval:)` countdown shown *before* the visit begins.
        ///
        /// The lower bound is clamped to `now` so the range is always valid
        /// even if the state arrives late.
        public func countdownToStart(from now: Date = .now) -> ClosedRange<Date> {
            let upper = max(start, now.addingTimeInterval(1))
            return min(now, start)...upper
        }

        /// The appointment window itself, for a `Text(timerInterval:)`
        /// countdown shown *while* the service is happening.
        public var serviceRange: ClosedRange<Date> {
            start...resolvedEnd
        }

        /// The countdown range appropriate for `now`: to the start before the
        /// visit, then through the service itself.
        public func activeCountdownRange(at now: Date = .now) -> ClosedRange<Date> {
            isUnderway(at: now) ? serviceRange : countdownToStart(from: now)
        }

        /// End date guaranteed to sit after `start`, so timer ranges never
        /// invert on malformed data.
        private var resolvedEnd: Date {
            max(end, start.addingTimeInterval(60))
        }
    }

    /// Salon hosting the appointment.
    public var salonName: String
    /// Primary service being performed.
    public var serviceName: String
    /// Raw identifier of the appointment, used to build the deep link and to
    /// find a running activity again.
    public var appointmentID: UUID

    /// Creates the fixed (non-changing) half of a booking activity.
    /// - Parameters:
    ///   - salonName: Salon hosting the appointment.
    ///   - serviceName: Primary service being performed.
    ///   - appointmentID: Raw appointment identifier.
    public init(salonName: String, serviceName: String, appointmentID: UUID) {
        self.salonName = salonName
        self.serviceName = serviceName
        self.appointmentID = appointmentID
    }

    /// `prvbeauty://appointment/<uuid>` — the deep link both the lock-screen
    /// banner and the Dynamic Island open.
    public var deepLinkURL: URL {
        PRVDeepLink.appointment(appointmentID)
    }
}

// MARK: - Deep links

/// Builds the `prvbeauty://` URLs that widgets and Live Activities open.
///
/// Kept here (rather than in the app target) because the widget extension has
/// no access to the app's deep-link handler but must produce identical URLs.
public enum PRVDeepLink {
    /// The app's custom URL scheme.
    public static let scheme = "prvbeauty"

    /// `prvbeauty://appointment/<uuid>`
    public static func appointment(_ id: UUID) -> URL {
        url(host: "appointment", path: id.uuidString)
    }

    /// `prvbeauty://loyalty`
    public static var loyalty: URL { url(host: "loyalty") }

    /// `prvbeauty://wallet`
    public static var wallet: URL { url(host: "wallet") }

    /// `prvbeauty://assistant`
    public static var beautyAssistant: URL { url(host: "assistant") }

    /// `prvbeauty://notifications`
    public static var notifications: URL { url(host: "notifications") }

    private static func url(host: String, path: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let path { components.path = "/\(path)" }
        // The components above are always well-formed; the fallback keeps the
        // API non-optional for call sites in view builders.
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }
}

// MARK: - Lifecycle

/// Starts, updates, and ends booking Live Activities.
///
/// Only the app target ever calls these — the widget extension links this file
/// purely for `BookingActivityAttributes` — but keeping the lifecycle beside
/// the payload guarantees the two stay in step.
///
/// Marked unavailable to app extensions because a Live Activity can only be
/// *requested* from the app itself; the annotation keeps the same file
/// compiling cleanly inside the extension-API-only widget target.
@available(iOSApplicationExtension, unavailable)
@MainActor
public enum BookingLiveActivityController {
    /// Whether the user allows Live Activities for this app.
    public static var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// The running activity for an appointment, if any.
    public static func activity(for appointmentID: UUID) -> Activity<BookingActivityAttributes>? {
        Activity<BookingActivityAttributes>.activities
            .first { $0.attributes.appointmentID == appointmentID }
    }

    /// Starts a booking activity, or updates the existing one when this
    /// appointment already has a live activity.
    /// - Parameters:
    ///   - attributes: Fixed salon/service/appointment information.
    ///   - state: Initial content state.
    ///   - staleDate: When the system should consider the content stale.
    ///     Defaults to one hour past the appointment end.
    /// - Returns: The running activity, or `nil` when Live Activities are
    ///   disabled or the request was rejected.
    @discardableResult
    public static func start(
        attributes: BookingActivityAttributes,
        state: BookingActivityAttributes.ContentState,
        staleDate: Date? = nil
    ) async -> Activity<BookingActivityAttributes>? {
        guard areActivitiesEnabled else { return nil }

        let stale = staleDate ?? state.end.addingTimeInterval(60 * 60)

        if let existing = activity(for: attributes.appointmentID) {
            await existing.update(ActivityContent(state: state, staleDate: stale))
            return existing
        }

        do {
            return try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: stale, relevanceScore: 1),
                pushType: nil
            )
        } catch {
            return nil
        }
    }

    /// Pushes a new content state to a running activity. No-op when the
    /// appointment has no live activity.
    public static func update(
        appointmentID: UUID,
        to state: BookingActivityAttributes.ContentState,
        staleDate: Date? = nil
    ) async {
        guard let activity = activity(for: appointmentID) else { return }
        let stale = staleDate ?? state.end.addingTimeInterval(60 * 60)
        await activity.update(ActivityContent(state: state, staleDate: stale))
    }

    /// Ends a running activity, optionally leaving the final state on the
    /// Lock Screen for a short grace period.
    /// - Parameters:
    ///   - appointmentID: Appointment whose activity should end.
    ///   - finalState: Last state to display; the current state is reused when
    ///     omitted.
    ///   - dismissAfter: How long the ended activity remains visible.
    public static func end(
        appointmentID: UUID,
        with finalState: BookingActivityAttributes.ContentState? = nil,
        dismissAfter: TimeInterval = 5 * 60
    ) async {
        guard let activity = activity(for: appointmentID) else { return }
        let state = finalState ?? activity.content.state
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(.now.addingTimeInterval(dismissAfter))
        )
    }

    /// Ends every running booking activity immediately — used on sign-out.
    public static func endAll() async {
        for activity in Activity<BookingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
