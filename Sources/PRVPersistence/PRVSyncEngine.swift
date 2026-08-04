import Foundation
import PRVFoundation
import PRVModels
#if canImport(Network)
import Network
#endif

// MARK: - Entities

/// Backend table names a ``SyncOperation`` can target.
///
/// These are the real Supabase table names from `0001_schema.sql`, kept in one
/// place so a queued operation, the conflict policy, and the sender that posts
/// it can never disagree about what `"client_notes"` means.
public enum SyncEntity {
    /// `appointments` — bookings. Server-authoritative.
    public static let appointments = "appointments"
    /// `waitlist_entries` — waitlist requests. Server-authoritative.
    public static let waitlistEntries = "waitlist_entries"
    /// `orders` — checkout totals. Server-authoritative.
    public static let orders = "orders"
    /// `refunds`. Server-authoritative.
    public static let refunds = "refunds"
    /// `invoices`. Server-authoritative.
    public static let invoices = "invoices"
    /// `gift_cards`. Server-authoritative.
    public static let giftCards = "gift_cards"
    /// `wallet_transactions`. Server-authoritative.
    public static let walletTransactions = "wallet_transactions"
    /// `membership_subscriptions`. Server-authoritative.
    public static let membershipSubscriptions = "membership_subscriptions"
    /// `client_records` — CRM client cards.
    public static let clientRecords = "client_records"
    /// `client_notes` — treatment notes and colour formulas.
    public static let clientNotes = "client_notes"
    /// `consent_forms` — signed consent documents.
    public static let consentForms = "consent_forms"
    /// `reviews`.
    public static let reviews = "reviews"
    /// `messages` — chat.
    public static let messages = "messages"
    /// `products` — inventory.
    public static let products = "products"
    /// `shifts` — rota.
    public static let shifts = "shifts"
    /// `time_entries` — clock in/out.
    public static let timeEntries = "time_entries"
}

/// Which entities the server owns outright.
///
/// ARCHITECTURE.md §6: reconciliation is last-write-wins **except** for
/// bookings and payments, which are server-authoritative. The reason is not
/// stylistic — a slot can be taken and money can move while a device is in a
/// basement, and no local edit may be allowed to overwrite that. For those
/// entities a conflict means the local operation is *dropped*, not retried.
public struct SyncConflictPolicy: Sendable {
    /// Entity names the server always wins for.
    public var serverAuthoritativeEntities: Set<String>

    /// Creates a policy.
    /// - Parameter serverAuthoritativeEntities: Table names the server owns.
    public init(serverAuthoritativeEntities: Set<String>) {
        self.serverAuthoritativeEntities = serverAuthoritativeEntities
    }

    /// Bookings and everything that touches money.
    public static let `default` = SyncConflictPolicy(serverAuthoritativeEntities: [
        SyncEntity.appointments,
        SyncEntity.waitlistEntries,
        SyncEntity.orders,
        SyncEntity.refunds,
        SyncEntity.invoices,
        SyncEntity.giftCards,
        SyncEntity.walletTransactions,
        SyncEntity.membershipSubscriptions,
    ])

    /// Whether the server's version wins for `entity`.
    public func isServerAuthoritative(_ entity: String) -> Bool {
        serverAuthoritativeEntities.contains(entity)
    }
}

// MARK: - Transport contract

/// One delivery attempt handed to the injected sender.
public struct SyncAttempt: Sendable {
    /// The operation to deliver, including its current attempt count.
    public var operation: SyncOperation
    /// `true` when a previous attempt hit a conflict on a last-write-wins
    /// entity and the engine ruled that the local write is the newer one.
    ///
    /// The sender should then overwrite unconditionally — drop the
    /// `If-Unmodified-Since` precondition, or send `Prefer: resolution=merge-duplicates`
    /// on the PostgREST upsert — instead of repeating a request the server has
    /// already refused.
    public var overwritesServerVersion: Bool

    /// Creates an attempt.
    public init(operation: SyncOperation, overwritesServerVersion: Bool = false) {
        self.operation = operation
        self.overwritesServerVersion = overwritesServerVersion
    }
}

