import Foundation
#if canImport(FoundationNetworking)
// `URLError`/`NSURLErrorDomain` live in a separate module off-Apple, where this
// module is built by the domain CI job.
import FoundationNetworking
#endif
import PRVFoundation
import PRVModels

// MARK: - Why these three
//
// Offline support is not free: every decorated read needs a cache shape, an
// invalidation story, and a background refresh that cannot stampede. It is
// therefore applied where losing the network actually breaks a real workflow,
// and nowhere else.
//
//   * **Salons, services, professionals** — browsing is the top of every
//     funnel and the data is public, slow-changing, and small. A client in a
//     metro tunnel keeps browsing; a stale price is corrected on the next
//     refresh, seconds later.
//   * **Appointments (read)** — "what does my day look like" is the single
//     most-opened screen for both clients and staff, and it must work in a
//     basement salon. Reads only: booking, cancelling, and rescheduling are
//     server-authoritative (ARCHITECTURE.md §6) because a slot can be taken
//     while a device is offline, so an optimistic local booking would be a
//     promise the platform cannot keep.
//   * **CRM clients and notes** — the one place an *offline write* is both
//     safe and necessary. A colourist writes the formula at the chair, often
//     with no signal, and the note is theirs alone: nobody else is editing it,
//     so last-write-wins is exactly right. Notes queue as `SyncOperation`s and
//     the client card reads them back immediately.
//
// Left deliberately direct (no decorator):
//
//   * **Payments, orders, refunds, gift cards** — money is created by Edge
//     Functions against Stripe. Queuing a payment offline would risk double
//     charges and show balances that do not exist.
//   * **Availability and booking mutations** — a cached slot list is a wrong
//     answer with a confident face.
//   * **Chat sends** — messaging already has its own delivery state machine
//     (`ChatMessage.DeliveryState`) and a live stream; a second queue would
//     fight it. Transcripts are still *cached* for instant opens.
//   * **Analytics, marketing, inventory, team** — back-office screens used at
//     a desk on Wi-Fi; the cache would cost more than it returns.
//   * **Auth** — session restore is Keychain-backed, not cache-backed.

// MARK: - Live-side contracts

/// The part of `SalonRepository` worth serving from a cache.
///
/// Signatures are copied verbatim from the repository protocol, so the live
/// Supabase repository conforms with an empty extension in the networking
/// module and the decorator drops straight in:
///
/// ```swift
/// extension SupabaseSalonRepository: SalonCatalogFetching {}
/// let catalog = CachingSalonCatalog(live: supabaseSalons, cache: cache)
/// ```
///
/// `PRVPersistence` cannot import `PRVNetworking` (ARCHITECTURE.md §3), which
/// is why the subset is restated here rather than referenced.
public protocol SalonCatalogFetching: Sendable {
    /// Salons matching a search query.
    func searchSalons(_ query: SalonSearchQuery) async throws -> [Salon]
    /// One salon.
    func salon(id: Salon.ID) async throws -> Salon
    /// The trending list.
    func trendingSalons() async throws -> [Salon]
    /// A salon's service menu.
    func services(salonID: Salon.ID) async throws -> [SalonService]
    /// One service.
    func service(id: SalonService.ID) async throws -> SalonService
    /// A salon's team.
    func professionals(salonID: Salon.ID) async throws -> [Professional]
    /// One professional.
    func professional(id: Professional.ID) async throws -> Professional
}

/// The read side of `AppointmentRepository`.
public protocol AppointmentBookFetching: Sendable {
    /// A client's appointments.
    func appointments(clientID: User.ID) async throws -> [Appointment]
    /// A salon's appointments on one day.
    func appointments(salonID: Salon.ID, on day: Date) async throws -> [Appointment]
    /// One appointment.
    func appointment(id: Appointment.ID) async throws -> Appointment
}

/// The part of `CRMRepository` that has to work in a basement.
public protocol ClientRecordFetching: Sendable {
    /// A salon's client records, name-searched.
    func clients(salonID: Salon.ID, searchText: String) async throws -> [ClientRecord]
    /// One client record.
    func client(id: ClientRecord.ID) async throws -> ClientRecord
    /// A client's notes.
    func notes(clientRecordID: ClientRecord.ID) async throws -> [ClientNote]
    /// Adds a note.
    func addNote(_ note: ClientNote) async throws -> ClientNote
}

