import Foundation
import PRVModels
import PRVPersistence

// Test doubles for the offline-first sync layer.
//
// `PRVSyncEngine` takes its transport and its connectivity as injected
// values precisely so it can be driven deterministically: no URLSession, no
// `NWPathMonitor`, no wall-clock waiting beyond the backoff a test asks for.

/// A scripted stand-in for the real Supabase sender.
///
/// Outcomes are consumed in order; once the script runs out, ``fallback`` is
/// returned for every further attempt. That makes both shapes of test easy to
/// write: "fails twice, then succeeds" (a script) and "never succeeds" (a
/// fallback).
actor FakeSyncSender {
    private var scripted: [SyncSendResult]
    private let fallback: SyncSendResult
    private var recorded: [SyncAttempt] = []

    /// Creates a sender.
    /// - Parameters:
    ///   - scripted: Outcomes to return, in order.
    ///   - fallback: Outcome returned once the script is exhausted.
    init(
        scripted: [SyncSendResult] = [],
        fallback: SyncSendResult = .delivered(serverPayload: nil)
    ) {
        self.scripted = scripted
        self.fallback = fallback
    }

    /// Every attempt the engine made, oldest first.
    var attempts: [SyncAttempt] { recorded }

    /// How many times the engine tried to deliver anything.
    var attemptCount: Int { recorded.count }

    /// The entities the engine tried to deliver, in the order it tried them.
    var deliveredEntityIDs: [UUID] { recorded.map(\.operation.entityID) }

    /// The transport closure to hand to ``PRVSyncEngine``.
    nonisolated func sender() -> SyncSender {
        { attempt in await self.handle(attempt) }
    }

    private func handle(_ attempt: SyncAttempt) -> SyncSendResult {
        recorded.append(attempt)
        guard !scripted.isEmpty else { return fallback }
        return scripted.removeFirst()
    }
}

/// Records the server-canonical rows the engine hands back for caching.
actor ServerVersionRecorder {
    private(set) var versions: [SyncServerVersion] = []

    /// The handler to hand to ``PRVSyncEngine``.
    nonisolated func handler() -> SyncServerVersionHandler {
        { version in await self.record(version) }
    }

    private func record(_ version: SyncServerVersion) {
        versions.append(version)
    }
}

/// Connectivity the test drives by hand.
///
/// `ReachabilityMonitoring.onlineChanges()` is synchronous, so this is a
/// lock-guarded class rather than an actor. Nothing escapes the lock, which is
/// what makes the unchecked conformance safe.
final class FakeReachability: ReachabilityMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var online: Bool
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    /// Creates a monitor in the given state.
    init(online: Bool = true) {
        self.online = online
    }

    /// A monitor that reports a healthy connection.
    static func connected() -> FakeReachability { FakeReachability(online: true) }

    /// A monitor that reports no usable connection.
    static func disconnected() -> FakeReachability { FakeReachability(online: false) }

    func start() async {}

    func isOnline() async -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    func onlineChanges() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            observers[id] = continuation
            let current = online
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.observers.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Flips connectivity and notifies every observer.
    func set(online newValue: Bool) {
        lock.lock()
        online = newValue
        let continuations = Array(observers.values)
        lock.unlock()
        for continuation in continuations {
            continuation.yield(newValue)
        }
    }
}

/// Fixtures and factories shared by the sync suites.
enum SyncFixtures {
    /// Retry tuning with the waiting taken out, for the tests that are about
    /// *what* the engine does rather than *when*.
    static let instantRetries = PRVSyncEngine.Configuration(
        maxAttempts: 3,
        baseBackoff: 0,
        maxBackoff: 0,
        jitterFraction: 0
    )

    /// Retry tuning with a small, deterministic (jitter-free) delay, for the
    /// one test that asserts the backoff exists at all.
    static let measurableBackoff = PRVSyncEngine.Configuration(
        maxAttempts: 3,
        baseBackoff: 0.05,
        maxBackoff: 1,
        jitterFraction: 0
    )

    /// A queued mutation.
    /// - Parameters:
    ///   - entity: Backend table name, e.g. ``SyncEntity/clientNotes``.
    ///   - kind: Create, update, or delete.
    ///   - secondsAgo: How long ago the mutation was made locally, which is
    ///     what the queue orders by.
    ///   - payload: JSON body.
    static func operation(
        entity: String,
        kind: SyncOperation.Kind = .update,
        secondsAgo: TimeInterval,
        payload: String = #"{"text":"local"}"#
    ) -> SyncOperation {
        SyncOperation(
            kind: kind,
            entity: entity,
            entityID: UUID(),
            payload: Data(payload.utf8),
            createdAt: Date.now.addingTimeInterval(-secondsAgo)
        )
    }

    /// A server-canonical row, as a `.conflict` or `.delivered` payload.
    static func serverPayload(_ json: String = #"{"text":"server"}"#) -> Data {
        Data(json.utf8)
    }

    /// Builds an engine over an in-memory queue.
    static func engine(
        store: any SyncOperationStore,
        sender: FakeSyncSender,
        reachability: FakeReachability = FakeReachability.connected(),
        configuration: PRVSyncEngine.Configuration = SyncFixtures.instantRetries,
        applyServerVersion: @escaping SyncServerVersionHandler = { _ in }
    ) -> PRVSyncEngine {
        PRVSyncEngine(
            store: store,
            reachability: reachability,
            configuration: configuration,
            applyServerVersion: applyServerVersion,
            send: sender.sender()
        )
    }
}