/// What the server did with one attempt.
///
/// The sender classifies the transport outcome — `PRVPersistence` deliberately
/// does not import `PRVNetworking`, so `APIError` is mapped **at the boundary**:
/// `.conflict` → ``conflict``, `.rateLimited`/`.server`/`.network` →
/// ``retryable(reason:)``, `.offline` → ``offline``, `.unauthorized`/`.forbidden`/
/// `.notFound`/`.decoding` → ``rejected(reason:)``.
public enum SyncSendResult: Sendable {
    /// Accepted. `serverPayload` carries the canonical row when the endpoint
    /// returned one (PostgREST `Prefer: return=representation`), so the cache
    /// can be refreshed with the server's own copy.
    case delivered(serverPayload: Data?)
    /// The server holds a competing version. `serverPayload` is that version,
    /// when the response included it.
    case conflict(serverPayload: Data?)
    /// The operation can never succeed (unauthorised, malformed, the row is
    /// gone). It is dropped so it cannot block the queue forever.
    case rejected(reason: String)
    /// A transient failure — 429, 5xx, a dropped connection. Worth retrying.
    case retryable(reason: String)
    /// There is no usable connection right now. The drain stops and resumes on
    /// the next connectivity change.
    case offline
}

/// Delivers one queued operation to the backend.
///
/// Injected rather than imported: the engine stays a pure state machine, the
/// networking module owns URLs, auth, and error mapping, and tests drive the
/// engine with a closure.
public typealias SyncSender = @Sendable (SyncAttempt) async -> SyncSendResult

/// The server's canonical version of a row, handed back for cache refresh.
public struct SyncServerVersion: Sendable {
    /// Backend table the row belongs to.
    public var entity: String
    /// Row identifier.
    public var entityID: UUID
    /// Encoded row exactly as the server returned it.
    public var payload: Data
    /// `true` when this version replaced a local change that was discarded
    /// under the server-authoritative rule — the UI may want to tell the user
    /// their edit did not stick.
    public var replacedLocalChange: Bool

    /// Creates a server version record.
    public init(entity: String, entityID: UUID, payload: Data, replacedLocalChange: Bool) {
        self.entity = entity
        self.entityID = entityID
        self.payload = payload
        self.replacedLocalChange = replacedLocalChange
    }
}

/// Applies a server-canonical row — normally by decoding it and writing it
/// into the offline cache.
public typealias SyncServerVersionHandler = @Sendable (SyncServerVersion) async -> Void

// MARK: - Reachability

/// Connectivity as the sync engine needs it: a current answer plus a stream of
/// changes.
public protocol ReachabilityMonitoring: Sendable {
    /// Begins monitoring. Idempotent.
    func start() async
    /// Whether a network path is currently available.
    func isOnline() async -> Bool
    /// Online/offline transitions, starting with the current value. The stream
    /// finishes when the consumer stops iterating.
    func onlineChanges() -> AsyncStream<Bool>
}

#if canImport(Network)
/// `NWPathMonitor`-backed reachability.
///
/// `NWPathMonitor` predates Swift Concurrency and still delivers updates to a
/// `DispatchQueue`. That single queue is the only GCD in this module: the
/// callback immediately reduces `NWPath` to a `Bool` and hops onto this actor,
/// so no `NWPath` and no queue ever escapes.
public actor NetworkPathReachability: ReachabilityMonitoring {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var isStarted = false
    private var online: Bool
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Creates a monitor. It is optimistic until the first path update
    /// arrives: assuming online means the first request is actually attempted
    /// rather than being pre-emptively queued on a healthy connection.
    public init() {
        monitor = NWPathMonitor()
        queue = DispatchQueue(label: "com.prv.beauty.reachability", qos: .utility)
        online = true
    }

    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = Self.pathHandler(for: self)
        monitor.start(queue: queue)
    }

    public func isOnline() async -> Bool {
        await start()
        return online
    }

    public nonisolated func onlineChanges() -> AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id) }
            }
            Task { await self.addObserver(id, continuation: continuation) }
        }
    }

    /// Stops monitoring and finishes every observer stream.
    ///
    /// Terminal for this instance: `NWPathMonitor` cannot be restarted once
    /// cancelled, so build a new monitor if monitoring is needed again.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.cancel()
        for continuation in observers.values { continuation.finish() }
        observers.removeAll()
    }

    /// Built in a `nonisolated` context so the escaping callback is plainly
    /// `@Sendable` and captures nothing but a weak reference to the actor.
    private nonisolated static func pathHandler(
        for reachability: NetworkPathReachability
    ) -> @Sendable (NWPath) -> Void {
        { [weak reachability] path in
            let satisfied = path.status == .satisfied
            Task { await reachability?.apply(online: satisfied) }
        }
    }

    private func addObserver(_ id: UUID, continuation: AsyncStream<Bool>.Continuation) async {
        observers[id] = continuation
        await start()
        continuation.yield(online)
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func apply(online newValue: Bool) {
        guard newValue != online else { return }
        online = newValue
        PRVLog.sync.notice("Connectivity changed: \(newValue ? "online" : "offline", privacy: .public)")
        for continuation in observers.values {
            continuation.yield(newValue)
        }
    }
}
#endif