// MARK: - Offline error classification

/// Decides whether a failed request means "no connection" — the one case where
/// a write may be queued instead of surfaced.
///
/// `APIError` lives in `PRVNetworking`, which this module does not import, so
/// classification is injected. The composition root should widen the default:
///
/// ```swift
/// let classifier = OfflineErrorClassifier { error in
///     if case APIError.offline = error { return true }
///     if case APIError.network = error { return true }
///     return OfflineErrorClassifier.default.isOffline(error)
/// }
/// ```
public struct OfflineErrorClassifier: Sendable {
    private let predicate: @Sendable (any Error) -> Bool

    /// Wraps a predicate.
    public init(_ predicate: @escaping @Sendable (any Error) -> Bool) {
        self.predicate = predicate
    }

    /// Whether `error` means the device could not reach the backend.
    public func isOffline(_ error: any Error) -> Bool {
        predicate(error)
    }

    /// Recognises URL loading system connectivity failures.
    ///
    /// Cancellation is explicitly *not* offline: a cancelled request means the
    /// user navigated away, and queuing a write for that would be wrong.
    public static let `default` = OfflineErrorClassifier { error in
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return false }
        return OfflineErrorClassifier.offlineURLErrorCodes.contains(urlError.code.rawValue)
    }

    /// URL loading system codes that mean "there is no usable connection".
    /// Compared as raw values so the set is spelled the same way on every
    /// platform this module is built for.
    private static let offlineURLErrorCodes: Set<Int> = [
        -1_001, // timed out
        -1_003, // cannot find host
        -1_004, // cannot connect to host
        -1_005, // network connection lost
        -1_009, // not connected to the internet
        -1_018, // international roaming off
        -1_019, // call is active
        -1_020, // data not allowed
    ]
}

// MARK: - Background refresh coordination

