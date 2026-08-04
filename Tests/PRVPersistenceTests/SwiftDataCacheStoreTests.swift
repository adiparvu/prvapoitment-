#if canImport(SwiftData)
import Foundation
import PRVModels
import PRVPersistence
import SwiftData
import Testing

/// The shipping store, exercised against a real (in-memory) `ModelContainer`.
///
/// `InMemoryOfflineCache` and `SwiftDataCacheStore` are two implementations of
/// one contract, so the interesting assertions are the ones that hold for both:
/// the queue is ordered by when a mutation happened, unsent work outlives a
/// cache purge, and the sync engine cannot tell the two stores apart.
@Suite("SwiftData cache store")
struct SwiftDataCacheStoreTests {
    /// A store over a throwaway container — nothing touches disk, and every
    /// test starts empty.
    private func makeStore() throws -> SwiftDataCacheStore {
        SwiftDataCacheStore.make(container: try PRVCacheContainer.make(inMemory: true))
    }

    // MARK: - Documents

    @Test("A cached document round-trips through the store")
    func documentsRoundTrip() async throws {
        let store = try makeStore()

        await store.write(["lumiere", "velvet"], key: "salons/trending")
        let read: [String]? = await store.read([String].self, key: "salons/trending")

        #expect(read == ["lumiere", "velvet"])
    }

    @Test("A missing key reads as nil rather than throwing")
    func missingDocumentsReadAsNil() async throws {
        let store = try makeStore()

        let read: [String]? = await store.read([String].self, key: PRVCacheKey.trendingSalons)

        // A cache miss is an ordinary outcome: the caller falls through to the
        // network exactly as it would on a cold launch.
        #expect(read == nil)
    }

    @Test("Writing the same key twice replaces the value")
    func documentWritesAreUpserts() async throws {
        let store = try makeStore()

        await store.write(["first"], key: "salons/trending")
        await store.write(["second"], key: "salons/trending")

        let read: [String]? = await store.read([String].self, key: "salons/trending")
        #expect(read == ["second"])
    }

    @Test("Removing a key clears it")
    func documentsCanBeRemoved() async throws {
        let store = try makeStore()

        await store.write(["value"], key: "salons/trending")
        await store.remove(key: "salons/trending")

        let read: [String]? = await store.read([String].self, key: "salons/trending")
        #expect(read == nil)
    }

    // MARK: - Read models

    @Test("Cached appointments reproduce the live repository's filter and order")
    func cachedAppointmentsMatchTheRepositorySemantics() async throws {
        let store = try makeStore()
        let guest = User.ID()
        let later = Self.appointment(startingIn: 3 * 24 * 3_600)
        let sooner = Self.appointment(startingIn: 24 * 3_600, additionalClientIDs: [guest])
        let someoneElse = Self.appointment(startingIn: 2 * 24 * 3_600, clientID: User.ID())

        await store.storeAppointments([later, sooner, someoneElse])

        let mine = await store.cachedAppointments(clientID: PreviewData.client.id)
        #expect(mine.map(\.id) == [sooner.id, later.id])

        // Group bookings surface for every participant, not only the booker.
        let theirs = await store.cachedAppointments(clientID: guest)
        #expect(theirs.map(\.id) == [sooner.id])

        let byID = await store.cachedAppointment(id: later.id)
        #expect(byID?.id == later.id)
    }

    // MARK: - Sync queue

    @Test("The queue reads back oldest-first regardless of insertion order")
    func queueIsOrderedByCreationTime() async throws {
        let store = try makeStore()
        let oldest = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 300)
        let newest = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60)

        await store.append(newest)
        await store.append(oldest)

        let pending = await store.pending()
        #expect(pending.map(\.id) == [oldest.id, newest.id])
        #expect(pending.first?.payload == oldest.payload)
        #expect(pending.first?.entity == SyncEntity.clientNotes)
    }

    @Test("Updating an operation persists its attempt count instead of duplicating it")
    func queueUpdatesAreUpserts() async throws {
        let store = try makeStore()
        var operation = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60)

        await store.append(operation)
        operation.attemptCount = 2
        await store.update(operation, lastError: "503")

        let pending = await store.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.attemptCount == 2)
    }

    @Test("Delivered operations can be removed one at a time or all at once")
    func queueEntriesCanBeRemoved() async throws {
        let store = try makeStore()
        let first = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 120)
        let second = SyncFixtures.operation(entity: SyncEntity.reviews, secondsAgo: 60)

        await store.append(first)
        await store.append(second)
        await store.remove(id: first.id)

        let afterOne = await store.pending()
        #expect(afterOne.map(\.id) == [second.id])

        await store.removeAllOperations()
        let afterAll = await store.pending()
        #expect(afterAll.isEmpty)
    }

    @Test("Clearing the read cache never destroys unsent work")
    func cachePurgeKeepsTheQueue() async throws {
        let store = try makeStore()
        await store.append(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        await store.write(["lumiere"], key: "salons/trending")
        await store.storeSalons([PreviewData.salonLumiere])

        // The sign-out purge drops cached copies of server data — and only that.
        await store.removeAll()

        let document: [String]? = await store.read([String].self, key: "salons/trending")
        #expect(document == nil)
        let salons = await store.cachedSalons()
        #expect(salons.isEmpty)
        let pending = await store.pending()
        #expect(pending.count == 1)
    }

    // MARK: - End to end

    @Test("The sync engine drains a SwiftData-backed queue exactly as it drains an in-memory one")
    func engineDrainsTheSwiftDataQueue() async throws {
        let store = try makeStore()
        let sender = FakeSyncSender()
        let engine = SyncFixtures.engine(store: store, sender: sender)

        let oldest = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 300)
        let newest = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 100)
        await engine.enqueue(newest)
        await engine.enqueue(oldest)

        let delivered = await engine.syncNow()

        #expect(delivered == 2)
        let order = await sender.deliveredEntityIDs
        #expect(order == [oldest.entityID, newest.entityID])
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test("A parked operation survives in the SwiftData queue with its attempt count")
    func parkedOperationsPersist() async throws {
        let store = try makeStore()
        let sender = FakeSyncSender(fallback: .retryable(reason: "gateway timeout"))
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        _ = await engine.syncNow()

        let pending = await store.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.attemptCount == SyncFixtures.instantRetries.maxAttempts)
        let state = await engine.state()
        #expect(state == .failed)
    }

    // MARK: - Fixtures

    /// An appointment for the demo client, starting `startingIn` seconds from now.
    private static func appointment(
        startingIn seconds: TimeInterval,
        clientID: User.ID = PreviewData.client.id,
        additionalClientIDs: [User.ID] = []
    ) -> Appointment {
        let start = Date.now.addingTimeInterval(seconds)
        return Appointment(
            salonID: PreviewData.salonLumiere.id,
            salonName: PreviewData.salonLumiere.name,
            clientID: clientID,
            additionalClientIDs: additionalClientIDs,
            items: [
                AppointmentItem(
                    serviceID: PreviewData.serviceCutBlowDry.id,
                    serviceName: PreviewData.serviceCutBlowDry.name,
                    start: start,
                    durationMinutes: 60,
                    price: Money(75)
                ),
            ],
            status: .confirmed
        )
    }
}
#endif
