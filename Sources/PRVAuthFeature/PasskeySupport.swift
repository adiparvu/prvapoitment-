import Foundation
import AuthenticationServices
import PRVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// The result of a successful passkey registration, ready to be relayed to
/// the server for credential storage (WebAuthn attestation).
public struct PasskeyRegistration: Hashable, Sendable {
    /// Identifier of the newly created platform credential.
    public let credentialID: Data
    /// Raw client data JSON produced by the authenticator.
    public let clientDataJSON: Data
    /// Raw attestation object, when the authenticator provided one.
    public let attestationObject: Data?

    /// Creates a registration payload (normally produced by `PasskeyAuthenticator`).
    public init(credentialID: Data, clientDataJSON: Data, attestationObject: Data?) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
    }
}

/// The result of a successful passkey assertion (sign-in), ready for
/// server-side signature verification.
public struct PasskeyAssertion: Hashable, Sendable {
    /// Identifier of the credential that produced the assertion.
    public let credentialID: Data
    /// Raw client data JSON produced by the authenticator.
    public let clientDataJSON: Data
    /// Raw authenticator data covered by the signature.
    public let authenticatorData: Data
    /// The WebAuthn signature over challenge + authenticator data.
    public let signature: Data
    /// The user handle the credential was registered with, when available.
    public let userHandle: Data?

    /// Creates an assertion payload (normally produced by `PasskeyAuthenticator`).
    public init(
        credentialID: Data,
        clientDataJSON: Data,
        authenticatorData: Data,
        signature: Data,
        userHandle: Data?
    ) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
    }
}

/// User-presentable passkey errors. Every case carries copy suitable for
/// showing directly in the UI — no raw framework codes leak out.
public enum PasskeyError: Error, LocalizedError, Sendable, Equatable {
    /// The user dismissed the system passkey sheet.
    case canceled
    /// Passkeys are not available on this device or configuration.
    case notSupported
    /// The authenticator returned something we couldn't read.
    case invalidResponse
    /// Any other failure, already translated to friendly copy.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .canceled:
            "Passkey request was canceled."
        case .notSupported:
            "Passkeys aren't available on this device yet. You can sign in with your email instead."
        case .invalidResponse:
            "The passkey response couldn't be read. Please try again."
        case .failed(let message):
            message
        }
    }

    /// Wraps an arbitrary error, translating `ASAuthorizationError` codes to
    /// friendly messages and passing existing `PasskeyError`s through.
    init(wrapping error: any Error) {
        if let passkeyError = error as? PasskeyError {
            self = passkeyError
            return
        }
        guard let authorizationError = error as? ASAuthorizationError else {
            self = .failed("Something went wrong while using your passkey. Please try again.")
            return
        }
        switch authorizationError.code {
        case .canceled:
            self = .canceled
        case .invalidResponse:
            self = .invalidResponse
        case .notHandled, .notInteractive:
            self = .failed("The passkey prompt couldn't be shown. Please try again.")
        case .failed:
            self = .failed("Your passkey couldn't be verified. Please try again.")
        default:
            self = .failed("Something went wrong while using your passkey. Please try again.")
        }
    }
}

/// Clean async wrapper around `ASAuthorizationPlatformPublicKeyCredential`
/// registration and assertion flows.
///
/// The relying party identifier must match an associated domain of the app
/// (`webcredentials:` entitlement), and both challenges must be minted
/// server-side per WebAuthn — never generated on device.
@MainActor
public struct PasskeyAuthenticator {
    /// The relying party (domain) these credentials are scoped to.
    public let relyingPartyIdentifier: String

    /// Creates an authenticator scoped to the given relying party.
    public init(relyingPartyIdentifier: String) {
        self.relyingPartyIdentifier = relyingPartyIdentifier
    }

    /// Registers a new passkey for the given account.
    ///
    /// - Parameters:
    ///   - userName: The account name shown in the system passkey UI.
    ///   - userID: Stable server-issued user handle (opaque bytes).
    ///   - challenge: Server-minted registration challenge.
    /// - Returns: The attestation payload to relay to the server.
    /// - Throws: `PasskeyError` with user-presentable messaging.
    public func register(
        userName: String,
        userID: Data,
        challenge: Data
    ) async throws -> PasskeyRegistration {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyIdentifier
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: userName,
            userID: userID
        )
        let coordinator = PasskeyRequestCoordinator(anchor: Self.currentAnchor())
        do {
            let outcome = try await coordinator.perform([request])
            guard case .registration(let registration) = outcome else {
                throw PasskeyError.invalidResponse
            }
            PRVLog.auth.info("Passkey registered.")
            return registration
        } catch {
            throw PasskeyError(wrapping: error)
        }
    }

    /// Signs in with an existing passkey for this relying party.
    ///
    /// - Parameter challenge: Server-minted assertion challenge.
    /// - Returns: The signed assertion to relay to the server for verification.
    /// - Throws: `PasskeyError` with user-presentable messaging.
    public func signIn(challenge: Data) async throws -> PasskeyAssertion {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyIdentifier
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        let coordinator = PasskeyRequestCoordinator(anchor: Self.currentAnchor())
        do {
            let outcome = try await coordinator.perform([request])
            guard case .assertion(let assertion) = outcome else {
                throw PasskeyError.invalidResponse
            }
            PRVLog.auth.info("Passkey assertion completed.")
            return assertion
        } catch {
            throw PasskeyError(wrapping: error)
        }
    }

    /// Resolves the window the system passkey sheet should attach to.
    private static func currentAnchor() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
            ?? scenes.first?.windows.first {
            return window
        }
        #endif
        return ASPresentationAnchor()
    }
}

// MARK: - Coordinator

/// Bridges `ASAuthorizationController` delegate callbacks into a checked
/// continuation. Payloads are extracted into `Sendable` value types inside the
/// callback, and the lock guarantees the continuation resumes exactly once —
/// the basis for the `@unchecked Sendable` annotation.
private final class PasskeyRequestCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding,
    @unchecked Sendable {

    enum Outcome: Sendable {
        case registration(PasskeyRegistration)
        case assertion(PasskeyAssertion)
    }

    private let anchor: ASPresentationAnchor
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, any Error>?
    private var controller: ASAuthorizationController?

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    /// Runs the given authorization requests and suspends until the system
    /// sheet completes or fails.
    func perform(_ requests: [ASAuthorizationRequest]) async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            let controller = ASAuthorizationController(authorizationRequests: requests)
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<Outcome, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Outcome, any Error>? in
            defer {
                self.continuation = nil
                self.controller = nil
            }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        switch authorization.credential {
        case let registration as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            finish(.success(.registration(PasskeyRegistration(
                credentialID: registration.credentialID,
                clientDataJSON: registration.rawClientDataJSON,
                attestationObject: registration.rawAttestationObject
            ))))
        case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            finish(.success(.assertion(PasskeyAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature,
                userHandle: assertion.userID
            ))))
        default:
            finish(.failure(PasskeyError.invalidResponse))
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        finish(.failure(PasskeyError(wrapping: error)))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor
    }
}
