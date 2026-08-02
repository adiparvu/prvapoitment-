import Foundation
import Observation

/// A single remotely-configurable feature flag.
public enum FeatureFlag: String, CaseIterable, Sendable {
    case aiAssistant = "ai_assistant"
    case aiSearch = "ai_search"
    case groupBooking = "group_booking"
    case giftCards = "gift_cards"
    case memberships = "memberships"
    case packages = "packages"
    case liveActivities = "live_activities"
    case virtualTour = "virtual_tour"
    case tikTokFeed = "tiktok_feed"
    case instagramFeed = "instagram_feed"
    case referralProgram = "referral_program"
    case dailyRewards = "daily_rewards"
    case smartCalendarOptimization = "smart_calendar_optimization"
    case fraudDetection = "fraud_detection"
    case multiSalon = "multi_salon"

    /// Conservative default used before remote configuration is fetched.
    public var defaultValue: Bool {
        switch self {
        case .virtualTour, .tikTokFeed: false
        default: true
        }
    }
}

/// Observable store of feature flags. Remote values (Supabase `feature_flags`
/// table) override defaults; overrides persist across launches so the app is
/// consistent offline.
@Observable
@MainActor
public final class FeatureFlagStore {
    public static let shared = FeatureFlagStore()

    private var overrides: [FeatureFlag: Bool]
    private static let defaultsKey = "prv.featureFlags.overrides"

    public init() {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Bool] {
            var restored: [FeatureFlag: Bool] = [:]
            for (key, value) in stored {
                if let flag = FeatureFlag(rawValue: key) { restored[flag] = value }
            }
            overrides = restored
        } else {
            overrides = [:]
        }
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        overrides[flag] ?? flag.defaultValue
    }

    /// Applies a remote configuration payload (flag raw value → enabled).
    public func apply(remote: [String: Bool]) {
        for (key, value) in remote {
            guard let flag = FeatureFlag(rawValue: key) else { continue }
            overrides[flag] = value
        }
        persist()
    }

    public func setOverride(_ value: Bool?, for flag: FeatureFlag) {
        overrides[flag] = value
        persist()
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
    }
}
