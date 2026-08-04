import Foundation
import PRVModels
import PRVPersistence
import Testing

/// The queue half of the offline-first contract: what the engine sends, in
/// what order, how often, and what it does when the connection is not there.
@Suite("Sync engine — draining the queue")
struct SyncEngineDrainTests {
    // MARK: - Ordering

    @Test("Operations are delivered oldest-first, whatever order they were queued in")
    func drainIsFIFOByCreationTime() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender()
        let engine = SyncFixtures.engine(store: store, sender: sender)

        // A note created offline and then edited must reach the server in that
        // sequence, so the queue orders by when the *mutation* happened — not
        // by when it happened to be enqueued.
        let oldest = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 300)
        let middle = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 200)
        let newest = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 100)

        await engine.enqueue(middle)
        await engine.enqueue(newest)
        await engine.enqueue(oldest)

        let delivered = await engine.syncNow()

        #expect(delivered == 3)
        let order = await sender.deliveredEntityIDs
        #expect(order == [oldest.entityID, middle.entityID, newest.entityID])
    }

    @Test("Delivered operations leave the queue")
    func deliveredOperationsAreRemoved() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender()
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.reviews, secondsAgo: 60))
        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.messages, secondsAgo: 30))

        let pendingBefore = await engine.pendingOperations()
        #expect(pendingBefore.count == 2)

        _ = await engine.syncNow()

        let pendingAfter = await engine.pendingOperations()
        #expect(pendingAfter.isEmpty)
        let state = await engine.state()
        #expect(state == .idle)
    }

    @Test("A delivered row the server echoed back is written into the cache")
    func serverEchoRefreshesTheCache() async {
        let store = InMemoryOfflineCache()
        let recorder = ServerVersionRecorder()
        let sender = FakeSyncSender(
            scripted: [.delivered(serverPayload: SyncFixtures.serverPayload())]
        )
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            applyServerVersion: recorder.handler()
        )
        let operation = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 10)

        await engine.enqueue(operation)
        _ = await engine.syncNow()

        let versions = await recorder.versions
        #expect(versions.count == 1)
        #expect(versions.first?.entity == SyncEntity.clientNotes)
        #expect(versions.first?.entityID == operation.entityID)
        // Nothing was overruled — this is just the canonical copy.
        #expect(versions.first?.replacedLocalChange == false)
    }

    @Test("A delivery with no echoed row leaves the cache alone")
    func deliveryWithoutEchoTouchesNothing() async {
        let store = InMemoryOfflineCache()
        let recorder = ServerVersionRecorder()
        let sender = FakeSyncSender(scripted: [.delivered(serverPayload: nil)])
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            applyServerVersion: recorder.handler()
        )

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.shifts, secondsAgo: 5))
        _ = await engine.syncNow()

        let versions = await recorder.versions
        #expect(versions.isEmpty)
    }

    // MARK: - Offline

    @Test("With no connection nothing is sent and the queue is kept")
    func offlineQueuesInsteadOfSending() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender()
        let reachability = FakeReachability.disconnected()
        let engine = SyncFixtures.engine(store: store, sender: sender, reachability: reachability)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        let delivered = await engine.syncNow()

        #expect(delivered == 0)
        let attempts = await sender.attemptCount
        #expect(attempts == 0)
        let pending = await engine.pendingOperations()
        #expect(pending.count == 1)
        let state = await engine.state()
        #expect(state == .offline)
    }

    @Test("Work queued offline drains once the connection returns")
    func queuedWorkDrainsWhenConnectivityReturns() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender()
        let reachability = FakeReachability.disconnected()
        let engine = SyncFixtures.engine(store: store, sender: sender, reachability: reachability)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 120))
        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        #expect(await engine.syncNow() == 0)

        reachability.set(online: true)
        let delivered = await engine.syncNow()

        #expect(delivered == 2)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test("Losing the connection mid-drain stops cleanly and keeps the rest")
    func connectionLostMidDrainStopsCleanly() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(
            scripted: [.delivered(serverPayload: nil), .offline]
        )
        let engine = SyncFixtures.engine(store: store, sender: sender)

        let first = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 300)
        let second = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 200)
        let third = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 100)
        await engine.enqueue(first)
        await engine.enqueue(second)
        await engine.enqueue(third)

        let delivered = await engine.syncNow()

        #expect(delivered == 1)
        // The drain stops at the offline result: the third operation is never
        // even attempted, so the queue keeps its order for the next pass.
        let attempts = await sender.attemptCount
        #expect(attempts == 2)
        let pending = await engine.pendingOperations()
        #expect(pending.map(\.id) == [second.id, third.id])
    }

    // MARK: - Retry

    @Test("A transient failure is retried until it succeeds")
    func transientFailuresAreRetried() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(
            scripted: [
                .retryable(reason: "503"),
                .retryable(reason: "connection reset"),
                .delivered(serverPayload: nil),
            ]
        )
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 30))
        let delivered = await engine.syncNow()

        #expect(delivered == 1)
        let attempts = await sender.attempts
        #expect(attempts.count == 3)
        // Each retry carries the incremented attempt count, so the sender can
        // decide to give up early or log a genuine failure rate.
        #expect(attempts.map(\.operation.attemptCount) == [0, 1, 2])
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test("Retries actually wait between attempts")
    func retriesBackOff() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(
            scripted: [.retryable(reason: "503"), .retryable(reason: "503"), .delivered(serverPayload: nil)]
        )
        let engine = SyncFixtures.engine(
            store: store,
            sender: sender,
            configuration: SyncFixtures.measurableBackoff
        )

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 10))

        let started = Date.now
        _ = await engine.syncNow()
        let elapsed = Date.now.timeIntervalSince(started)

        // 50 ms then 100 ms, jitter switched off. The floor is deliberately
        // well below the total so a busy machine cannot make this flaky.
        #expect(elapsed >= 0.1)
    }

    @Test("An operation is parked once it hits the attempt cap")
    func attemptCapParksTheOperation() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(fallback: .retryable(reason: "gateway timeout"))
        let engine = SyncFixtures.engine(store: store, sender: sender)
        let operation = SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 30)

        await engine.enqueue(operation)
        let delivered = await engine.syncNow()

        #expect(delivered == 0)
        let attempts = await sender.attemptCount
        #expect(attempts == SyncFixtures.instantRetries.maxAttempts)

        // Parked, not dropped: the work is still the user's, and the
        // diagnostics screen has to be able to show it.
        let pending = await engine.pendingOperations()
        #expect(pending.count == 1)
        #expect(pending.first?.attemptCount == SyncFixtures.instantRetries.maxAttempts)
        let reason = await store.failureReason(for: operation.id)
        #expect(reason == "gateway timeout")
        let state = await engine.state()
        #expect(state == .failed)
    }

    @Test("A parked operation does not wedge the queue behind it")
    func parkedOperationsAreSkipped() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(fallback: .retryable(reason: "503"))
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        _ = await engine.syncNow()
        let afterFirstDrain = await sender.attemptCount

        // A second drain must not re-attempt the parked operation…
        _ = await engine.syncNow()
        #expect(await sender.attemptCount == afterFirstDrain)

        // …and must still deliver anything queued behind it.
        let sender2 = FakeSyncSender(fallback: .delivered(serverPayload: nil))
        let engine2 = SyncFixtures.engine(store: store, sender: sender2)
        await engine2.enqueue(SyncFixtures.operation(entity: SyncEntity.reviews, secondsAgo: 10))

        let delivered = await engine2.syncNow()
        #expect(delivered == 1)
        let stillPending = await engine2.pendingOperations()
        #expect(stillPending.count == 1)
        #expect(stillPending.first?.entity == SyncEntity.clientNotes)
    }

    @Test("Retrying failures un-parks them for another pass")
    func retryFailedRevivesParkedOperations() async {
        let store = InMemoryOfflineCache()
        let failing = FakeSyncSender(fallback: .retryable(reason: "503"))
        let engine = SyncFixtures.engine(store: store, sender: failing)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        _ = await engine.syncNow()
        #expect(await engine.state() == .failed)

        let reset = await engine.retryFailed()
        #expect(reset == 1)
        let revived = await engine.pendingOperations()
        #expect(revived.first?.attemptCount == 0)
        #expect(await engine.state() == .idle)

        let healthy = FakeSyncSender()
        let engine2 = SyncFixtures.engine(store: store, sender: healthy)
        #expect(await engine2.syncNow() == 1)
        #expect(await engine2.pendingOperations().isEmpty)
    }

    @Test("An operation the server will never accept is dropped, not retried")
    func rejectedOperationsAreDropped() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(
            scripted: [.rejected(reason: "row no longer exists")]
        )
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, kind: .delete, secondsAgo: 30))
        let delivered = await engine.syncNow()

        // Not counted as delivered — but gone, so it cannot block the queue.
        #expect(delivered == 0)
        let attempts = await sender.attemptCount
        #expect(attempts == 1)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    // MARK: - Concurrency and lifecycle

    @Test("Two drains at once deliver each operation exactly once")
    func concurrentDrainsDoNotDoubleSend() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender()
        let engine = SyncFixtures.engine(store: store, sender: sender)

        for offset in 0 ..< 4 {
            await engine.enqueue(
                SyncFixtures.operation(entity: SyncEntity.messages, secondsAgo: Double(100 - offset))
            )
        }

        // A foreground drain and a background-refresh drain can genuinely race.
        async let first = engine.syncNow()
        async let second = engine.syncNow()
        let counts = await [first, second]

        #expect(counts.reduce(0, +) == 4)
        let attempts = await sender.attemptCount
        #expect(attempts == 4)
        let pending = await engine.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test("Discarding the queue destroys everything in it")
    func discardQueueClearsPendingWork() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender(fallback: .retryable(reason: "503"))
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        _ = await engine.syncNow()
        #expect(await engine.state() == .failed)

        await engine.discardQueue()

        #expect(await engine.pendingOperations().isEmpty)
        #expect(await engine.state() == .idle)
    }

    @Test("The queue survives clearing the read cache")
    func clearingTheCacheKeepsUnsentWork() async {
        let store = InMemoryOfflineCache()
        let sender = FakeSyncSender()
        let engine = SyncFixtures.engine(store: store, sender: sender)

        await engine.enqueue(SyncFixtures.operation(entity: SyncEntity.clientNotes, secondsAgo: 60))
        await store.write(["cached"], key: "salons/trending")

        // `removeAll()` is the sign-out cache purge; unsent local writes are
        // work, not a copy of something the server already has.
        await store.removeAll()

        let cached: [String]? = await store.read([String].self, key: "salons/trending")
        #expect(cached == nil)
        let pending = await engine.pendingOperations()
        #expect(pending.count == 1)
    }
}
