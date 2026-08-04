import Foundation
import Security
import PRVFoundation
import PRVNetworking

/// Persists the Supabase session in the Keychain so a signed-in user stays
/// signed in across launches.
///
/// The item is stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// background refresh and push handling need to read it while the device is
/// locked, but the session must never sync to another device or ride along in
/// an encrypted backup. It is the only place an access or refresh token is
/// written — tokens never reach `UserDefaults`, a log, or an analytics payload.
public actor KeychainTokenStore: SupabaseTokenStore {
    private let service: String
    private let account: String

    /// Caches the decoded session so the common path — an authorized request
    /// while the app is warm — does not hit the Keychain every time.
    private var cached: SupabaseSession?
    private var hasLoaded = false

    /// Creates a store.
    /// - Parameters:
    ///   - service: Keychain service name; defaults to the bundle identifier so
    ///     debug and release builds cannot read each other's sessions.
    ///   - account: Distinguishes this item from any other the app stores.
    public init(
        service: String = Bundle.main.bundleIdentifier ?? "com.prv.beauty.app",
        account: String = "supabase.session"
    ) {
        self.service = service
        self.account = account
    }

    public func load() async -> SupabaseSession? {
        if hasLoaded { return cached }
        hasLoaded = true

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                PRVLog.auth.error("Keychain read failed with status \(status, privacy: .public)")
            }
            return nil
        }

        cached = try? JSONDecoder().decode(SupabaseSession.self, from: data)
        if cached == nil {
            // A session we cannot decode is worse than none: drop it so the
            // next sign-in starts clean rather than looping on a bad refresh.
            PRVLog.auth.error("Stored session could not be decoded; discarding it")
            await clear()
        }
        return cached
    }

    public func save(_ session: SupabaseSession) async {
        cached = session
        hasLoaded = true

        guard let data = try? JSONEncoder().encode(session) else {
            PRVLog.auth.error("Session could not be encoded for the Keychain")
            return
        }

        // SecItemUpdate only succeeds when the item exists, so delete-then-add
        // keeps this a single unconditional path.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            PRVLog.auth.error("Keychain write failed with status \(status, privacy: .public)")
        }
    }

    public func clear() async {
        cached = nil
        hasLoaded = true
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            PRVLog.auth.error("Keychain delete failed with status \(status, privacy: .public)")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
