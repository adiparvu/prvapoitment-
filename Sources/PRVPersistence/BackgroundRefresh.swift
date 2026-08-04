#if canImport(BackgroundTasks)
import BackgroundTasks
import Foundation
import PRVFoundation

/// Registers and services the app's background refresh task.
///
/// The system wakes the app on its own schedule; each wake does three things,
/// in this order:
///
/// 1. **drains the sync queue** — notes written at the chair reach Postgres
///    without anyone reopening the app,
/// 2. **refreshes the widget snapshot** — the Lock Screen and Home Screen show
///    tomorrow's appointment, not yesterday's,
/// 3. **prunes the cache** — a store that only ever grows is a bug with a long
///    fuse.
///
/// Wire it up once, during launch:
///
/// ```swift
/// PRVBackgroundRefresh.register(
///     job: PRVBackgroundRefresh.Job(sync: engine, cache: cache) {
///         await WidgetSyncService.refresh(using: deps, for: user)
///     }
/// )
/// PRVBackgroundRefresh.schedule()
/// ```
///
/// - Important: `BGTaskSchedulerPermittedIdentifiers` in the app's `Info.plist`
///   must contain ``taskIdentifier``, and the target needs the `fetch`
///   background mode. Registration throws at runtime otherwise — by design, so
///   the mistake is impossible to ship unnoticed.
public enum PRVBackgroundRefresh {
    /// The task identifier declared in `Info.plist`.
    public static let taskIdentifier = "com.prv.beauty.refresh"

    /// Scheduling knobs.
    public struct Configuration: Sendable {
        /// Earliest the system may run the next refresh, in seconds from now.
        ///
        /// A floor, not a promise: iOS decides the real cadence from usage,
        /// battery, and network conditions.
        public var earliestInterval: TimeInterval
        /// How much cached history to keep when pruning.
        public var cacheRetention: TimeInterval

        /// Creates a configuration. The defaults ask for a refresh every
        /// fifteen minutes and keep a month of history.
        public init(
            earliestInterval: TimeInterval = 15 * 60,
            cacheRetention: TimeInterval = 30 * 24 * 60 * 60
        ) {
            self.earliestInterval = max(60, earliestInterval)
            self.cacheRetention = max(0, cacheRetention)
        }
    }

    /// The work one background wake performs.
    ///
    /// A value type holding only `Sendable` collaborators, so it can be
    /// captured by the launch handler and run off any executor.
    public struct Job: Sendable {
        private let sync: any SyncEngine
        private let cache: (any OfflineCacheMaintenance)?
        private let cacheRetention: TimeInterval
        private let refreshSnapshot: @Sendable () async -> Void

        /// Creates the job.
        /// - Parameters:
        ///   - sync: Engine whose queue should be drained.
        ///   - cache: Store to prune. Pass `nil` to skip pruning.
        ///   - cacheRetention: How much history to keep when pruning.
        ///   - refreshSnapshot: Rebuilds and publishes the widget snapshot.
        public init(
            sync: any SyncEngine,
            cache: (any OfflineCacheMaintenance)? = nil,
            cacheRetention: TimeInterval = 30 * 24 * 60 * 60,
            refreshSnapshot: @escaping @Sendable () async -> Void
        ) {
            self.sync = sync
            self.cache = cache
            self.cacheRetention = max(0, cacheRetention)
            self.refreshSnapshot = refreshSnapshot
        }

        /// Runs the job.
        ///
        /// Cancellation-aware at every step: when the system expires the task
        /// the remaining work is skipped rather than risking a kill.
        /// - Returns: `true` when the run finished without being cancelled.
        public func run() async -> Bool {
            let delivered = await sync.syncNow()
            PRVLog.sync.notice("Background refresh delivered \(delivered) queued operation(s)")
            guard !Task.isCancelled else { return false }

            await refreshSnapshot()
            guard !Task.isCancelled else { return false }

            if let cache {
                await cache.prune(olderThan: cacheRetention)
            }
            return !Task.isCancelled
        }
    }

    /// Registers the launch handler. Call before the app finishes launching,
    /// and only once — the system treats a second registration for the same
    /// identifier as a programmer error.
    /// - Parameters:
    ///   - job: The work each wake performs.
    ///   - configuration: Scheduling knobs, reused when the handler chains the
    ///     next request.
    /// - Returns: `true` when the handler was registered.
    @MainActor
    @discardableResult
    public static func register(job: Job, configuration: Configuration = Configuration()) -> Bool {
        guard !isRegistered else { return true }

        // Built with an explicit `@Sendable` type: the handler runs on a queue
        // BackgroundTasks owns, so it must capture nothing but `Sendable`
        // values — here, the job and the configuration.
        let handler: @Sendable (BGTask) -> Void = { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            run(task: refreshTask, job: job, configuration: configuration)
        }

        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil,
            launchHandler: handler
        )
        if !isRegistered {
            PRVLog.app.error(
                "BGTaskScheduler refused \(taskIdentifier, privacy: .public) — check BGTaskSchedulerPermittedIdentifiers"
            )
        }
        return isRegistered
    }

    /// Asks the system for another refresh.
    ///
    /// Safe to call repeatedly: submitting the same identifier replaces the
    /// pending request rather than queuing a second one. Call at launch, when
    /// the app goes to the background, and after each run (the handler does
    /// this itself).
    /// - Parameter configuration: Scheduling knobs.
    public static func schedule(configuration: Configuration = Configuration()) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: configuration.earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator, a device with Background App Refresh switched off, or
            // too many pending requests. None of these are user-facing: the
            // app still syncs on foreground.
            PRVLog.app.notice("Background refresh not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    /// Cancels any pending refresh — sign-out, account deletion.
    public static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    // MARK: - Handling a wake

    /// Services one wake.
    ///
    /// The next request is submitted **first**: if the run is expired or the
    /// process is killed, the chain must not break.
    private static func run(task: BGAppRefreshTask, job: Job, configuration: Configuration) {
        schedule(configuration: configuration)

        let box = ExpiringTask(task: task)
        let work = Task.detached(priority: .utility) {
            let finished = await job.run()
            box.complete(success: finished)
        }
        // The required expiration handler: the system is reclaiming the run,
        // so cancel the work and let it complete the task on its way out.
        task.expirationHandler = {
            PRVLog.app.notice("Background refresh expired; cancelling in-flight work")
            work.cancel()
        }
    }

    /// Carries the `BGAppRefreshTask` into the async work.
    ///
    /// `BGTask` predates Swift Concurrency and is not `Sendable`. Completion
    /// may be signalled from any thread and exactly once, which this box
    /// guarantees — keeping the unchecked assumption in one auditable place
    /// instead of spreading it across the handler.
    private struct ExpiringTask: @unchecked Sendable {
        private let task: BGAppRefreshTask
        private let hasCompleted = CompletionFlag()

        init(task: BGAppRefreshTask) {
            self.task = task
        }

        /// Marks the run finished, ignoring any later duplicate.
        func complete(success: Bool) {
            guard hasCompleted.claim() else { return }
            task.setTaskCompleted(success: success)
        }
    }

    /// A one-shot flag: the first claimant wins.
    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var isClaimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }

    @MainActor
    private static var isRegistered = false
}
#endif