/// Reachability that always reports a connection.
///
/// Used where `Network.framework` does not exist (the Linux domain build) and
/// in tests that drive the engine's failure paths through the sender instead.
public struct AlwaysOnlineReachability: ReachabilityMonitoring {
    /// Creates the monitor.
    public init() {}

    public func start() async {}

    public func isOnline() async -> Bool { true }

    public func onlineChanges() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
            continuation.finish()
        }
    }
}

/// The process-wide reachability monitor.
public enum PRVReachability {
    /// One `NWPathMonitor` per process — creating several is pure overhead.
    public static let system: any ReachabilityMonitoring = {
        #if canImport(Network)
        return NetworkPathReachability()
        #else
        return AlwaysOnlineReachability()
        #endif
    }()
}

// MARK: - Engine

/// The offline-first sync engine.
///
/// Local mutations are queued as ``SyncOperation`` values and replayed against
/// the backend in `createdAt` order. Ordering is the whole contract: a note
/// created offline and then edited must reach the server in that sequence.
///
/// Failure handling:
///
/// * transient failures retry with exponential backoff plus jitter,
/// * after `maxAttempts` the operation is **parked** — kept for the
///   diagnostics screen, skipped by later drains so it cannot wedge the queue,
///   and the engine reports ``SyncState/failed`` until ``retryFailed()`` or a
///   fresh connection clears it,
/// * operations the server will never accept are dropped immediately.
///
/// Conflicts follow ARCHITECTURE.md §6: last-write-wins in general (retry with
/// `overwritesServerVersion`), server-authoritative for bookings and payments
/// (the local operation is discarded and the server's row replaces it).
///
/// ```swift
/// let engine = PRVSyncEngine(store: cache, applyServerVersion: cache.applyServerVersion) { attempt in
///     await supabase.deliver(attempt)
/// }
/// await engine.startAutomaticSync()
/// ```
public actor PRVSyncEngine: SyncEngine {
    /// Retry and conflict tuning.
    public struct Configuration: Sendable {
        /// How many times one operation may be attempted before it is parked.
        public var maxAttempts: Int
        /// Delay before the second attempt, in seconds; doubles from there.
        public var baseBackoff: TimeInterval
        /// Ceiling for the backoff delay, in seconds.
        public var maxBackoff: TimeInterval
        /// Random spread applied to each delay, as a fraction of it, so a fleet
        /// of devices coming back online together does not stampede.
        public var jitterFraction: Double
        /// Which entities the server owns.
        public var conflictPolicy: SyncConflictPolicy

        /// Creates a configuration. The defaults give five attempts spread over
        /// roughly half an hour.
        public init(
            maxAttempts: Int = 5,
            baseBackoff: TimeInterval = 2,
            maxBackoff: TimeInterval = 300,
            jitterFraction: Double = 0.2,
            conflictPolicy: SyncConflictPolicy = .default
        ) {
            self.maxAttempts = max(1, maxAttempts)
            self.baseBackoff = max(0, baseBackoff)
            self.maxBackoff = max(0, maxBackoff)
            self.jitterFraction = min(max(0, jitterFraction), 1)
            self.conflictPolicy = conflictPolicy
        }
    }

    /// Outcome of delivering one operation.
    private enum Delivery {
        case delivered
        case discarded
        case exhausted
        case offline
        case cancelled
    }

    private let store: any SyncOperationStore
    private let reachability: any ReachabilityMonitoring
    private let configuration: Configuration
    private let applyServerVersion: SyncServerVersionHandler
    private let send: SyncSender
    private var isDraining = false
    private var lastDrainFailed = false
    private var connectivityTask: Task<Void, Never>?

    /// Creates an engine.
    /// - Parameters:
    ///   - store: Durable queue storage — `SwiftDataCacheStore` on device,
    ///     ``InMemoryOfflineCache`` in previews and tests.
    ///   - reachability: Connectivity source. Defaults to the shared
    ///     `NWPathMonitor`.
    ///   - configuration: Retry and conflict tuning.
    ///   - applyServerVersion: Writes a server-canonical row back into the
    ///     cache. Defaults to ignoring it.
    ///   - send: Delivers one attempt to the backend.
    public init(
        store: any SyncOperationStore,
        reachability: any ReachabilityMonitoring = PRVReachability.system,
        configuration: Configuration = Configuration(),
        applyServerVersion: @escaping SyncServerVersionHandler = { _ in },
        send: @escaping SyncSender
    ) {
        self.store = store
        self.reachability = reachability
        self.configuration = configuration
        self.applyServerVersion = applyServerVersion
        self.send = send
    }

    // MARK: - SyncEngine

    public func enqueue(_ operation: SyncOperation) async {
        await store.append(operation)
        PRVLog.sync.notice(
            "Queued \(operation.kind.rawValue, privacy: .public) on \(operation.entity, privacy: .public)"
        )
    }

    @discardableResult
    public func syncNow() async -> Int {
        // Re-entrancy guard: a foreground drain and a background-refresh drain
        // must never interleave and deliver the same operation twice.
        guard !isDraining else { return 0 }
        isDraining = true
        defer { isDraining = false }

        guard await reachability.isOnline() else {
            PRVLog.sync.notice("Sync deferred: no connection")
            return 0
        }

        var delivered = 0
        var parked = false

        for operation in await store.pending() {
            if Task.isCancelled { break }
            // Parked operations are skipped, not retried: a permanently
            // failing note must not hold up everything queued behind it. The
            // queue is last-write-wins, so a later write to the same row is
            // still the truth.
            guard operation.attemptCount < configuration.maxAttempts else {
                parked = true
                continue
            }

            switch await deliver(operation) {
            case .delivered:
                delivered += 1
            case .discarded:
                continue
            case .exhausted:
                parked = true
            case .offline:
                PRVLog.sync.notice("Sync paused: connection lost mid-drain")
                lastDrainFailed = parked
                return delivered
            case .cancelled:
                lastDrainFailed = parked
                return delivered
            }
        }

        lastDrainFailed = parked
        if delivered > 0 {
            PRVLog.sync.notice("Synced \(delivered) queued operation(s)")
        }
        return delivered
    }

    public func state() async -> SyncState {
        if isDraining { return .syncing }
        guard await reachability.isOnline() else { return .offline }
        return lastDrainFailed ? .failed : .idle
    }

    public func pendingOperations() async -> [SyncOperation] {
        await store.pending()
    }

    // MARK: - Lifecycle

    /// Drains whenever connectivity returns, and once immediately.
    ///
    /// Call at app launch. Idempotent.
    public func startAutomaticSync() {
        guard connectivityTask == nil else { return }
        let changes = reachability.onlineChanges()
        connectivityTask = Task { [weak self] in
            for await isOnline in changes {
                guard let self else { return }
                guard isOnline else { continue }
                // A new network path is a genuine reason to believe parked
                // work can succeed now.
                await self.retryFailed()
                await self.syncNow()
            }
        }
    }

    /// Stops the connectivity-driven drain (sign-out, teardown).
    public func stopAutomaticSync() {
        connectivityTask?.cancel()
        connectivityTask = nil
    }

    /// Un-parks every operation that hit the attempt cap so the next drain
    /// tries them again.
    /// - Returns: How many operations were reset.
    @discardableResult
    public func retryFailed() async -> Int {
        var reset = 0
        for operation in await store.pending() where operation.attemptCount >= configuration.maxAttempts {
            var revived = operation
            revived.attemptCount = 0
            await store.update(revived, lastError: nil)
            reset += 1
        }
        if reset > 0 {
            PRVLog.sync.notice("Reset \(reset) parked operation(s) for another attempt")
        }
        lastDrainFailed = false
        return reset
    }

    /// Discards the whole queue. Only for sign-out and account deletion —
    /// this destroys work the user believes is saved.
    public func discardQueue() async {
        await store.removeAllOperations()
        lastDrainFailed = false
    }

    // MARK: - Delivery

    private func deliver(_ operation: SyncOperation) async -> Delivery {
        var current = operation
        var overwritesServerVersion = false

        while current.attemptCount < configuration.maxAttempts {
            if Task.isCancelled { return .cancelled }

            let attempt = SyncAttempt(
                operation: current,
                overwritesServerVersion: overwritesServerVersion
            )

            switch await send(attempt) {
            case .delivered(let serverPayload):
                if let serverPayload {
                    await applyServerVersion(
                        SyncServerVersion(
                            entity: current.entity,
                            entityID: current.entityID,
                            payload: serverPayload,
                            replacedLocalChange: false
                        )
                    )
                }
                await store.remove(id: current.id)
                return .delivered

            case .conflict(let serverPayload):
                if configuration.conflictPolicy.isServerAuthoritative(current.entity) {
                    // Bookings and payments: the server is the record of
                    // truth. Take its version, drop ours, never retry.
                    if let serverPayload {
                        await applyServerVersion(
                            SyncServerVersion(
                                entity: current.entity,
                                entityID: current.entityID,
                                payload: serverPayload,
                                replacedLocalChange: true
                            )
                        )
                    }
                    await store.remove(id: current.id)
                    PRVLog.sync.notice(
                        "Server version wins for \(current.entity, privacy: .public); local change discarded"
                    )
                    return .discarded
                }
                // Last-write-wins: ours is the later write, so re-send it as
                // an unconditional overwrite instead of repeating a request
                // the server has already refused.
                overwritesServerVersion = true
                current.attemptCount += 1
                await store.update(current, lastError: "Conflict; retrying as overwrite")
                if current.attemptCount < configuration.maxAttempts {
                    guard await backOff(beforeAttempt: current.attemptCount) else { return .cancelled }
                }

            case .retryable(let reason):
                current.attemptCount += 1
                await store.update(current, lastError: reason)
                if current.attemptCount < configuration.maxAttempts {
                    guard await backOff(beforeAttempt: current.attemptCount) else { return .cancelled }
                }

            case .rejected(let reason):
                await store.remove(id: current.id)
                PRVLog.sync.error(
                    "Dropping \(current.entity, privacy: .public) operation the server refuses: \(reason, privacy: .public)"
                )
                return .discarded

            case .offline:
                return .offline
            }
        }

        PRVLog.sync.error(
            "Parking \(current.entity, privacy: .public) operation after \(current.attemptCount) attempts"
        )
        return .exhausted
    }

    /// Sleeps for this attempt's exponential, jittered delay.
    /// - Returns: `false` when the task was cancelled while waiting.
    private func backOff(beforeAttempt attempt: Int) async -> Bool {
        let exponent = Double(max(0, attempt - 1))
        let capped = min(configuration.maxBackoff, configuration.baseBackoff * pow(2, exponent))
        let jitter = capped * configuration.jitterFraction
        let delay = max(0, capped + Double.random(in: -jitter ... jitter))
        do {
            try await Task.sleep(for: .seconds(delay))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Applying the server's version

/// Writes a server-canonical row into the offline cache.
///
/// This is the second half of the server-authoritative rule: discarding the
/// local operation is only correct if the device then *shows* what the server
/// actually has. Hand ``handler()`` to `PRVSyncEngine(applyServerVersion:)` and
/// a booking that lost a race is replaced on screen by the booking that won.
///
/// ```swift
/// let applier = CacheServerVersionApplier(cache: cache, coder: wireCoder)
/// let engine = PRVSyncEngine(store: cache, applyServerVersion: applier.handler()) { ... }
/// ```
public struct CacheServerVersionApplier: Sendable {
    private let cache: any OfflineCache
    private let coder: any PersistenceCoding

    /// Creates an applier.
    /// - Parameters:
    ///   - cache: The offline store to update.
    ///   - coder: Coder matching the **wire** format, because the payload came
    ///     from the server — pass an adapter over `JSONCoding` from
    ///     `PRVNetworking`.
    public init(cache: any OfflineCache, coder: any PersistenceCoding) {
        self.cache = cache
        self.coder = coder
    }

    /// The handler to hand to ``PRVSyncEngine``.
    public func handler() -> SyncServerVersionHandler {
        let applier = self
        return { version in
            await applier.apply(version)
        }
    }

    /// Decodes one server row and stores it.
    ///
    /// Unknown entities are ignored: a table that has no cached read model
    /// simply has nothing to refresh.
    public func apply(_ version: SyncServerVersion) async {
        switch version.entity {
        case SyncEntity.appointments:
            guard let value: Appointment = decode(version.payload, as: Appointment.self) else { return }
            await cache.storeAppointments([value])
        case SyncEntity.orders:
            guard let value: Order = decode(version.payload, as: Order.self) else { return }
            await cache.storeOrders([value])
        case SyncEntity.clientRecords:
            guard let value: ClientRecord = decode(version.payload, as: ClientRecord.self) else { return }
            await cache.storeClients([value])
        case SyncEntity.clientNotes:
            guard let value: ClientNote = decode(version.payload, as: ClientNote.self) else { return }
            // Server-confirmed: the note is no longer pending.
            await cache.storeNotes([value])
        case SyncEntity.messages:
            guard let value: ChatMessage = decode(version.payload, as: ChatMessage.self) else { return }
            await cache.storeMessages([value])
        default:
            PRVLog.sync.notice(
                "No cached read model for \(version.entity, privacy: .public); server version not stored"
            )
        }
    }

    private func decode<Value: Decodable>(_ data: Data, as type: Value.Type) -> Value? {
        do {
            return try coder.decode(type, from: data)
        } catch {
            PRVLog.sync.error("Could not decode the server's version: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
