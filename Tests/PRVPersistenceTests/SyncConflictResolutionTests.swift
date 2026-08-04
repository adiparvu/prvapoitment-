import Foundation
import PRVModels
import PRVPersistence
import Testing

/// ARCHITECTURE.md §6: reconciliation is last-write-wins **except** for
/// bookings and payments, which are server-authoritative.
///
/// The distinction is not stylistic. A slot can be taken and money can move
/// while a device is in a basement; when the server says the local edit lost,
/// that edit is discarded — never retried, never re-applied — and the server's
/// row replaces it on screen. Everything else is the client's to overwrite.
@Suite("Sync engine — conflict resolution")
struct SyncConflictResolutionTests {
    // MARK: - Policy

    @Test("The default policy names exactly the booking and money tables")
    func defaultPolicyCoversBookingsAndPayments() {
        let policy = SyncConflictPolicy.default

        #expect(policy.isServerAuthoritative(SyncEntity.appointments))
        #expect(policy.isServerAuthoritative(SyncEntity.waitlistEntries))
        #expect(policy.isServerAuthoritative(SyncEntity.orders))
        #expect(policy.isServerAuthoritative(SyncEntity.refunds))
        #expect(policy.isServerAuthoritative(SyncEntity.invoices))
        #expect(policy.isServerAuthoritative(SyncEntity.giftCards))
        #expect(policy.isServerAuthoritative(SyncEntity.walletTransactions))
        #expect(policy.isServerAuthoritative(SyncEntity.membershipSubscriptions))

        // Everything a salon types is last-write-wins: the device that wrote
        // last is the one that knows what happened in the chair.
        #expect(!policy.isServerAuthoritative(SyncEntity.clientNotes))
        #expect(!policy.isServerAuthoritative(SyncEntity.clientRecords))
        #expect(!policy.isServerAuthoritative(SyncEntity.consentForms))
        #expect(!policy.isServerAuthoritative(SyncEntity.reviews))
        #expect(!policy.isServerAuthoritative(SyncEntity.messages))
        #expect(!policy.isServerAuthoritative(SyncEntity.products))
        #expect(!policy.isServerAuthoritative(SyncEntity.shifts))
        #expect(!policy.isServerAuthoritative(SyncEntity.timeEntries))
    }

    // MARK: - Server-authoritative

