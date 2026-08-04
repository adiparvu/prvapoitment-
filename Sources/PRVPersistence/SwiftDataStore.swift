#if canImport(SwiftData)
import Foundation
import PRVFoundation
import PRVModels
import SwiftData

// MARK: - Storage shape
//
// Every cached row is the same three things:
//
//   1. the **encoded domain value** (`payload`),
//   2. the **queryable keys** the offline reads filter on (`id`, `salonID`,
//      `clientID`, a date), and
//   3. **freshness bookkeeping** (`updatedAt` from the domain value,
//      `cachedAt` from the device clock).
//
// Nothing about `Salon`, `Appointment`, or `ClientNote` is mirrored into
// columns. That is deliberate: the cache must never become a second schema
// that has to be migrated every time a domain type gains a field, and a
// lightweight SwiftData migration of eleven near-identical tables is a
// liability nobody should have to think about during a release. Adding a
// property to a domain model is a no-op here; only the *keys* are structural.
//
// The model classes are intentionally `internal`. They are reference types and
// therefore not `Sendable`, so they must never leave the `ModelActor` that
// owns them — the public surface of this module is domain values only.

/// A cached ``Salon`` row. Salons carry no `updatedAt`, so `createdAt` is
/// stored as the freshness key.
@Model
final class CachedSalon {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, updatedAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``SalonService`` row. `salonID` is optional because freelancer
/// services are not attached to a location.
@Model
final class CachedService {
    @Attribute(.unique) var id: UUID
    var salonID: UUID?
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, salonID: UUID?, updatedAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.salonID = salonID
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``Professional`` row.
@Model
final class CachedProfessional {
    @Attribute(.unique) var id: UUID
    var salonID: UUID?
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, salonID: UUID?, updatedAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.salonID = salonID
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``Appointment`` row.
///
/// `startsAt` is denormalised (and never optional) so the salon day view can
/// be answered with a range query instead of decoding the whole table;
/// bookings with no items sort to `.distantPast` rather than disappearing.
@Model
final class CachedAppointment {
    @Attribute(.unique) var id: UUID
    var salonID: UUID
    var clientID: UUID
    var startsAt: Date
    var status: String
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(
        id: UUID,
        salonID: UUID,
        clientID: UUID,
        startsAt: Date,
        status: String,
        updatedAt: Date,
        cachedAt: Date,
        payload: Data
    ) {
        self.id = id
        self.salonID = salonID
        self.clientID = clientID
        self.startsAt = startsAt
        self.status = status
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``Order`` row.
@Model
final class CachedOrder {
    @Attribute(.unique) var id: UUID
    var salonID: UUID
    var clientID: UUID
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, salonID: UUID, clientID: UUID, updatedAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.salonID = salonID
        self.clientID = clientID
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``Conversation`` row. `updatedAt` holds `lastMessageAt` so the
/// chat list can be pruned oldest-first.
@Model
final class CachedConversation {
    @Attribute(.unique) var id: UUID
    var salonID: UUID?
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, salonID: UUID?, updatedAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.salonID = salonID
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``ChatMessage`` row, keyed by conversation for transcript reads.
@Model
final class CachedMessage {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var sentAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, conversationID: UUID, sentAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.conversationID = conversationID
        self.sentAt = sentAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``PRVNotification`` row.
@Model
final class CachedNotification {
    @Attribute(.unique) var id: UUID
    var userID: UUID
    var createdAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, userID: UUID, createdAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.userID = userID
        self.createdAt = createdAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``ClientRecord`` row.
@Model
final class CachedClientRecord {
    @Attribute(.unique) var id: UUID
    var salonID: UUID
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, salonID: UUID, updatedAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.salonID = salonID
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// A cached ``ClientNote`` row.
///
/// Notes are the one read model that also exists *before* the server has seen
/// it: a note written in a basement salon is cached immediately and queued for
/// sync, so the client card reads back correctly while still offline.
@Model
final class CachedClientNote {
    @Attribute(.unique) var id: UUID
    var clientRecordID: UUID
    var createdAt: Date
    var cachedAt: Date
    /// True while the note exists only on this device.
    var isPendingSync: Bool
    var payload: Data

    init(
        id: UUID,
        clientRecordID: UUID,
        createdAt: Date,
        cachedAt: Date,
        isPendingSync: Bool,
        payload: Data
    ) {
        self.id = id
        self.clientRecordID = clientRecordID
        self.createdAt = createdAt
        self.cachedAt = cachedAt
        self.isPendingSync = isPendingSync
        self.payload = payload
    }
}

/// A cached ``LoyaltyProfile`` row, keyed by **user** identifier: a user has
/// exactly one profile, and the widget looks it up by user.
@Model
final class CachedLoyaltyProfile {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    var cachedAt: Date
    var payload: Data

    init(id: UUID, updatedAt: Date, cachedAt: Date, payload: Data) {
        self.id = id
        self.updatedAt = updatedAt
        self.cachedAt = cachedAt
        self.payload = payload
    }
}

/// An arbitrary keyed document — the backing store for the generic
/// ``CacheStore`` protocol (search results, trending lists, feature payloads
/// that have no table of their own).
@Model
final class CachedDocument {
    @Attribute(.unique) var key: String
    var updatedAt: Date
    var payload: Data

    init(key: String, updatedAt: Date, payload: Data) {
        self.key = key
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

/// A persisted ``SyncOperation``.
///
/// The queue survives termination, low-memory kills, and reboots — the whole
/// point of an offline write is that closing the app does not lose it.
@Model
final class QueuedSyncOperation {
    @Attribute(.unique) var id: UUID
    /// Raw value of `SyncOperation.Kind`.
    var kind: String
    /// Backend table name, e.g. `"client_notes"`.
    var entity: String
    var entityID: UUID
    var payload: Data
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?

    init(
        id: UUID,
        kind: String,
        entity: String,
        entityID: UUID,
        payload: Data,
        createdAt: Date,
        attemptCount: Int,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.entity = entity
        self.entityID = entityID
        self.payload = payload
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    /// Projects the row back into the domain value the sync engine works with.
    /// - Returns: `nil` when the stored `kind` is not a known operation kind,
    ///   which can only happen if a newer build wrote the row.
    func operation() -> SyncOperation? {
        guard let parsedKind = SyncOperation.Kind(rawValue: kind) else { return nil }
        return SyncOperation(
            id: SyncOperation.ID(id),
            kind: parsedKind,
            entity: entity,
            entityID: entityID,
            payload: payload,
            createdAt: createdAt,
            attemptCount: attemptCount
        )
    }

    /// Creates a row from a queued operation.
    static func row(for operation: SyncOperation) -> QueuedSyncOperation {
        QueuedSyncOperation(
            id: operation.id.rawValue,
            kind: operation.kind.rawValue,
            entity: operation.entity,
            entityID: operation.entityID,
            payload: operation.payload,
            createdAt: operation.createdAt,
            attemptCount: operation.attemptCount
        )
    }

    /// Copies the mutable fields of an operation onto an existing row.
    func apply(_ operation: SyncOperation) {
        kind = operation.kind.rawValue
        entity = operation.entity
        entityID = operation.entityID
        payload = operation.payload
        attemptCount = operation.attemptCount
    }
}

// MARK: - Container

/// Builds the ``ModelContainer`` the offline cache runs on.
///
/// One container per process, created at launch and handed to
/// ``SwiftDataCacheStore``:
///
/// ```swift
/// let container = try PRVCacheContainer.make()
/// let cache = SwiftDataCacheStore.make(container: container)
/// ```
public enum PRVCacheContainer {
    /// Every model the cache stores.
    static let models: [any PersistentModel.Type] = [
        CachedSalon.self,
        CachedService.self,
        CachedProfessional.self,
        CachedAppointment.self,
        CachedOrder.self,
        CachedConversation.self,
        CachedMessage.self,
        CachedNotification.self,
        CachedClientRecord.self,
        CachedClientNote.self,
        CachedLoyaltyProfile.self,
        CachedDocument.self,
        QueuedSyncOperation.self,
    ]

    /// The cache schema.
    static var schema: Schema { Schema(models) }

    /// Creates the shipping container.
    ///
    /// - Parameter inMemory: `true` for a throwaway store — tests, SwiftUI
    ///   previews, and demo mode, where nothing should touch disk.
    /// - Returns: A container ready to hand to ``SwiftDataCacheStore``.
    /// - Throws: Whatever SwiftData raises when the store cannot be opened.
    public static func make(inMemory: Bool = false) throws -> ModelContainer {
        let cacheSchema = schema
        let configuration = ModelConfiguration(schema: cacheSchema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: cacheSchema, configurations: [configuration])
    }

    /// Creates a container backed by a specific store file — used to put the
    /// cache in the shared app group so extensions can read it.
    ///
    /// A cache is disposable by definition, so an unopenable store is *never*
    /// allowed to take the app down with it: if opening fails (an interrupted
    /// migration, a corrupted file, a downgrade), the store files are deleted
    /// and the container is rebuilt empty. The user loses offline data they
    /// can re-download, instead of losing the app.
    ///
    /// - Parameter url: Location of the `.store` file.
    /// - Returns: A container ready to hand to ``SwiftDataCacheStore``.
    /// - Throws: Only when the store cannot be opened *even after* it was
    ///   discarded and rebuilt.
    public static func make(url: URL) throws -> ModelContainer {
        let cacheSchema = schema
        let configuration = ModelConfiguration(schema: cacheSchema, url: url)
        do {
            let container = try ModelContainer(for: cacheSchema, configurations: [configuration])
            applyFileProtection(at: url)
            return container
        } catch {
            PRVLog.persistence.error("Cache store unreadable, rebuilding it empty")
            discardStore(at: url)
            let container = try ModelContainer(for: cacheSchema, configurations: [configuration])
            applyFileProtection(at: url)
            return container
        }
    }

    /// Deletes a store and its journal side-files.
    private static func discardStore(at url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard manager.fileExists(atPath: path) else { continue }
            do {
                try manager.removeItem(atPath: path)
            } catch {
                PRVLog.persistence.error("Could not remove stale cache file")
            }
        }
    }

    /// Cached appointments and client notes are personal data, so the store is
    /// readable only after the device has been unlocked once since boot —
    /// which is also exactly what a background refresh needs.
    private static func applyFileProtection(at url: URL) {
        #if os(iOS)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            PRVLog.persistence.notice("Cache store file protection could not be set")
        }
        #endif
    }
}
#endif
