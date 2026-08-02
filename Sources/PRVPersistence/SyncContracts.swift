import Foundation
import PRVModels

/// A queued local mutation awaiting server reconciliation. The sync engine
/// replays these against Supabase in order, with server-authoritative
/// resolution for bookings and payments.
public struct SyncOperation: Codable, Hashable, Sendable, Identifiable {
    public typealias ID = PRVID<SyncOperation>

    public enum Kind: String, Codable, Hashable, Sendable {
        case create
        case update
        case delete
    }

    public var id: ID
    public var kind: Kind
    /// Entity table name, e.g. "appointments".
    public var entity: String
    public var entityID: UUID
    /// JSON payload of the mutation.
    public var payload: Data
    public var createdAt: Date
    public var attemptCount: Int

    public init(
        id: ID = ID(),
        kind: Kind,
        entity: String,
        entityID: UUID,
        payload: Data,
        createdAt: Date = .now,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.entity = entity
        self.entityID = entityID
        self.payload = payload
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }
}

public enum SyncState: String, Sendable {
    case idle
    case syncing
    case offline
    case failed
}

/// Offline-first synchronization engine contract. The live implementation
/// persists queued operations with SwiftData and drains them on connectivity,
/// app foreground, and background refresh.
public protocol SyncEngine: Sendable {
    /// Enqueues a local mutation for eventual server delivery.
    func enqueue(_ operation: SyncOperation) async
    /// Drains the queue now; returns the number of operations synced.
    @discardableResult
    func syncNow() async -> Int
    /// Current engine state for UI badges ("Offline — changes will sync").
    func state() async -> SyncState
    /// Pending operations (for diagnostics/settings UI).
    func pendingOperations() async -> [SyncOperation]
}

/// Generic local cache for read models, keyed by entity + id.
public protocol CacheStore: Sendable {
    func read<T: Codable & Sendable>(_ type: T.Type, key: String) async -> T?
    func write<T: Codable & Sendable>(_ value: T, key: String) async
    func remove(key: String) async
    func removeAll() async
}
