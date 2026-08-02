import Foundation
import os

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
