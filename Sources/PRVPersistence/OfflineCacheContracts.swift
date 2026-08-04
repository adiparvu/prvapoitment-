import Foundation
import PRVFoundation
import PRVModels

// The offline layer is split in two on purpose:
//
//   * these contracts — pure Foundation, buildable everywhere (including the
//     Linux domain CI job that compiles this module), and
//   * the SwiftData implementation, which only exists where an Apple SDK does.
//
// Everything above the cache (the sync engine, the caching repository
// decorators, background refresh) talks to the protocols declared here, so the
// storage engine can be swapped — SwiftData on device, `InMemoryOfflineCache`
// in previews, tests, and the Linux build — without touching a call site.

// MARK: - Coding

/// Encodes and decodes the domain values a cache persists as opaque blobs.
///
/// The cache stores *encoded domain values*, never mirrored properties, so the
/// SwiftData schema never constrains the shape of a `PRVModels` type: adding a
/// field to `Appointment` changes no table.
public protocol PersistenceCoding: Sendable {
    /// Encodes a domain value for storage.
    func encode<Value: Encodable>(_ value: Value) throws -> Data
    /// Decodes a domain value read back out of storage.
    func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value
}

/// The default coder for **on-device storage only**: ISO-8601 dates and the
/// models' own camelCase keys.
///
/// It is deliberately symmetric rather than wire-shaped. Cache blobs are
/// written and read by the same coder on the same device, so the local format
/// only has to round-trip; keeping it independent of the backend means a wire
/// format change can never invalidate a user's cache.
///
/// - Important: Payloads that travel to the server — `SyncOperation.payload` —
///   must use the **wire** coder instead (`JSONCoding` in `PRVNetworking`,
///   which maps `salonID → salon_id` through `PRVKeyCase`). That is why every
///   type that builds a `SyncOperation` takes its coder by injection:
///   pass a `PersistenceCoding` adapter over `JSONCoding.encoder` from the
///   composition root, and keep this coder for cache-only work.
public struct PRVLocalJSONCoder: PersistenceCoding {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a coder with ISO-8601 date handling in both directions.
    public init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys make the encoded form of a value deterministic, which is
        // what lets ``PRVCacheKey`` hash a query into a stable cache key.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder = decoder
    }

    public func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try encoder.encode(value)
    }

    public func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decoder.decode(type, from: data)
    }
}

// MARK: - Cached read models

/// Offline browse: the salon catalogue a client can page through with no
/// connection at all.
public protocol SalonCatalogCache: Sendable {
    /// Every cached salon, in no particular order.
    func cachedSalons() async -> [Salon]
    /// One cached salon, or `nil` on a miss.
    func cachedSalon(id: Salon.ID) async -> Salon?
    /// Inserts or replaces the given salons.
    func storeSalons(_ salons: [Salon]) async
    /// Cached services for a salon, matching `SalonRepository.services(salonID:)`.
    func cachedServices(salonID: Salon.ID) async -> [SalonService]
    /// One cached service, or `nil` on a miss.
    func cachedService(id: SalonService.ID) async -> SalonService?
    /// Inserts or replaces the given services.
    func storeServices(_ services: [SalonService]) async
    /// Cached professionals for a salon.
    func cachedProfessionals(salonID: Salon.ID) async -> [Professional]
    /// One cached professional, or `nil` on a miss.
    func cachedProfessional(id: Professional.ID) async -> Professional?
    /// Inserts or replaces the given professionals.
    func storeProfessionals(_ professionals: [Professional]) async
}

/// Offline calendar: "what does my day look like" without a connection.
public protocol AppointmentCache: Sendable {
    /// A client's appointments, ordered exactly like the live repository:
    /// earliest first, group bookings included.
    func cachedAppointments(clientID: User.ID) async -> [Appointment]
    /// A salon's appointments on one calendar day.
    func cachedAppointments(salonID: Salon.ID, on day: Date) async -> [Appointment]
    /// One cached appointment, or `nil` on a miss.
    func cachedAppointment(id: Appointment.ID) async -> Appointment?
    /// Inserts or replaces the given appointments.
    func storeAppointments(_ appointments: [Appointment]) async
}