/// De-duplicates and throttles the background refreshes a cache-first read
/// fires off.
///
/// Without this, scrolling a list of twenty salons would launch twenty
/// requests for the same rows, and a `List` that re-renders would launch them
/// again. One refresh per key is in flight at a time, and a key that refreshed
/// recently is left alone.
actor RefreshCoordinator {
    private let minimumInterval: TimeInterval
    private var inFlight: Set<String> = []
    private var lastRefreshed: [String: Date] = [:]

    /// Creates a coordinator.
    /// - Parameter minimumInterval: How long a key stays fresh after a
    ///   successful refresh.
    init(minimumInterval: TimeInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    /// Starts `operation` unless the key is already refreshing or still fresh.
    ///
    /// Returns as soon as the work is scheduled: the caller has already
    /// answered from cache and must not wait on the network.
    ///
    /// A failed refresh is logged, not propagated — the read it belongs to
    /// already succeeded — and still starts the throttle window, so a backend
    /// that is down cannot turn every scroll into a retry storm.
    func schedule(key: String, operation: @escaping @Sendable () async throws -> Void) {
        guard !inFlight.contains(key) else { return }
        if let last = lastRefreshed[key], Date.now.timeIntervalSince(last) < minimumInterval {
            return
        }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            do {
                try await operation()
            } catch is CancellationError {
                // The screen went away; nothing to report.
            } catch {
                PRVLog.persistence.notice(
                    "Background refresh failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            await self.complete(key)
        }
    }

    /// Clears the throttle for a key, e.g. after an explicit pull-to-refresh.
    func invalidate(key: String) {
        lastRefreshed.removeValue(forKey: key)
    }

    private func complete(_ key: String) {
        inFlight.remove(key)
        lastRefreshed[key] = .now
    }
}

// MARK: - Salon catalogue

/// Offline-first salon browsing.
///
/// Every read answers from the cache when it can and refreshes behind the
/// user's back; a cold cache falls through to the network and warms it. The
/// decorator never invents data: a miss with no connection throws exactly what
/// the live repository threw.
public struct CachingSalonCatalog: SalonCatalogFetching {
    private let live: any SalonCatalogFetching
    private let cache: any OfflineCache
    private let refresh: RefreshCoordinator

    /// Wraps a live catalogue.
    /// - Parameters:
    ///   - live: The Supabase-backed repository.
    ///   - cache: The offline store.
    ///   - refreshInterval: How long a background refresh keeps a key fresh.
    public init(
        live: any SalonCatalogFetching,
        cache: any OfflineCache,
        refreshInterval: TimeInterval = 60
    ) {
        self.live = live
        self.cache = cache
        self.refresh = RefreshCoordinator(minimumInterval: refreshInterval)
    }

    public func searchSalons(_ query: SalonSearchQuery) async throws -> [Salon] {
        let key = PRVCacheKey.salonSearch(query)
        if let cached: [Salon] = await cache.read([Salon].self, key: key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.searchSalons(query)
                await cache.write(fresh, key: key)
                await cache.storeSalons(fresh)
            }
            return cached
        }
        let fresh = try await live.searchSalons(query)
        await cache.write(fresh, key: key)
        await cache.storeSalons(fresh)
        return fresh
    }

    public func salon(id: Salon.ID) async throws -> Salon {
        if let cached = await cache.cachedSalon(id: id) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: "salons/\(id.rawValue.uuidString)") {
                let fresh = try await live.salon(id: id)
                await cache.storeSalons([fresh])
            }
            return cached
        }
        let fresh = try await live.salon(id: id)
        await cache.storeSalons([fresh])
        return fresh
    }

    public func trendingSalons() async throws -> [Salon] {
        let key = PRVCacheKey.trendingSalons
        if let cached: [Salon] = await cache.read([Salon].self, key: key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.trendingSalons()
                await cache.write(fresh, key: key)
                await cache.storeSalons(fresh)
            }
            return cached
        }
        let fresh = try await live.trendingSalons()
        await cache.write(fresh, key: key)
        await cache.storeSalons(fresh)
        return fresh
    }

    public func services(salonID: Salon.ID) async throws -> [SalonService] {
        let key = "services/salon/\(salonID.rawValue.uuidString)"
        if await hasFetched(key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.services(salonID: salonID)
                await cache.storeServices(fresh)
                await cache.write(Date.now, key: key)
            }
            return await cache.cachedServices(salonID: salonID)
        }
        let fresh = try await live.services(salonID: salonID)
        await cache.storeServices(fresh)
        await cache.write(Date.now, key: key)
        return fresh
    }

    public func service(id: SalonService.ID) async throws -> SalonService {
        if let cached = await cache.cachedService(id: id) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: "services/\(id.rawValue.uuidString)") {
                let fresh = try await live.service(id: id)
                await cache.storeServices([fresh])
            }
            return cached
        }
        let fresh = try await live.service(id: id)
        await cache.storeServices([fresh])
        return fresh
    }

    public func professionals(salonID: Salon.ID) async throws -> [Professional] {
        let key = "professionals/salon/\(salonID.rawValue.uuidString)"
        if await hasFetched(key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.professionals(salonID: salonID)
                await cache.storeProfessionals(fresh)
                await cache.write(Date.now, key: key)
            }
            return await cache.cachedProfessionals(salonID: salonID)
        }
        let fresh = try await live.professionals(salonID: salonID)
        await cache.storeProfessionals(fresh)
        await cache.write(Date.now, key: key)
        return fresh
    }

    public func professional(id: Professional.ID) async throws -> Professional {
        if let cached = await cache.cachedProfessional(id: id) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: "professionals/\(id.rawValue.uuidString)") {
                let fresh = try await live.professional(id: id)
                await cache.storeProfessionals([fresh])
            }
            return cached
        }
        let fresh = try await live.professional(id: id)
        await cache.storeProfessionals([fresh])
        return fresh
    }

    /// Whether this collection has ever been fetched successfully.
    ///
    /// An empty list is a legitimate answer (a salon with no team yet), so
    /// emptiness alone cannot mean "cold cache" — a marker document records
    /// the fact of the fetch.
    private func hasFetched(_ key: String) async -> Bool {
        await cache.read(Date.self, key: key) != nil
    }
}

// MARK: - Appointments