    @Test("A booking that loses a race is discarded, not retried")
    func bookingConflictDiscardsTheLocalOperation() async {
        let store = InMemoryOfflineCache()
        let recorder = ServerVersionRecorder()
        let sender = FakeSyncSender(
            scripted: [.conflict(serverPayload: SyncFixtures.serverPayload(#"{"status":"confirmed"}"#))]
        )
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            applyServerVersion: recorder.handler()
        )
        let operation = SyncFixtures.operation(
            entity: SyncEntity.appointments,
            kind: .create,
            secondsAgo: 120
        )

        await engine.enqueue(operation)
        let delivered = await engine.syncNow()

        // Not delivered, not parked, not retried — gone.
        #expect(delivered == 0)
        let attempts = await sender.attemptCount
        #expect(attempts == 1)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)

        // …and the server's version replaces it, flagged so the UI can tell
        // the client their booking did not stick.
        let versions = await recorder.versions
        #expect(versions.count == 1)
        #expect(versions.first?.entity == SyncEntity.appointments)
        #expect(versions.first?.entityID == operation.entityID)
        #expect(versions.first?.replacedLocalChange == true)
        #expect(versions.first?.payload == SyncFixtures.serverPayload(#"{"status":"confirmed"}"#))
    }

    @Test("A payment conflict is resolved the same way as a booking")
    func paymentConflictDiscardsTheLocalOperation() async {
        let store = InMemoryOfflineCache()
        let recorder = ServerVersionRecorder()
        let sender = FakeSyncSender(
            scripted: [.conflict(serverPayload: SyncFixtures.serverPayload(#"{"status":"paid"}"#))]
        )
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            applyServerVersion: recorder.handler()
        )

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.orders, secondsAgo: 60))
        _ = await engine.syncNow()

        let attempts = await sender.attempts
        #expect(attempts.count == 1)
        #expect(attempts.first?.overwritesServerVersion == false)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
        let versions = await recorder.versions
        #expect(versions.first?.replacedLocalChange == true)
    }

    @Test("A server-authoritative conflict without a body still drops the local write")
    func bookingConflictWithoutABodyStillDiscards() async {
        let store = InMemoryOfflineCache()
        let recorder = ServerVersionRecorder()
        let sender = FakeSyncSender(scripted: [.conflict(serverPayload: nil)])
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            applyServerVersion: recorder.handler()
        )

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.walletTransactions, secondsAgo: 30))
        _ = await engine.syncNow()

        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
        // Nothing to write back, so nothing is written back.
        let versions = await recorder.versions
        #expect(versions.isEmpty)
    }

    @Test("A discarded booking does not block the operations behind it")
    func discardedBookingDoesNotBlockTheQueue() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(
            scripted: [.conflict(serverPayload: nil), .delivered(serverPayload: nil)]
        )
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.appointments, secondsAgo: 200))
        let note = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 100)
        await engine.enqueue(note)

        let delivered = await engine.syncNow()

        #expect(delivered == 1)
        let attempts = await sender.attemptCount
        #expect(attempts == 2)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    // MARK: - Last-write-wins

    @Test("A note conflict is re-sent as an unconditional overwrite")
    func noteConflictRetriesAsAnOverwrite() async {
        let store = InMemoryOfflineCache()
        let recorder = ServerVersionRecorder()
        let sender = FakeSyncSender(
            scripted: [
                .conflict(serverPayload: SyncFixtures.serverPayload()),
                .delivered(serverPayload: nil),
            ]
        )
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            applyServerVersion: recorder.handler()
        )

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 45))
        let delivered = await engine.syncNow()

        #expect(delivered == 1)
        let attempts = await sender.attempts
        #expect(attempts.count == 2)
        // The first attempt is a normal conditional write; the second drops
        // the precondition, because repeating a request the server already
        // refused would just loop.
        #expect(attempts.first?.overwritesServerVersion == false)
        #expect(attempts.last?.overwritesServerVersion == true)
        #expect(attempts.map(\.operation.attemptCount) == [0, 1])

        // The local write won, so nothing of the server's is applied.
        let versions = await recorder.versions
        #expect(versions.isEmpty)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test("A note that keeps conflicting is parked, not looped forever")
    func repeatedNoteConflictsAreParked() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(fallback: .conflict(serverPayload: nil))
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 45))
        let delivered = await engine.syncNow()

        #expect(delivered == 0)
        let attempts = await sender.attemptCount
        #expect(attempts == SyncFixtures.instantRetries.maxAttempts)
        let pending = await engine.pendingOperations()
        #expect(pending.count == 1)
        #expect(pending.first?.attemptCount == SyncFixtures.instantRetries.maxAttempts)
        let state = await engine.state()
        #expect(state == .failed)
    }

    @Test("A custom policy replaces the default set wholesale")
    func customPolicyIsHonoured() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(
            scripted: [.conflict(serverPayload: nil), .delivered(serverPayload: nil)]
        )
        // Inventory made server-authoritative — a stock count is settled by
        // whichever till rang last, not by the device that reconnected last.
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            configuration: PRVSyncEngine.Configuration(
                maxAttempts: 3,
                baseBackoff: 0,
                maxBackoff: 0,
                jitterFraction: 0,
                conflictPolicy: SyncConflictPolicy(
                    serverAuthoritativeEntities: [SyncEntity.products]
                )
            )
        )

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.products, secondsAgo: 60))
        _ = await engine.syncNow()

        // Discarded on the first conflict, because this policy says so.
        let attempts = await sender.attemptCount
        #expect(attempts == 1)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test("Appointments are server-authoritative even when the queue is mixed")
    func mixedQueueAppliesTheRightRulePerEntity() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(fallback: .conflict(serverPayload: nil))
        let engine = SyncFixtures.engine(store: store, sender: sender)

        let booking = SyncFixtures.operation(entity: SyncEntity.appointments, secondsAgo: 200)
        let note = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 100)
        await engine.enqueue(booking)
        await engine.enqueue(note)

        _ = await engine.syncNow()

        // One attempt for the booking (discarded immediately) plus the note's
        // full retry budget.
        let attempts = await sender.attemptCount
        #expect(attempts == 1 + SyncFixtures.instantRetries.maxAttempts)
        let pending = await engine.pendingOperations()
        #expect(pending.map(\.id) == [note.id])
    }
}