/// Offline CRM: client cards and treatment notes in a basement salon with no
/// signal, including notes written while offline.
public protocol ClientRecordCache: Sendable {
    /// A salon's client records filtered by the same name search the live
    /// repository applies, sorted by last name.
    func cachedClients(salonID: Salon.ID, searchText: String) async -> [ClientRecord]
    /// One cached client record, or `nil` on a miss.
    func cachedClient(id: ClientRecord.ID) async -> ClientRecord?
    /// Inserts or replaces the given client records.
    func storeClients(_ records: [ClientRecord]) async
    /// A client's notes, newest first.
    func cachedNotes(clientRecordID: ClientRecord.ID) async -> [ClientNote]
    /// Inserts or replaces server-confirmed notes, clearing any pending flag.
    func storeNotes(_ notes: [ClientNote]) async
    /// Inserts or replaces one note, recording whether it still only exists on
    /// this device. CRM can badge pending notes as "will sync".
    func storeNote(_ note: ClientNote, pendingSync: Bool) async
    /// Identifiers of this client's notes that have not reached the server yet.
    func pendingNoteIDs(clientRecordID: ClientRecord.ID) async -> Set<ClientNote.ID>
}

/// Cached orders, so receipts and outstanding balances survive a dead zone.
public protocol OrderCache: Sendable {
    /// A client's orders, newest first.
    func cachedOrders(clientID: User.ID) async -> [Order]
    /// One cached order, or `nil` on a miss.
    func cachedOrder(id: Order.ID) async -> Order?
    /// Inserts or replaces the given orders.
    func storeOrders(_ orders: [Order]) async
}

/// Cached conversations and messages, so chat history opens instantly.
public protocol ConversationCache: Sendable {
    /// A user's conversations, most recent message first.
    func cachedConversations(userID: User.ID) async -> [Conversation]
    /// Inserts or replaces the given conversations.
    func storeConversations(_ conversations: [Conversation]) async
    /// A conversation's messages, oldest first.
    func cachedMessages(conversationID: Conversation.ID) async -> [ChatMessage]
    /// Inserts or replaces the given messages.
    func storeMessages(_ messages: [ChatMessage]) async
}

/// Cached notification centre contents.
public protocol NotificationCache: Sendable {
    /// A user's notifications, newest first.
    func cachedNotifications(userID: User.ID) async -> [PRVNotification]
    /// Inserts or replaces the given notifications.
    func storeNotifications(_ notifications: [PRVNotification]) async
}

/// Cached loyalty standing — the widget renders it with no network at all.
public protocol LoyaltyCache: Sendable {
    /// A user's cached loyalty profile, or `nil` on a miss.
    func cachedLoyaltyProfile(userID: User.ID) async -> LoyaltyProfile?
    /// Inserts or replaces a loyalty profile.
    func storeLoyaltyProfile(_ profile: LoyaltyProfile) async
}

/// Housekeeping every cache has to support so an app that is open for months
/// does not accumulate an unbounded store.
public protocol OfflineCacheMaintenance: Sendable {
    /// Drops time-series rows older than `retention` — past appointments, old
    /// messages, read notifications, stale search documents.
    ///
    /// Reference data (salons, services, professionals, client cards) and
    /// anything in the future is kept: those are what make the app usable
    /// offline in the first place.
    /// - Parameter retention: How far back to keep, in seconds.
    func prune(olderThan retention: TimeInterval) async
}

/// Everything the offline layer expects from a local store: the generic
/// key/value ``CacheStore`` plus the typed read models.
///
/// `SwiftDataCacheStore` is the shipping implementation;
/// ``InMemoryOfflineCache`` is the preview/test/Linux one.
public typealias OfflineCache = CacheStore
    & SalonCatalogCache
    & AppointmentCache
    & ClientRecordCache
    & OrderCache
    & ConversationCache
    & NotificationCache
    & LoyaltyCache
    & OfflineCacheMaintenance

// MARK: - Sync queue storage

/// Durable storage for the queue of local mutations awaiting the server.
///
/// Split out of ``SyncEngine`` so `PRVSyncEngine` stays a pure state machine:
/// it can be exercised against an in-memory queue in tests and runs against
/// SwiftData on device.
public protocol SyncOperationStore: Sendable {
    /// Appends an operation to the tail of the queue.
    func append(_ operation: SyncOperation) async
    /// Every stored operation, oldest `createdAt` first.
    func pending() async -> [SyncOperation]
    /// Persists a changed operation (attempt count) together with the reason
    /// the last attempt failed, for the diagnostics screen. Inserts the
    /// operation if it is no longer stored, so a drain never loses work.
    func update(_ operation: SyncOperation, lastError: String?) async
    /// Removes a delivered, discarded, or superseded operation.
    func remove(id: SyncOperation.ID) async
    /// Clears the queue (sign-out, account deletion).
    ///
    /// Deliberately *not* named `removeAll()`: a store can back both this
    /// protocol and ``CacheStore``, and wiping unsent user writes whenever the
    /// read cache is cleared would silently destroy work.
    func removeAllOperations() async
}

