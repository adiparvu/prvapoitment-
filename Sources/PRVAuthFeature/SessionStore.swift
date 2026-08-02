import Foundation
import Security
import PRVFoundation
import PRVModels

/// Errors thrown by `SessionStore` keychain operations.
public enum SessionStoreError: Error, LocalizedError, Sendable, Equatable {
    /// The Security framework returned an unexpected status code.
    case unexpectedStatus(OSStatus)
    /// The stored payload exists but could not be decoded.
    case corruptedData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Secure storage failed (code \(status))."
        case .corruptedData:
            "The stored session could not be read."
        }
    }
}

/// The persisted authentication session: tokens plus just enough metadata to
/// restore the signed-in user on next launch.
public struct StoredSession: Codable, Hashable, Sendable {
    /// Bearer token sent with every authenticated API request.
    public var accessToken: String
    /// Long-lived token used to mint fresh access tokens, if issued.
    public var refreshToken: String?
    /// The signed-in user this session belongs to.
    public var userID: User.ID
    /// When the access token expires; `nil` means non-expiring (demo mode).
    public var expiresAt: Date?

    /// Creates a persisted session payload.
    public init(
        accessToken: String,
        refreshToken: String? = nil,
        userID: User.ID,
        expiresAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.expiresAt = expiresAt
    }

    /// Whether the access token is already past its expiry.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= .now
    }
}

/// Actor-isolated Keychain wrapper for session-token persistence.
///
/// Tokens are stored as a `kSecClassGenericPassword` item protected with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they never migrate
/// to other devices via backup or iCloud Keychain and stay readable for
/// background refresh after the first unlock.
public actor SessionStore {
    private let service: String
    private let account: String

    /// Creates a store bound to a keychain service/account pair. The defaults
    /// are correct for the app; tests may inject unique values for isolation.
    public init(service: String = "com.prv.beauty.session", account: String = "primary") {
        self.service = service
        self.account = account
    }

    /// Persists the session, replacing any previously stored one.
    public func save(_ session: StoredSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw SessionStoreError.corruptedData
        }

        // Replace-on-write keeps the logic branch-free: remove any existing
        // item, then add the fresh one.
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            PRVLog.auth.error("Keychain save failed with status \(status, privacy: .public)")
            throw SessionStoreError.unexpectedStatus(status)
        }
    }

    /// Loads the persisted session, or `nil` when none has been stored.
    public func load() throws -> StoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let session = try? JSONDecoder().decode(StoredSession.self, from: data)
            else {
                throw SessionStoreError.corruptedData
            }
            return session
        case errSecItemNotFound:
            return nil
        default:
            PRVLog.auth.error("Keychain load failed with status \(status, privacy: .public)")
            throw SessionStoreError.unexpectedStatus(status)
        }
    }

    /// Removes any persisted session. Succeeds silently when nothing exists.
    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            PRVLog.auth.error("Keychain clear failed with status \(status, privacy: .public)")
            throw SessionStoreError.unexpectedStatus(status)
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
