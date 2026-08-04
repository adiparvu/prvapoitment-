import Foundation
import PRVFoundation
import PRVModels

/// The live ``NotificationRepository``, backed by the `notifications` and
/// `device_tokens` tables.
///
/// Notifications are created by the platform — `notify-fanout` and the database
/// triggers in `0003_functions_triggers.sql` — and never by a device:
/// `notifications` has `SELECT`, `UPDATE`, and `DELETE` policies scoped to
/// `auth.uid()` and deliberately no `INSERT` policy, so an app can read its own
/// inbox and mark it read, and nothing else.
///
/// `route` is stored as `jsonb` in exactly the shape Swift synthesizes for
/// `AppRoute`, so a notification deep-links without the client re-deriving a
/// destination from its text.
public struct SupabaseNotificationRepository: NotificationRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows the inbox returns.
    private static let listLimit = 200

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Inbox

    /// The user's notifications, newest first.
    public func notifications(userID: User.ID) async throws -> [PRVNotification] {
        let request = PostgRESTQuery("notifications")
            .filter(.equals("user_id", userID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [NotificationRow] = try await client.select(request)
        return try rows.map(Self.makeNotification)
    }

    /// Marks one notification read.
    ///
    /// A notification that does not exist — or belongs to somebody else, which
    /// RLS makes the same thing — updates nothing and is not an error. That is
    /// what `InMemoryBackend` does, and what a notification tapped twice needs,
    /// so no single row is demanded of the response.
    public func markRead(id: PRVNotification.ID) async throws {
        _ = try await client.update(
            "notifications",
            values: NotificationReadUpdate(isRead: true, readAt: SupabaseTimestamp.string(from: .now)),
            filters: [.equals("id", id.rawValue)],
            returning: "id",
            singleRow: false,
            as: [NotificationIdentifierRow].self
        )
    }

    /// Marks every unread notification read.
    ///
    /// Already-read rows are excluded by the filter rather than rewritten, so
    /// `read_at` keeps recording when a notification was first seen instead of
    /// when the inbox was last opened. The end state is identical to marking all
    /// of them.
    public func markAllRead(userID: User.ID) async throws {
        _ = try await client.update(
            "notifications",
            values: NotificationReadUpdate(isRead: true, readAt: SupabaseTimestamp.string(from: .now)),
            filters: [.equals("user_id", userID.rawValue), .isTrue("is_read", false)],
            returning: "id",
            singleRow: false,
            as: [NotificationIdentifierRow].self
        )
    }

    // MARK: - Devices

    /// Registers this device's push token for the user.
    ///
    /// `device_tokens` is unique on the token, so this is an upsert resolved on
    /// that index rather than a blind insert: re-registering the same token on
    /// every launch updates the row in place instead of colliding with it, and a
    /// token that moves to another account on the same device follows the
    /// account. `created_at` survives; `last_seen_at` advances.
    ///
    /// The bundle identifier, locale, and sandbox flag travel with it because
    /// APNs needs all three to choose a topic and an environment, and the device
    /// is the only place that knows them.
    public func registerDeviceToken(_ token: String, userID: User.ID) async throws {
        let payload = DeviceTokenUpsert(
            token: token,
            userID: userID.rawValue,
            platform: Self.platform,
            bundleID: Bundle.main.bundleIdentifier,
            locale: Locale.current.identifier,
            isSandbox: Self.isSandboxBuild,
            lastSeenAt: SupabaseTimestamp.string(from: .now)
        )
        _ = try await client.upsert(
            into: "device_tokens",
            values: payload,
            onConflict: "token",
            returning: "id",
            as: DeviceTokenIdentifierRow.self
        )
    }

    /// The `device_platform` value this build registers under.
    private static let platform = "ios"

    /// Whether this build talks to the APNs sandbox.
    private static var isSandboxBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - Row mapping

    private static func makeNotification(_ row: NotificationRow) throws -> PRVNotification {
        PRVNotification(
            id: PRVNotification.ID(row.id),
            userID: User.ID(row.userID),
            kind: PRVNotification.Kind(rawValue: row.kind) ?? .system,
            title: row.title,
            body: row.body,
            route: row.route,
            isRead: row.isRead,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }
}

// MARK: - Rows

extension SupabaseNotificationRepository {
    /// A `notifications` row.
    ///
    /// `route` decodes straight into ``AppRoute`` because the column stores the
    /// synthesized `Codable` shape — one key naming the case, positional values
    /// keyed `_0` — which `JSONCoding.decoder` reads back unchanged.
    fileprivate struct NotificationRow: Decodable, Sendable {
        let id: UUID
        let userID: UUID
        let kind: String
        let title: String
        let body: String
        let route: AppRoute?
        let isRead: Bool
        let createdAt: String
    }

    /// The identifier PostgREST echoes back from a `notifications` write.
    fileprivate struct NotificationIdentifierRow: Decodable, Sendable {
        let id: UUID
    }

    /// The identifier PostgREST echoes back from a `device_tokens` write.
    fileprivate struct DeviceTokenIdentifierRow: Decodable, Sendable {
        let id: UUID
    }
}

// MARK: - Payloads

extension SupabaseNotificationRepository {
    /// Marks a notification read, stamping when.
    fileprivate struct NotificationReadUpdate: Encodable, Sendable {
        let isRead: Bool
        let readAt: String
    }

    /// A push registration, merged onto the unique `token` index.
    fileprivate struct DeviceTokenUpsert: Encodable, Sendable {
        let token: String
        let userID: UUID
        let platform: String
        let bundleID: String?
        let locale: String
        let isSandbox: Bool
        let lastSeenAt: String
    }
}
