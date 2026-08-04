import Foundation

/// A callback that must run exactly once, from whatever thread gets there first.
///
/// Both payment sheets in this module hand back a completion handler that Apple
/// does not mark `Sendable` and that must be invoked precisely once: PassKit's
/// `PKPaymentAuthorizationResult` handler, and the continuation behind
/// `ASWebAuthenticationSession`. Calling either twice traps; never calling it
/// hangs the sheet forever.
///
/// This box makes both safe to carry into a `Task` and both safe to race:
///
/// - `@unchecked Sendable` is the deliberate assertion that the wrapped closure
///   is only ever *invoked* through ``run(_:)``, which serializes on a lock and
///   drops every call after the first. The closure itself is never handed out.
/// - Dropping the reference after the first call releases whatever the closure
///   captured — a continuation, a delegate — at the moment the flow ends rather
///   than when the sheet is finally deallocated.
final class OneShotHandler<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?

    /// Wraps a handler that must run at most once.
    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    /// Runs the handler with `value`, if it has not run already.
    ///
    /// - Returns: `true` when this call was the one that ran it.
    @discardableResult
    func run(_ value: Value) -> Bool {
        let pending = lock.withLock { () -> ((Value) -> Void)? in
            let stored = handler
            handler = nil
            return stored
        }
        guard let pending else { return false }
        pending(value)
        return true
    }

    /// Whether the handler is still waiting to run.
    var isPending: Bool {
        lock.withLock { handler != nil }
    }
}

/// A one-shot bridge from a callback to a `CheckedContinuation`, tolerant of
/// the callback arriving first.
///
/// `ASWebAuthenticationSession` is created, configured, and started *before*
/// there is a continuation to resume — and a session that fails to start can
/// call back synchronously. Buffering the value until the continuation attaches
/// removes that race, and removes the need to build the session inside a
/// `withCheckedContinuation` body whose isolation is not ours to assume.
///
/// `@unchecked Sendable` is the assertion that every access goes through the
/// lock below; neither stored value is ever handed out.
final class ContinuationRelay<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var buffered: Value?
    private var isResolved = false

    /// Creates an unresolved relay.
    init() {}

    /// Hands the relay the continuation to resume. Resumes immediately when
    /// the value already arrived.
    func attach(_ continuation: CheckedContinuation<Value, Never>) {
        let ready = lock.withLock { () -> Value? in
            if let value = buffered {
                buffered = nil
                return value
            }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    /// Delivers the outcome. Every call after the first is ignored, so a
    /// callback that fires twice cannot resume a consumed continuation.
    func resolve(_ value: Value) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            guard !isResolved else { return nil }
            isResolved = true
            if let pending = continuation {
                continuation = nil
                return pending
            }
            buffered = value
            return nil
        }
        waiting?.resume(returning: value)
    }
}