// MARK: - Cache key vocabulary

/// Canonical keys for the generic ``CacheStore``.
///
/// Keys are namespaced `"<entity>/<scope>"` so a targeted invalidation can be
/// written without guessing, and so two features never collide on a key.
public enum PRVCacheKey {
    /// Key for the salon list backing a search query, hashed to keep the key
    /// short and stable across launches.
    public static func salonSearch(_ query: SalonSearchQuery) -> String {
        "salons/search/\(stableHash(of: query))"
    }

    /// Key for the trending salon list.
    public static let trendingSalons = "salons/trending"

    /// Key for a user's recently viewed salon identifiers.
    public static func recentlyViewed(userID: User.ID) -> String {
        "salons/recently-viewed/\(userID.rawValue.uuidString)"
    }

    /// A deterministic, launch-stable hash of an encodable value.
    ///
    /// `Hasher` is seeded per process, so it cannot produce a key that must
    /// survive a relaunch; this folds the value's canonical (sorted-key) JSON
    /// with FNV-1a instead.
    static func stableHash(of value: some Encodable) -> String {
        // The description fallback keeps two different values on two different
        // keys even if one of them refuses to encode.
        let data = (try? PRVCacheKey.keyCoder.encode(value)) ?? Data(String(describing: value).utf8)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }

    private static let keyCoder = PRVLocalJSONCoder()
}

// MARK: - Shared read semantics

/// The filtering and ordering rules a cached read must reproduce.
///
/// `InMemoryBackend` is the reference implementation of every repository, so
/// an offline read has to answer exactly what the live one would. Keeping the
/// rules here — rather than inside each store — means the SwiftData store and
/// the in-memory store can never drift apart, and a fix lands once.
enum PRVCacheSemantics {
    /// Client appointments: own bookings plus group bookings they were added
    /// to, earliest first.
    static func appointments(_ all: [Appointment], clientID: User.ID) -> [Appointment] {
        all
            .filter { $0.clientID == clientID || $0.additionalClientIDs.contains(clientID) }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    /// Salon appointments on one calendar day.
    ///
    /// The live repository returns these in storage order; the cache returns
    /// them chronologically, which is what every caller (day timeline, widget)
    /// sorts into anyway.
    static func appointments(_ all: [Appointment], salonID: Salon.ID, on day: Date) -> [Appointment] {
        all
            .filter { $0.salonID == salonID && ($0.start?.isSameDay(as: day) ?? false) }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }

    /// Salon client records, name-searched and sorted by last name.
    static func clients(_ all: [ClientRecord], salonID: Salon.ID, searchText: String) -> [ClientRecord] {
        var results = all.filter { $0.salonID == salonID }
        if !searchText.isBlank {
            let needle = searchText.lowercased()
            results = results.filter { $0.fullName.lowercased().contains(needle) }
        }
        return results.sorted { $0.lastName < $1.lastName }
    }

    /// Treatment notes, newest first.
    static func notes(_ all: [ClientNote], clientRecordID: ClientRecord.ID) -> [ClientNote] {
        all
            .filter { $0.clientRecordID == clientRecordID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Services offered by one salon.
    static func services(_ all: [SalonService], salonID: Salon.ID) -> [SalonService] {
        all.filter { $0.salonID == salonID }
    }

    /// Professionals working at one salon.
    static func professionals(_ all: [Professional], salonID: Salon.ID) -> [Professional] {
        all.filter { $0.salonID == salonID }
    }

    /// Client orders, newest first.
    static func orders(_ all: [Order], clientID: User.ID) -> [Order] {
        all
            .filter { $0.clientID == clientID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Conversations a user participates in, most recent activity first.
    static func conversations(_ all: [Conversation], userID: User.ID) -> [Conversation] {
        all
            .filter { $0.participantIDs.contains(userID) }
            .sorted { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
    }

    /// Messages in a conversation, oldest first.
    static func messages(_ all: [ChatMessage], conversationID: Conversation.ID) -> [ChatMessage] {
        all
            .filter { $0.conversationID == conversationID }
            .sorted { $0.sentAt < $1.sentAt }
    }

    /// A user's notifications, newest first.
    static func notifications(_ all: [PRVNotification], userID: User.ID) -> [PRVNotification] {
        all
            .filter { $0.userID == userID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The freshness key stored alongside a cached appointment.
    static func freshness(of appointment: Appointment) -> Date { appointment.updatedAt }

    /// The chronological key stored alongside a cached appointment. Bookings
    /// with no items sort to the far past rather than being dropped.
    static func startKey(of appointment: Appointment) -> Date { appointment.start ?? .distantPast }
}
