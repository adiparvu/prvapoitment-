import Foundation
import Observation
import UserNotifications
import PRVFoundation
import PRVModels
import PRVNetworking
#if canImport(UIKit)
import UIKit
#endif

/// Owns everything between the user and APNs: authorization, remote
/// registration, device-token forwarding, and decoding the route a tapped
/// push should open.
///
/// The app target drives it from its scene lifecycle and its
/// `UIApplicationDelegate` shims:
///
/// ```swift
/// @State private var push = PushRegistrar()
///
/// .task {
///     await push.requestProvisionalAuthorization()   // quiet by default
///     push.registerForRemoteNotifications()
/// }
///
/// // From application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
/// await push.didRegisterForRemoteNotifications(
///     deviceToken: token, userID: user.id, using: deps
/// )
///
/// // From userNotificationCenter(_:didReceive:)
/// if let route = push.route(for: response.notification.request.content.userInfo) {
///     router.open(route)
/// }
/// ```
///
/// PRV Beauty asks **provisionally** first — notifications land silently in
/// Notification Centre with no permission prompt at all — and only escalates
/// to a full prompt once the client has felt the value (from the notification
/// preferences sheet, or after their first booking).
@Observable
@MainActor
public final class PushRegistrar {
    /// The app's view of the system authorization state.
    public enum Authorization: String, Hashable, Sendable, CaseIterable {
        /// The user has neither been asked nor granted provisional delivery.
        case notDetermined
        /// Quiet delivery: notifications arrive without banners or sound.
        case provisional
        /// Full delivery with banners, sounds, and badges.
        case authorized
        /// The user declined, or turned notifications off in Settings.
        case denied

        /// Whether the system will deliver anything at all.
        public var allowsDelivery: Bool {
            self == .authorized || self == .provisional
        }

        /// Whether an interruptive prompt can still be shown.
        public var canRequestFullAuthorization: Bool {
            self == .notDetermined || self == .provisional
        }
    }

    /// Current system authorization, refreshed on demand.
    public private(set) var authorization: Authorization = .notDetermined

    /// The APNs device token, hex-encoded, once the system has issued one.
    public private(set) var deviceToken: String?

    /// Human description of the last registration failure, for diagnostics
    /// surfaces. `nil` while everything is healthy.
    public private(set) var lastError: String?

    /// Creates a registrar. Reading the live authorization state is an async
    /// call, so kick it off with ``refreshAuthorization()`` in a `.task`.
    public init() {}

    // MARK: - Authorization

    /// Category identifier attached to locally scheduled appointment
    /// reminders and to server-sent reminder pushes.
    public nonisolated static let appointmentCategoryIdentifier = "PRV_APPOINTMENT"

    /// Category identifier for chat message pushes.
    public nonisolated static let messageCategoryIdentifier = "PRV_MESSAGE"

    /// The APNs payload key carrying the JSON-encoded `AppRoute`.
    public nonisolated static let routePayloadKey = "route"

    /// Reads the live system settings into ``authorization``.
    public func refreshAuthorization() async {
        authorization = Self.authorization(for: await Self.currentAuthorizationStatus())
    }

    /// Requests **provisional** authorization: no prompt, quiet delivery.
    ///
    /// Safe to call on every launch — the system ignores it once a decision
    /// exists.
    /// - Returns: The authorization state after the request.
    @discardableResult
    public func requestProvisionalAuthorization() async -> Authorization {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return authorization }