/// Offline-first appointment reads: the day view keeps working when the signal
/// does not.
///
/// Writes are intentionally absent. `book`, `cancel`, `reschedule`, and
/// `updateStatus` stay on the live repository because the server owns the
/// calendar; queuing them would let two devices "book" the same slot.
public struct CachingAppointmentBook: AppointmentBookFetching {
    private let live: any AppointmentBookFetching
    private let cache: any OfflineCache
    private let refresh: RefreshCoordinator

    /// Wraps a live appointment repository.
    /// - Parameters:
    ///   - live: The Supabase-backed repository.
    ///   - cache: The offline store.
    ///   - refreshInterval: How long a background refresh keeps a key fresh.
    ///     Shorter than the catalogue's: a calendar moves.
    public init(
        live: any AppointmentBookFetching,
        cache: any OfflineCache,
        refreshInterval: TimeInterval = 30
    ) {
        self.live = live
        self.cache = cache
        self.refresh = RefreshCoordinator(minimumInterval: refreshInterval)
    }

    public func appointments(clientID: User.ID) async throws -> [Appointment] {
        let key = "appointments/client/\(clientID.rawValue.uuidString)"
        if await hasFetched(key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.appointments(clientID: clientID)
                await cache.storeAppointments(fresh)
                await cache.write(Date.now, key: key)
            }
            return await cache.cachedAppointments(clientID: clientID)
        }
        let fresh = try await live.appointments(clientID: clientID)
        await cache.storeAppointments(fresh)
        await cache.write(Date.now, key: key)
        return fresh
    }

    public func appointments(salonID: Salon.ID, on day: Date) async throws -> [Appointment] {
        let key = Self.dayKey(salonID: salonID, day: day)
        if await hasFetched(key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.appointments(salonID: salonID, on: day)
                await cache.storeAppointments(fresh)
                await cache.write(Date.now, key: key)
            }
            return await cache.cachedAppointments(salonID: salonID, on: day)
        }
        let fresh = try await live.appointments(salonID: salonID, on: day)
        await cache.storeAppointments(fresh)
        await cache.write(Date.now, key: key)
        return fresh
    }

    public func appointment(id: Appointment.ID) async throws -> Appointment {
        if let cached = await cache.cachedAppointment(id: id) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: "appointments/\(id.rawValue.uuidString)") {
                let fresh = try await live.appointment(id: id)
                await cache.storeAppointments([fresh])
            }
            return cached
        }
        let fresh = try await live.appointment(id: id)
        await cache.storeAppointments([fresh])
        return fresh
    }

    /// A day's cache key, pinned to the calendar day rather than the instant
    /// so two reads of "today" share one entry.
    private static func dayKey(salonID: Salon.ID, day: Date) -> String {
        let start = day.startOfDay()
        return "appointments/salon/\(salonID.rawValue.uuidString)/\(Int(start.timeIntervalSince1970))"
    }

    private func hasFetched(_ key: String) async -> Bool {
        await cache.read(Date.self, key: key) != nil
    }
}

// MARK: - CRM

/// Offline-first CRM: client cards read from cache, and notes that can be
/// written with no connection at all.
///
/// A note written offline is cached immediately (so the client card reads it
/// back), queued as a `SyncOperation` against the `client_notes` table, and
/// returned to the caller as if it had been saved — because from the salon's
/// point of view it has been. It reaches Postgres on the next drain.
public struct CachingClientRecords: ClientRecordFetching {
    private let live: any ClientRecordFetching
    private let cache: any OfflineCache
    private let sync: any SyncEngine
    private let payloadCoder: any PersistenceCoding
    private let offlineErrors: OfflineErrorClassifier
    private let refresh: RefreshCoordinator

    /// Wraps a live CRM repository.
    /// - Parameters:
    ///   - live: The Supabase-backed repository.
    ///   - cache: The offline store.
    ///   - sync: Engine that will deliver queued notes.
    ///   - payloadCoder: Coder for `SyncOperation.payload`. This payload is
    ///     posted to PostgREST, so pass a coder that produces the **wire**
    ///     format (`JSONCoding` in `PRVNetworking`) — there is deliberately no
    ///     default, because silently shipping camelCase keys to a snake_case
    ///     table is the kind of bug that only shows up in production.
    ///   - offlineErrors: How to recognise a connectivity failure.
    ///   - refreshInterval: How long a background refresh keeps a key fresh.
    public init(
        live: any ClientRecordFetching,
        cache: any OfflineCache,
        sync: any SyncEngine,
        payloadCoder: any PersistenceCoding,
        offlineErrors: OfflineErrorClassifier = .default,
        refreshInterval: TimeInterval = 60
    ) {
        self.live = live
        self.cache = cache
        self.sync = sync
        self.payloadCoder = payloadCoder
        self.offlineErrors = offlineErrors
        self.refresh = RefreshCoordinator(minimumInterval: refreshInterval)
    }

