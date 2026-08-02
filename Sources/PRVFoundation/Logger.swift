import Foundation
#if canImport(os)
import os
#endif

#if canImport(os)

/// Structured, privacy-respecting logging for the whole platform.
/// Wraps `os.Logger` so call sites stay uniform and categories stay discoverable.
public enum PRVLog {
    public static let subsystem = "com.prv.beauty"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let booking = Logger(subsystem: subsystem, category: "booking")
    public static let payments = Logger(subsystem: subsystem, category: "payments")
    public static let chat = Logger(subsystem: subsystem, category: "chat")
    public static let analytics = Logger(subsystem: subsystem, category: "analytics")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}

#else

// The domain layer (models + booking/payments/loyalty kits) is pure Foundation
// and is built on Linux so its tests can run on cheap CI runners. `os` is
// Apple-only, so these shims give the same call-site surface — including the
// `privacy:` interpolation argument — and write to standard error. Shipping
// Apple builds always take the branch above.

/// Mirrors `OSLogPrivacy` so `\(value, privacy: .public)` compiles everywhere.
public enum PRVLogPrivacy: Sendable {
    case auto
    case `public`
    case `private`
}

/// A log message built from string interpolation, accepting the same
/// `privacy:` argument as `OSLogMessage`.
public struct PRVLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public let text: String

    public init(stringLiteral value: String) {
        text = value
    }

    public init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity)
        }

        public mutating func appendLiteral(_ literal: String) {
            text += literal
        }

        public mutating func appendInterpolation(
            _ value: String,
            privacy: PRVLogPrivacy = .auto
        ) {
            text += privacy == .private ? "<private>" : value
        }

        public mutating func appendInterpolation(
            _ value: some CustomStringConvertible,
            privacy: PRVLogPrivacy = .auto
        ) {
            text += privacy == .private ? "<private>" : value.description
        }
    }
}

/// Minimal stand-in for `os.Logger` on non-Apple platforms.
public struct PRVLogger: Sendable {
    private let label: String

    public init(subsystem: String, category: String) {
        label = "\(subsystem):\(category)"
    }

    private func emit(_ level: String, _ message: PRVLogMessage) {
        FileHandle.standardError.write(Data("[\(level)] \(label) \(message.text)\n".utf8))
    }

    public func debug(_ message: PRVLogMessage) { emit("debug", message) }
    public func info(_ message: PRVLogMessage) { emit("info", message) }
    public func notice(_ message: PRVLogMessage) { emit("notice", message) }
    public func warning(_ message: PRVLogMessage) { emit("warning", message) }
    public func error(_ message: PRVLogMessage) { emit("error", message) }
    public func fault(_ message: PRVLogMessage) { emit("fault", message) }
}

/// Structured, privacy-respecting logging for the whole platform.
public enum PRVLog {
    public static let subsystem = "com.prv.beauty"

    public static let app = PRVLogger(subsystem: subsystem, category: "app")
    public static let auth = PRVLogger(subsystem: subsystem, category: "auth")
    public static let network = PRVLogger(subsystem: subsystem, category: "network")
    public static let persistence = PRVLogger(subsystem: subsystem, category: "persistence")
    public static let sync = PRVLogger(subsystem: subsystem, category: "sync")
    public static let booking = PRVLogger(subsystem: subsystem, category: "booking")
    public static let payments = PRVLogger(subsystem: subsystem, category: "payments")
    public static let chat = PRVLogger(subsystem: subsystem, category: "chat")
    public static let analytics = PRVLogger(subsystem: subsystem, category: "analytics")
    public static let ui = PRVLogger(subsystem: subsystem, category: "ui")
}

#endif