        _ = await Self.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
        registerCategories()
        await refreshAuthorization()
        return authorization
    }

    /// Escalates to full authorization with the system prompt (banners,
    /// sounds, badges).
    ///
    /// Call this from an explicit user action — never on launch.
    /// - Returns: The authorization state after the request.
    @discardableResult
    public func requestFullAuthorization() async -> Authorization {
        await refreshAuthorization()
        guard authorization.canRequestFullAuthorization else { return authorization }

        let granted = await Self.requestAuthorization(options: [.alert, .sound, .badge])
        registerCategories()
        await refreshAuthorization()

        if granted {
            registerForRemoteNotifications()
        }
        return authorization
    }

    /// Registers the actionable categories the platform sends.
    ///
    /// Idempotent — the system replaces the whole set each time.
    public func registerCategories() {
        let appointment = UNNotificationCategory(
            identifier: Self.appointmentCategoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: "PRV_APPOINTMENT_VIEW",
                    title: "View Booking",
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: "PRV_APPOINTMENT_DIRECTIONS",
                    title: "Directions",
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        let message = UNNotificationCategory(
            identifier: Self.messageCategoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: "PRV_MESSAGE_OPEN",
                    title: "Reply",
                    options: [.foreground]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([appointment, message])
    }

    // MARK: - Remote registration

    /// Asks the system for an APNs device token.
    ///
    /// The token itself arrives on the app delegate; forward it with
    /// ``didRegisterForRemoteNotifications(deviceToken:userID:using:)``.
    public func registerForRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Stops remote delivery — used when a user signs out of the device.
    public func unregisterFromRemoteNotifications() {
        #if canImport(UIKit)
        UIApplication.shared.unregisterForRemoteNotifications()
        #endif
        deviceToken = nil
    }

    /// Hex-encodes the raw APNs token and forwards it to the backend so the
    /// user's devices can be addressed.
    /// - Parameters:
    ///   - deviceToken: Raw token from the app delegate.
    ///   - userID: The signed-in user the token belongs to.
    ///   - deps: Repository container from the environment.
    public func didRegisterForRemoteNotifications(
        deviceToken: Data,
        userID: User.ID,
        using deps: PRVDependencies
    ) async {
        let hex = Self.hexEncoded(deviceToken)
        self.deviceToken = hex
        lastError = nil

        do {
            try await deps.notifications.registerDeviceToken(hex, userID: userID)
            PRVLog.app.info("Registered APNs device token for user \(userID.description, privacy: .private)")
        } catch {
            lastError = "We couldn't register this device for notifications."
            PRVLog.app.error("Device token registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Records a failed APNs registration. Non-fatal: in-app notifications and
    /// locally scheduled reminders keep working.
    public func didFailToRegisterForRemoteNotifications(with error: any Error) {
        deviceToken = nil
        lastError = "This device couldn't register for push notifications."
        PRVLog.app.error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    /// Re-sends the cached token, e.g. after a user signs in on a device that
    /// already registered.
    public func syncDeviceToken(userID: User.ID, using deps: PRVDependencies) async {
        guard let deviceToken else { return }
        try? await deps.notifications.registerDeviceToken(deviceToken, userID: userID)
    }

    // MARK: - Routing

    /// Decodes the destination carried by a notification payload.
    ///
    /// The backend attaches the app's own `AppRoute` encoding under a `route`
    /// key, either as a nested JSON object or as a JSON string:
    ///
    /// ```json
    /// { "aps": { … }, "route": { "appointment": { "_0": "0B1E…" } } }
    /// { "aps": { … }, "route": "{\"loyalty\":{}}" }
    /// ```
    ///
    /// - Parameter userInfo: The push payload, or a local notification's
    ///   `content.userInfo`.
    /// - Returns: The route to open, or `nil` when the payload carries none
    ///   (or one this build doesn't understand — forward compatibility).
    public nonisolated func route(for userInfo: [AnyHashable: Any]) -> AppRoute? {
        Self.route(for: userInfo)
    }

    /// Payload-decoding half of ``route(for:)``, usable without an instance
    /// (notification-service extensions, tests).
    public nonisolated static func route(for userInfo: [AnyHashable: Any]) -> AppRoute? {
        guard let raw = userInfo[routePayloadKey] else { return nil }
        guard let data = jsonData(from: raw) else { return nil }
        return try? JSONDecoder().decode(AppRoute.self, from: data)
    }

    /// Encodes a route for inclusion in a notification payload. Used by the
    /// local reminder scheduler so taps route exactly like remote pushes.
    public nonisolated static func routePayload(for route: AppRoute) -> String? {
        guard let data = try? JSONEncoder().encode(route) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func jsonData(from raw: Any) -> Data? {
        if let data = raw as? Data { return data }
        if let string = raw as? String { return string.data(using: .utf8) }
        guard JSONSerialization.isValidJSONObject(raw) else { return nil }
        return try? JSONSerialization.data(withJSONObject: raw)
    }

    // MARK: - Badge

    /// Mirrors the unread notification count onto the app icon badge.
    ///
    /// Failures are silent: a stale badge must never surface an error to the
    /// user.
    public static func setBadgeCount(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in
                continuation.resume()
            }
        }
    }

    // MARK: - UserNotifications bridging

    // The completion-handler APIs are bridged explicitly rather than using
    // their async spellings: the continuation extracts a `Sendable` value
    // (a status, a `Bool`) inside the callback, so no UserNotifications
    // reference ever crosses an isolation boundary.

    private static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private static func requestAuthorization(options: UNAuthorizationOptions) async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
                if let error {
                    PRVLog.app.error("Notification authorization failed: \(String(describing: error), privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    private static func authorization(for status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .authorized
        @unknown default: .notDetermined
        }
    }

    private nonisolated static func hexEncoded(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