    public func clients(salonID: Salon.ID, searchText: String) async throws -> [ClientRecord] {
        // The search itself is applied locally on the cached rows, exactly as
        // the live repository applies it server-side, so typing stays instant
        // offline. The key ignores the text: one cached roster serves every
        // query.
        let key = "clients/salon/\(salonID.rawValue.uuidString)"
        if await hasFetched(key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.clients(salonID: salonID, searchText: "")
                await cache.storeClients(fresh)
                await cache.write(Date.now, key: key)
            }
            return await cache.cachedClients(salonID: salonID, searchText: searchText)
        }
        let fresh = try await live.clients(salonID: salonID, searchText: searchText)
        await cache.storeClients(fresh)
        if searchText.isBlank {
            // Only a complete roster may claim the marker; a filtered result
            // would otherwise freeze the cache at one search term.
            await cache.write(Date.now, key: key)
        }
        return fresh
    }

    public func client(id: ClientRecord.ID) async throws -> ClientRecord {
        if let cached = await cache.cachedClient(id: id) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: "clients/\(id.rawValue.uuidString)") {
                let fresh = try await live.client(id: id)
                await cache.storeClients([fresh])
            }
            return cached
        }
        let fresh = try await live.client(id: id)
        await cache.storeClients([fresh])
        return fresh
    }

    public func notes(clientRecordID: ClientRecord.ID) async throws -> [ClientNote] {
        let key = "notes/client/\(clientRecordID.rawValue.uuidString)"
        if await hasFetched(key) {
            let live = self.live
            let cache = self.cache
            await refresh.schedule(key: key) {
                let fresh = try await live.notes(clientRecordID: clientRecordID)
                // Server notes are merged, never used to replace the cache:
                // a note still queued for sync exists nowhere else.
                await cache.storeNotes(fresh)
                await cache.write(Date.now, key: key)
            }
            return await cache.cachedNotes(clientRecordID: clientRecordID)
        }
        let fresh = try await live.notes(clientRecordID: clientRecordID)
        await cache.storeNotes(fresh)
        await cache.write(Date.now, key: key)
        return await cache.cachedNotes(clientRecordID: clientRecordID)
    }

    public func addNote(_ note: ClientNote) async throws -> ClientNote {
        // Known-offline: do not spend a request (and a timeout) to find out.
        if await sync.state() == .offline {
            return try await queueOffline(note)
        }
        do {
            let saved = try await live.addNote(note)
            await cache.storeNotes([saved])
            return saved
        } catch {
            guard offlineErrors.isOffline(error) else { throw error }
            return try await queueOffline(note)
        }
    }

    /// Identifiers of this client's notes that have not reached the server —
    /// CRM badges them "will sync".
    public func pendingNoteIDs(clientRecordID: ClientRecord.ID) async -> Set<ClientNote.ID> {
        await cache.pendingNoteIDs(clientRecordID: clientRecordID)
    }

    /// Caches a note locally and queues it for delivery.
    ///
    /// The payload is encoded *first*: if it cannot be encoded, the caller
    /// gets a real error instead of a note that is cached but can never sync.
    private func queueOffline(_ note: ClientNote) async throws -> ClientNote {
        let payload = try payloadCoder.encode(note)
        await cache.storeNote(note, pendingSync: true)
        await sync.enqueue(
            SyncOperation(
                kind: .create,
                entity: SyncEntity.clientNotes,
                entityID: note.id.rawValue,
                payload: payload
            )
        )
        PRVLog.sync.notice("Note saved offline; queued for sync")
        return note
    }

    private func hasFetched(_ key: String) async -> Bool {
        await cache.read(Date.self, key: key) != nil
    }
}
