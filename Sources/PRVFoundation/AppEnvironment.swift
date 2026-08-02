import Foundation

/// The deployment environment the app is running against.
public enum AppEnvironment: String, Sendable, CaseIterable {
    case development
    case staging
    case production

    /// Resolved from the bundle configuration; defaults to `.production`
    /// so a misconfigured build can never point at development data.
    public static var current: AppEnvironment {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PRVEnvironment") as? String,
              let env = AppEnvironment(rawValue: raw)
        else { return .production }
        return env
    }

    public var supabaseURL: URL {
        switch self {
        case .development: URL(string: "https://dev.api.prvbeauty.com")!
        case .staging: URL(string: "https://staging.api.prvbeauty.com")!
        case .production: URL(string: "https://api.prvbeauty.com")!
        }
    }
}
