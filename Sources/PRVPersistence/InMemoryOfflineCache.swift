import Foundation
import PRVFoundation
import PRVModels

/// A complete, dependency-free implementation of the offline layer's storage
/// contracts, held entirely in memory.
///
/// It exists for three reasons:
///
/// * **Previews and demo mode** — pairs with `InMemoryBackend` so an offline-first
///   screen behaves identically without touching disk.
/// * **Tests** — the sync engine and the caching decorators can be driven
///   deterministically, with no store file to clean up between cases.
/// * **Portability** — this module is compiled on Linux by the domain CI job,
///   where SwiftData does not exist. Everything that matters about the offline
///   semantics is therefore verifiable there.
///
/// Behaviour matches the SwiftData store exactly: both route their reads
/// through the same `PRVCacheSemantics` rules.
public actor InMemoryOfflineCache: OfflineCache, SyncOperationStore {
    private let coder: any PersistenceCoding

    private var documents: [String: Data] = [:]
    private var salons: [UUID: Salon] = [:]
    private var services: [UUID: SalonService] = [:]
    private var professionals: [UUID: Professional] = [:]
    private var appointments: [UUID: Appointment] = [:]
    private var orders: [UUID: Order] = [:]
    private var conversations: [UUID: Conversation] = [:]
    private var messages: [UUID: ChatMessage] = [:]
    private var notifications: [UUID: PRVNotification] = [:]
    private var clients: [UUID: ClientRecord] = [:]
    private var notes: [UUID: ClientNote] = [:]
    private var pendingNotes: Set<UUID> = []
    private var loyaltyProfiles: [UUID: LoyaltyProfile] = [:]
    private var queue: [SyncOperation] = []
    private var failureReasons: [UUID: String] = [:]

    /// Creates an empty cache.
    /// - Parameter coder: Coder used for the generic ``CacheStore`` blobs.
    public init(coder: any PersistenceCoding = PRVLocalJSONCoder()) {
        self.coder = coder
    }

    // MARK: - CacheStore

    public func read<T: Codable & Sendable>(_ type: T.Type, key: String) async -> T? {
        guard let data = documents[key] else { return nil }
        do {
            return try coder.decode(T.self, from: data)
        } catch {
            documents.removeValue(forKey: key)
            PRVLog.persistence.error("Dropping undecodable cache document for key \(key, privacy: .public)")
            return nil
        }
    }

    public func write<T: Codable & Sendable>(_ value: T, key: String) async {
        do {
            documents[key] = try coder.encode(value)
        } catch {
            PRVLog.persistence.error("Failed to encode cache document for key \(key, privacy: .public)")
        }
    }

    public func remove(key: String) async {
        documents.removeValue(forKey: key)
    }

    /// Clears every cached read model. Notes still waiting to sync survive,
    /// exactly as they do in the SwiftData store: this device holds the only
    /// copy of them.
    public func removeAll() async {
        documents.removeAll()
        salons.removeAll()
        services.removeAll()
        professionals.removeAll()
        appointments.removeAll()
        orders.removeAll()
        conversations.removeAll()
        messages.removeAll()
        notifications.removeAll()
        clients.removeAll()
        notes = notes.filter { pendingNotes.contains($0.key) }
        loyaltyProfiles.removeAll()
    }

    // MARK: - OfflineCacheMaintenance

    public func prune(olderThan retention: TimeInterval) async {
        let cutoff = Date.now.addingTimeInterval(-abs(retention))
        appointments = appointments.filter { PRVCacheSemantics.startKey(of: $0.value) >= cutoff }
        messages = messages.filter { $0.value.sentAt >= cutoff }
        notifications = notifications.filter { $0.value.createdAt >= cutoff }
        orders = orders.filter { $0.value.createdAt >= cutoff }
        // Notes that have not synced yet are never pruned: they are the only
        // copy of that work in existence.
        notes = notes.filter { $0.value.createdAt >= cutoff || pendingNotes.contains($0.key) }
    }

    // MARK: - SalonCatalogCache

    public func cachedSalons() async -> [Salon] {
        Array(salons.values)
    }

    public func cachedSalon(id: Salon.ID) async -> Salon? {
        salons[id.rawValue]
    }

    public func storeSalons(_ salons: [Salon]) async {
        for salon in salons { self.salons[salon.id.rawValue] = salon }
    }

    public func cachedServices(salonID: Salon.ID) async -> [SalonService] {
        PRVCacheSemantics.services(Array(services.values), salonID: salonID)
    }

    public func cachedService(id: SalonService.ID) async -> SalonService? {
        services[id.rawValue]
    }

    public func storeServices(_ services: [SalonService]) async {
        for service in services { self.services[service.id.rawValue] = service }
    }

    public func cachedProfessionals(salonID: Salon.ID) async -> [Professional] {
        PRVCacheSemantics.professionals(Array(professionals.values), salonID: salonID)
    }

    public func cachedProfessional(id: Professional.ID) async -> Professional? {
        professionals[id.rawValue]
    }

    public func storeProfessionals(_ professionals: [Professional]) async {
        for professional in professionals { self.professionals[professional.id.rawValue] = professional }
    }

    // MARK: - AppointmentCache

    public func cachedAppointments(clientID: User.ID) async -> [Appointment] {
        PRVCacheSemantics.appointments(Array(appointments.values), clientID: clientID)
    }

    public func cachedAppointments(salonID: Salon.ID, on day: Date) async -> [Appointment] {
        PRVCacheSemantics.appointments(Array(appointments.values), salonID: salonID, on: day)
    }

    public func cachedAppointment(id: Appointment.ID) async -> Appointment? {
        appointments[id.rawValue]
    }

    public func storeAppointments(_ appointments: [Appointment]) async {
        for appointment in appointments { self.appointments[appointment.id.rawValue] = appointment }
    }

    // MARK: - ClientRecordCache

    public func cachedClients(salonID: Salon.ID, searchText: String) async -> [ClientRecord] {
        PRVCacheSemantics.clients(Array(clients.values), salonID: salonID, searchText: searchText)
    }

    public func cachedClient(id: ClientRecord.ID) async -> ClientRecord? {
        clients[id.rawValue]
    }

    public func storeClients(_ records: [ClientRecord]) async {
        for record in records { clients[record.id.rawValue] = record }
    }

    public func cachedNotes(clientRecordID: ClientRecord.ID) async -> [ClientNote] {
        PRVCacheSemantics.notes(Array(notes.values), clientRecordID: clientRecordID)
    }

    public func storeNotes(_ notes: [ClientNote]) async {
        for note in notes {
            self.notes[note.id.rawValue] = note
            pendingNotes.remove(note.id.rawValue)
        }
    }

    public func storeNote(_ note: ClientNote, pendingSync: Bool) async {
        notes[note.id.rawValue] = note
        if pendingSync {
            pendingNotes.insert(note.id.rawValue)
        } else {
            pendingNotes.remove(note.id.rawValue)
        }
    }

    public func pendingNoteIDs(clientRecordID: ClientRecord.ID) async -> Set<ClientNote.ID> {
        var identifiers: Set<ClientNote.ID> = []
        for raw in pendingNotes {
            guard let note = notes[raw], note.clientRecordID == clientRecordID else { continue }
            identifiers.insert(note.id)
        }
        return identifiers
    }

    // MARK: - OrderCache

    public func cachedOrders(clientID: User.ID) async -> [Order] {
        PRVCacheSemantics.orders(Array(orders.values), clientID: clientID)
    }

    public func cachedOrder(id: Order.ID) async -> Order? {
        orders[id.rawValue]
    }

    public func storeOrders(_ orders: [Order]) async {
        for order in orders { self.orders[order.id.rawValue] = order }
    }

    // MARK: - ConversationCache

    public func cachedConversations(userID: User.ID) async -> [Conversation] {
        PRVCacheSemantics.conversations(Array(conversations.values), userID: userID)
    }

    public func storeConversations(_ conversations: [Conversation]) async {
        for conversation in conversations { self.conversations[conversation.id.rawValue] = conversation }
    }

    public func cachedMessages(conversationID: Conversation.ID) async -> [ChatMessage] {
        PRVCacheSemantics.messages(Array(messages.values), conversationID: conversationID)
    }

    public func storeMessages(_ messages: [ChatMessage]) async {
        for message in messages { self.messages[message.id.rawValue] = message }
    }

    // MARK: - NotificationCache

    public func cachedNotifications(userID: User.ID) async -> [PRVNotification] {
        PRVCacheSemantics.notifications(Array(notifications.values), userID: userID)
    }

    public func storeNotifications(_ notifications: [PRVNotification]) async {
        for notification in notifications { self.notifications[notification.id.rawValue] = notification }
    }

    // MARK: - LoyaltyCache

    public func cachedLoyaltyProfile(userID: User.ID) async -> LoyaltyProfile? {
        loyaltyProfiles[userID.rawValue]
    }

    public func storeLoyaltyProfile(_ profile: LoyaltyProfile) async {
        loyaltyProfiles[profile.userID.rawValue] = profile
    }

    // MARK: - SyncOperationStore

    public func append(_ operation: SyncOperation) async {
        if let index = queue.firstIndex(where: { $0.id == operation.id }) {
            queue[index] = operation
        } else {
            queue.append(operation)
        }
    }

    public func pending() async -> [SyncOperation] {
        queue.sorted { $0.createdAt < $1.createdAt }
    }

    public func update(_ operation: SyncOperation, lastError: String?) async {
        await append(operation)
        if let lastError {
            failureReasons[operation.id.rawValue] = lastError
        } else {
            failureReasons.removeValue(forKey: operation.id.rawValue)
        }
    }

    /// Why the last attempt at an operation failed, for tests and the
    /// diagnostics screen.
    public func failureReason(for id: SyncOperation.ID) -> String? {
        failureReasons[id.rawValue]
    }

    public func remove(id: SyncOperation.ID) async {
        queue.removeAll { $0.id == id }
        failureReasons.removeValue(forKey: id.rawValue)
    }

    public func removeAllOperations() async {
        queue.removeAll()
        failureReasons.removeAll()
    }
}
