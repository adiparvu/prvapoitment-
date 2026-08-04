#if canImport(SwiftData)
import Foundation
import PRVFoundation
import PRVModels
import SwiftData

/// The shipping offline cache: SwiftData behind a `ModelActor`.
///
/// `ModelContext` is not `Sendable` and SwiftData is explicit that a context
/// belongs to exactly one isolation domain. `@ModelActor` gives this actor its
/// own context *and* its own serial executor, so every fetch, insert, and save
/// in the module happens on that executor — no context ever crosses a task
/// boundary, which is what Swift 6 strict concurrency demands.
///
/// Only domain values (`Salon`, `Appointment`, `ClientNote`, …) cross the actor
/// boundary. The `@Model` classes never leave this file's module scope, so a
/// caller can never hold a live `PersistentModel` on the wrong actor.
///
/// ```swift
/// let cache = try SwiftDataCacheStore.make()
/// let today = await cache.cachedAppointments(salonID: salon.id, on: .now)
/// ```
///
/// Reads and writes never throw. A cache that fails loudly is worse than one
/// that misses: a decode failure is logged, the poisoned row is dropped, and
/// the caller falls through to the network exactly as it would on a cold
/// cache.
@ModelActor
public actor SwiftDataCacheStore: OfflineCache, SyncOperationStore {
    /// Cache blobs are written and read by the same device, so a symmetric
    /// local coder is correct here — see ``PRVLocalJSONCoder`` for why this is
    /// deliberately *not* the wire coder.
    private static let coder = PRVLocalJSONCoder()

    // MARK: - Factories

    /// Creates a store over an existing container.
    /// - Parameter container: Container built by ``PRVCacheContainer``.
    public static func make(container: ModelContainer) -> SwiftDataCacheStore {
        SwiftDataCacheStore(modelContainer: container)
    }

    /// Creates a store over a freshly built container.
    /// - Parameter inMemory: `true` for previews and tests.
    /// - Throws: Whatever SwiftData raises when the store cannot be opened.
    public static func make(inMemory: Bool = false) throws -> SwiftDataCacheStore {
        SwiftDataCacheStore(modelContainer: try PRVCacheContainer.make(inMemory: inMemory))
    }

    // MARK: - CacheStore

    public func read<T: Codable & Sendable>(_ type: T.Type, key: String) async -> T? {
        guard let row = fetchOne(#Predicate<CachedDocument> { $0.key == key }) else { return nil }
        guard let value = decode(T.self, from: row.payload) else {
            modelContext.delete(row)
            save()
            return nil
        }
        return value
    }

    public func write<T: Codable & Sendable>(_ value: T, key: String) async {
        guard let payload = encode(value) else { return }
        let now = Date.now
        upsert(
            matching: #Predicate<CachedDocument> { $0.key == key },
            insert: { CachedDocument(key: key, updatedAt: now, payload: payload) },
            update: { row in
                row.payload = payload
                row.updatedAt = now
            }
        )
        save()
    }

    public func remove(key: String) async {
        delete(CachedDocument.self, where: #Predicate<CachedDocument> { $0.key == key })
        save()
    }

    /// Clears every cached read model — the sign-out purge.
    ///
    /// Two things deliberately survive, because neither is cache:
    ///
    /// * the sync queue — unsent user writes are work, not a copy of something
    ///   the server already has; call ``removeAllOperations()`` when they
    ///   really should be destroyed (account deletion),
    /// * notes still waiting to sync, for the same reason: their queued
    ///   operation is still pending and this device holds the only copy.
    public func removeAll() async {
        delete(CachedDocument.self)
        delete(CachedSalon.self)
        delete(CachedService.self)
        delete(CachedProfessional.self)
        delete(CachedAppointment.self)
        delete(CachedOrder.self)
        delete(CachedConversation.self)
        delete(CachedMessage.self)
        delete(CachedNotification.self)
        delete(CachedClientRecord.self)
        delete(CachedClientNote.self, where: #Predicate<CachedClientNote> { $0.isPendingSync == false })
        delete(CachedLoyaltyProfile.self)
        save()
    }

    // MARK: - SalonCatalogCache

    public func cachedSalons() async -> [Salon] {
        let rows: [CachedSalon] = fetchAll()
        return rows.compactMap { decode(Salon.self, from: $0.payload) }
    }

    public func cachedSalon(id: Salon.ID) async -> Salon? {
        let key = id.rawValue
        guard let row = fetchOne(#Predicate<CachedSalon> { $0.id == key }) else { return nil }
        return decode(Salon.self, from: row.payload)
    }

    public func storeSalons(_ salons: [Salon]) async {
        let now = Date.now
        for salon in salons {
            guard let payload = encode(salon) else { continue }
            let key = salon.id.rawValue
            let freshness = salon.createdAt
            upsert(
                matching: #Predicate<CachedSalon> { $0.id == key },
                insert: { CachedSalon(id: key, updatedAt: freshness, cachedAt: now, payload: payload) },
                update: { row in
                    row.payload = payload
                    row.updatedAt = freshness
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    public func cachedServices(salonID: Salon.ID) async -> [SalonService] {
        let key: UUID? = salonID.rawValue
        let rows: [CachedService] = fetchAll(#Predicate<CachedService> { $0.salonID == key })
        return rows.compactMap { decode(SalonService.self, from: $0.payload) }
    }

    public func cachedService(id: SalonService.ID) async -> SalonService? {
        let key = id.rawValue
        guard let row = fetchOne(#Predicate<CachedService> { $0.id == key }) else { return nil }
        return decode(SalonService.self, from: row.payload)
    }

    public func storeServices(_ services: [SalonService]) async {
        let now = Date.now
        for service in services {
            guard let payload = encode(service) else { continue }
            let key = service.id.rawValue
            let owner = service.salonID?.rawValue
            upsert(
                matching: #Predicate<CachedService> { $0.id == key },
                insert: { CachedService(id: key, salonID: owner, updatedAt: now, cachedAt: now, payload: payload) },
                update: { row in
                    row.payload = payload
                    row.salonID = owner
                    row.updatedAt = now
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    public func cachedProfessionals(salonID: Salon.ID) async -> [Professional] {
        let key: UUID? = salonID.rawValue
        let rows: [CachedProfessional] = fetchAll(#Predicate<CachedProfessional> { $0.salonID == key })
        return rows.compactMap { decode(Professional.self, from: $0.payload) }
    }

    public func cachedProfessional(id: Professional.ID) async -> Professional? {
        let key = id.rawValue
        guard let row = fetchOne(#Predicate<CachedProfessional> { $0.id == key }) else { return nil }
        return decode(Professional.self, from: row.payload)
    }

    public func storeProfessionals(_ professionals: [Professional]) async {
        let now = Date.now
        for professional in professionals {
            guard let payload = encode(professional) else { continue }
            let key = professional.id.rawValue
            let owner = professional.salonID?.rawValue
            upsert(
                matching: #Predicate<CachedProfessional> { $0.id == key },
                insert: {
                    CachedProfessional(id: key, salonID: owner, updatedAt: now, cachedAt: now, payload: payload)
                },
                update: { row in
                    row.payload = payload
                    row.salonID = owner
                    row.updatedAt = now
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    // MARK: - AppointmentCache

    public func cachedAppointments(clientID: User.ID) async -> [Appointment] {
        // Group bookings live in `additionalClientIDs`, inside the payload, so
        // the client view decodes the (pruned, per-device) table and applies
        // the repository's own rule rather than half-answering from a column.
        let rows: [CachedAppointment] = fetchAll()
        let appointments = rows.compactMap { decode(Appointment.self, from: $0.payload) }
        return PRVCacheSemantics.appointments(appointments, clientID: clientID)
    }

    public func cachedAppointments(salonID: Salon.ID, on day: Date) async -> [Appointment] {
        let key = salonID.rawValue
        let dayStart = day.startOfDay()
        let dayEnd = dayStart.adding(days: 1)
        let rows: [CachedAppointment] = fetchAll(
            #Predicate<CachedAppointment> {
                $0.salonID == key && $0.startsAt >= dayStart && $0.startsAt < dayEnd
            }
        )
        let appointments = rows.compactMap { decode(Appointment.self, from: $0.payload) }
        return PRVCacheSemantics.appointments(appointments, salonID: salonID, on: day)
    }

    public func cachedAppointment(id: Appointment.ID) async -> Appointment? {
        let key = id.rawValue
        guard let row = fetchOne(#Predicate<CachedAppointment> { $0.id == key }) else { return nil }
        return decode(Appointment.self, from: row.payload)
    }

    public func storeAppointments(_ appointments: [Appointment]) async {
        let now = Date.now
        for appointment in appointments {
            guard let payload = encode(appointment) else { continue }
            let key = appointment.id.rawValue
            let salon = appointment.salonID.rawValue
            let client = appointment.clientID.rawValue
            let start = PRVCacheSemantics.startKey(of: appointment)
            let status = appointment.status.rawValue
            let freshness = PRVCacheSemantics.freshness(of: appointment)
            upsert(
                matching: #Predicate<CachedAppointment> { $0.id == key },
                insert: {
                    CachedAppointment(
                        id: key,
                        salonID: salon,
                        clientID: client,
                        startsAt: start,
                        status: status,
                        updatedAt: freshness,
                        cachedAt: now,
                        payload: payload
                    )
                },
                update: { row in
                    // Last-write-wins: an older copy of the same booking must
                    // never overwrite a newer one that arrived out of order.
                    guard freshness >= row.updatedAt else { return }
                    row.payload = payload
                    row.salonID = salon
                    row.clientID = client
                    row.startsAt = start
                    row.status = status
                    row.updatedAt = freshness
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    // MARK: - ClientRecordCache

    public func cachedClients(salonID: Salon.ID, searchText: String) async -> [ClientRecord] {
        let key = salonID.rawValue
        let rows: [CachedClientRecord] = fetchAll(#Predicate<CachedClientRecord> { $0.salonID == key })
        let records = rows.compactMap { decode(ClientRecord.self, from: $0.payload) }
        return PRVCacheSemantics.clients(records, salonID: salonID, searchText: searchText)
    }

    public func cachedClient(id: ClientRecord.ID) async -> ClientRecord? {
        let key = id.rawValue
        guard let row = fetchOne(#Predicate<CachedClientRecord> { $0.id == key }) else { return nil }
        return decode(ClientRecord.self, from: row.payload)
    }

    public func storeClients(_ records: [ClientRecord]) async {
        let now = Date.now
        for record in records {
            guard let payload = encode(record) else { continue }
            let key = record.id.rawValue
            let salon = record.salonID.rawValue
            upsert(
                matching: #Predicate<CachedClientRecord> { $0.id == key },
                insert: {
                    CachedClientRecord(id: key, salonID: salon, updatedAt: now, cachedAt: now, payload: payload)
                },
                update: { row in
                    row.payload = payload
                    row.salonID = salon
                    row.updatedAt = now
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    public func cachedNotes(clientRecordID: ClientRecord.ID) async -> [ClientNote] {
        let key = clientRecordID.rawValue
        let rows: [CachedClientNote] = fetchAll(#Predicate<CachedClientNote> { $0.clientRecordID == key })
        let notes = rows.compactMap { decode(ClientNote.self, from: $0.payload) }
        return PRVCacheSemantics.notes(notes, clientRecordID: clientRecordID)
    }

    public func storeNotes(_ notes: [ClientNote]) async {
        for note in notes {
            store(note, pendingSync: false)
        }
        save()
    }

    public func storeNote(_ note: ClientNote, pendingSync: Bool) async {
        store(note, pendingSync: pendingSync)
        save()
    }

    public func pendingNoteIDs(clientRecordID: ClientRecord.ID) async -> Set<ClientNote.ID> {
        let key = clientRecordID.rawValue
        let rows: [CachedClientNote] = fetchAll(
            #Predicate<CachedClientNote> { $0.clientRecordID == key && $0.isPendingSync == true }
        )
        return Set(rows.map { ClientNote.ID($0.id) })
    }

    // MARK: - OrderCache

    public func cachedOrders(clientID: User.ID) async -> [Order] {
        let key = clientID.rawValue
        let rows: [CachedOrder] = fetchAll(#Predicate<CachedOrder> { $0.clientID == key })
        let orders = rows.compactMap { decode(Order.self, from: $0.payload) }
        return PRVCacheSemantics.orders(orders, clientID: clientID)
    }

    public func cachedOrder(id: Order.ID) async -> Order? {
        let key = id.rawValue
        guard let row = fetchOne(#Predicate<CachedOrder> { $0.id == key }) else { return nil }
        return decode(Order.self, from: row.payload)
    }

    public func storeOrders(_ orders: [Order]) async {
        let now = Date.now
        for order in orders {
            guard let payload = encode(order) else { continue }
            let key = order.id.rawValue
            let salon = order.salonID.rawValue
            let client = order.clientID.rawValue
            let freshness = order.paidAt ?? order.createdAt
            upsert(
                matching: #Predicate<CachedOrder> { $0.id == key },
                insert: {
                    CachedOrder(
                        id: key,
                        salonID: salon,
                        clientID: client,
                        updatedAt: freshness,
                        cachedAt: now,
                        payload: payload
                    )
                },
                update: { row in
                    row.payload = payload
                    row.salonID = salon
                    row.clientID = client
                    row.updatedAt = freshness
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    // MARK: - ConversationCache

    public func cachedConversations(userID: User.ID) async -> [Conversation] {
        // Participants are an array inside the payload; the table is small
        // (one row per thread), so the membership test happens after decoding.
        let rows: [CachedConversation] = fetchAll()
        let conversations = rows.compactMap { decode(Conversation.self, from: $0.payload) }
        return PRVCacheSemantics.conversations(conversations, userID: userID)
    }

    public func storeConversations(_ conversations: [Conversation]) async {
        let now = Date.now
        for conversation in conversations {
            guard let payload = encode(conversation) else { continue }
            let key = conversation.id.rawValue
            let salon = conversation.salonID?.rawValue
            let freshness = conversation.lastMessageAt ?? .distantPast
            upsert(
                matching: #Predicate<CachedConversation> { $0.id == key },
                insert: {
                    CachedConversation(
                        id: key,
                        salonID: salon,
                        updatedAt: freshness,
                        cachedAt: now,
                        payload: payload
                    )
                },
                update: { row in
                    row.payload = payload
                    row.salonID = salon
                    row.updatedAt = freshness
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    public func cachedMessages(conversationID: Conversation.ID) async -> [ChatMessage] {
        let key = conversationID.rawValue
        let rows: [CachedMessage] = fetchAll(#Predicate<CachedMessage> { $0.conversationID == key })
        let messages = rows.compactMap { decode(ChatMessage.self, from: $0.payload) }
        return PRVCacheSemantics.messages(messages, conversationID: conversationID)
    }

    public func storeMessages(_ messages: [ChatMessage]) async {
        let now = Date.now
        for message in messages {
            guard let payload = encode(message) else { continue }
            let key = message.id.rawValue
            let conversation = message.conversationID.rawValue
            let sentAt = message.sentAt
            upsert(
                matching: #Predicate<CachedMessage> { $0.id == key },
                insert: {
                    CachedMessage(
                        id: key,
                        conversationID: conversation,
                        sentAt: sentAt,
                        cachedAt: now,
                        payload: payload
                    )
                },
                update: { row in
                    row.payload = payload
                    row.conversationID = conversation
                    row.sentAt = sentAt
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    // MARK: - NotificationCache

    public func cachedNotifications(userID: User.ID) async -> [PRVNotification] {
        let key = userID.rawValue
        let rows: [CachedNotification] = fetchAll(#Predicate<CachedNotification> { $0.userID == key })
        let notifications = rows.compactMap { decode(PRVNotification.self, from: $0.payload) }
        return PRVCacheSemantics.notifications(notifications, userID: userID)
    }

    public func storeNotifications(_ notifications: [PRVNotification]) async {
        let now = Date.now
        for notification in notifications {
            guard let payload = encode(notification) else { continue }
            let key = notification.id.rawValue
            let user = notification.userID.rawValue
            let createdAt = notification.createdAt
            upsert(
                matching: #Predicate<CachedNotification> { $0.id == key },
                insert: {
                    CachedNotification(
                        id: key,
                        userID: user,
                        createdAt: createdAt,
                        cachedAt: now,
                        payload: payload
                    )
                },
                update: { row in
                    row.payload = payload
                    row.userID = user
                    row.createdAt = createdAt
                    row.cachedAt = now
                }
            )
        }
        save()
    }

    // MARK: - LoyaltyCache

    public func cachedLoyaltyProfile(userID: User.ID) async -> LoyaltyProfile? {
        let key = userID.rawValue
        guard let row = fetchOne(#Predicate<CachedLoyaltyProfile> { $0.id == key }) else { return nil }
        return decode(LoyaltyProfile.self, from: row.payload)
    }

    public func storeLoyaltyProfile(_ profile: LoyaltyProfile) async {
        guard let payload = encode(profile) else { return }
        let now = Date.now
        let key = profile.userID.rawValue
        upsert(
            matching: #Predicate<CachedLoyaltyProfile> { $0.id == key },
            insert: { CachedLoyaltyProfile(id: key, updatedAt: now, cachedAt: now, payload: payload) },
            update: { row in
                row.payload = payload
                row.updatedAt = now
                row.cachedAt = now
            }
        )
        save()
    }

    // MARK: - OfflineCacheMaintenance

    public func prune(olderThan retention: TimeInterval) async {
        let cutoff = Date.now.addingTimeInterval(-abs(retention))
        // Future bookings are never pruned — they are precisely what the
        // offline day view exists to show.
        delete(CachedAppointment.self, where: #Predicate<CachedAppointment> { $0.startsAt < cutoff })
        delete(CachedMessage.self, where: #Predicate<CachedMessage> { $0.sentAt < cutoff })
        delete(CachedNotification.self, where: #Predicate<CachedNotification> { $0.createdAt < cutoff })
        delete(CachedOrder.self, where: #Predicate<CachedOrder> { $0.updatedAt < cutoff })
        delete(CachedDocument.self, where: #Predicate<CachedDocument> { $0.updatedAt < cutoff })
        // An unsynced note is the only copy of that work in existence.
        delete(
            CachedClientNote.self,
            where: #Predicate<CachedClientNote> { $0.createdAt < cutoff && $0.isPendingSync == false }
        )
        save()
    }

    // MARK: - SyncOperationStore

    public func append(_ operation: SyncOperation) async {
        persist(operation, lastError: nil)
        save()
    }

    public func pending() async -> [SyncOperation] {
        let rows: [QueuedSyncOperation] = fetchAll()
        return rows
            .compactMap { $0.operation() }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func update(_ operation: SyncOperation, lastError: String?) async {
        persist(operation, lastError: lastError)
        save()
    }

    public func remove(id: SyncOperation.ID) async {
        let key = id.rawValue
        delete(QueuedSyncOperation.self, where: #Predicate<QueuedSyncOperation> { $0.id == key })
        save()
    }

    public func removeAllOperations() async {
        delete(QueuedSyncOperation.self)
        save()
    }

    // MARK: - Storage plumbing

    /// Inserts or updates one note row.
    private func store(_ note: ClientNote, pendingSync: Bool) {
        guard let payload = encode(note) else { return }
        let now = Date.now
        let key = note.id.rawValue
        let record = note.clientRecordID.rawValue
        let createdAt = note.createdAt
        upsert(
            matching: #Predicate<CachedClientNote> { $0.id == key },
            insert: {
                CachedClientNote(
                    id: key,
                    clientRecordID: record,
                    createdAt: createdAt,
                    cachedAt: now,
                    isPendingSync: pendingSync,
                    payload: payload
                )
            },
            update: { row in
                row.payload = payload
                row.clientRecordID = record
                row.createdAt = createdAt
                row.cachedAt = now
                row.isPendingSync = pendingSync
            }
        )
    }

    /// Inserts or updates one queued operation row.
    private func persist(_ operation: SyncOperation, lastError: String?) {
        let key = operation.id.rawValue
        upsert(
            matching: #Predicate<QueuedSyncOperation> { $0.id == key },
            insert: {
                let row = QueuedSyncOperation.row(for: operation)
                row.lastError = lastError
                row.lastAttemptAt = operation.attemptCount > 0 ? Date.now : nil
                return row
            },
            update: { row in
                row.apply(operation)
                row.lastError = lastError
                if operation.attemptCount > 0 {
                    row.lastAttemptAt = Date.now
                }
            }
        )
    }

    /// Fetches at most one row matching `predicate`.
    private func fetchOne<Model: PersistentModel>(_ predicate: Predicate<Model>) -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            PRVLog.persistence.error("Cache fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Fetches every row matching `predicate` (all rows when it is `nil`).
    private func fetchAll<Model: PersistentModel>(_ predicate: Predicate<Model>? = nil) -> [Model] {
        do {
            return try modelContext.fetch(FetchDescriptor<Model>(predicate: predicate))
        } catch {
            PRVLog.persistence.error("Cache fetch failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Updates the row matching `predicate`, or inserts a new one.
    private func upsert<Model: PersistentModel>(
        matching predicate: Predicate<Model>,
        insert: () -> Model,
        update: (Model) -> Void
    ) {
        if let existing = fetchOne(predicate) {
            update(existing)
        } else {
            modelContext.insert(insert())
        }
    }

    /// Batch-deletes rows of one model, optionally narrowed by a predicate.
    private func delete<Model: PersistentModel>(
        _ type: Model.Type,
        where predicate: Predicate<Model>? = nil
    ) {
        do {
            try modelContext.delete(model: type, where: predicate)
        } catch {
            PRVLog.persistence.error("Cache delete failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Commits pending changes, rolling back rather than leaving the context
    /// in a half-applied state if the write fails.
    private func save() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            PRVLog.persistence.error("Cache save failed: \(String(describing: error), privacy: .public)")
            modelContext.rollback()
        }
    }

    /// Encodes a domain value, logging and skipping rather than throwing.
    private func encode(_ value: some Encodable) -> Data? {
        do {
            return try Self.coder.encode(value)
        } catch {
            PRVLog.persistence.error("Cache encode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Decodes a cached payload, logging and reporting a miss rather than
    /// throwing.
    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) -> Value? {
        do {
            return try Self.coder.decode(type, from: data)
        } catch {
            PRVLog.persistence.error("Cache decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
#endif
