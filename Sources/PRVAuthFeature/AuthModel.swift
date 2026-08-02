import Foundation
import Observation
import AuthenticationServices
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVDesignSystem

/// Screen model backing `AuthRootView`: email form state, inline validation,
/// and the sign-in / sign-up / Sign in with Apple flows against the injected
/// `AuthService`. On success it updates the shared `UserSession` and plays the
/// success haptic; failures surface as friendly, human error messages.
@Observable
@MainActor
final class AuthModel {
    /// Which email form is currently showing.
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case signIn
        case signUp

        var id: String { rawValue }

        /// Segmented-control label and call-to-action title.
        var title: String {
            switch self {
            case .signIn: "Sign In"
            case .signUp: "Create Account"
            }
        }
    }

    /// Lifecycle of the current authentication attempt.
    enum Phase: Equatable, Sendable {
        case idle
        case working
        case failed(String)
    }

    var mode: Mode = .signIn
    var email = ""
    var password = ""
    var firstName = ""
    var lastName = ""
    private(set) var phase: Phase = .idle

    var isWorking: Bool { phase == .working }

    /// Friendly message describing the last failure, if any.
    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    // MARK: - Validation

    /// Inline validation for the email field; `nil` while empty or valid.
    var emailIssue: String? {
        guard !email.isBlank else { return nil }
        return Self.isValidEmail(email.trimmed) ? nil : "That doesn't look like a valid email address."
    }

    /// Inline validation for the password field; `nil` while empty or valid.
    var passwordIssue: String? {
        guard !password.isEmpty else { return nil }
        return password.count >= 8 ? nil : "Passwords need at least 8 characters."
    }

    /// Inline validation for the sign-up name fields; `nil` until one of the
    /// two names has been typed but not the other.
    var namesIssue: String? {
        guard mode == .signUp else { return nil }
        guard !firstName.isBlank || !lastName.isBlank else { return nil }
        return (!firstName.isBlank && !lastName.isBlank)
            ? nil
            : "Please tell us both your first and last name."
    }

    /// Whether the current form contents are complete and valid.
    var canSubmit: Bool {
        guard !isWorking,
              Self.isValidEmail(email.trimmed),
              password.count >= 8
        else { return false }
        if mode == .signUp {
            return !firstName.isBlank && !lastName.isBlank
        }
        return true
    }

    /// Switches between sign-in and sign-up, clearing any stale error.
    func select(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if case .failed = phase { phase = .idle }
        PRVHaptics.tap()
    }

    // MARK: - Actions

    /// Submits the email form (sign-in or sign-up depending on `mode`).
    func submitEmailForm(using deps: PRVDependencies, session: UserSession) async {
        guard canSubmit else { return }
        phase = .working
        do {
            let user: User = switch mode {
            case .signIn:
                try await deps.auth.signIn(email: email.trimmed, password: password)
            case .signUp:
                try await deps.auth.signUp(
                    email: email.trimmed,
                    password: password,
                    firstName: firstName.trimmed,
                    lastName: lastName.trimmed
                )
            }
            complete(with: user, session: session)
        } catch {
            fail(with: error)
        }
    }

    /// Completes Sign in with Apple using the identity token extracted from
    /// the `ASAuthorizationAppleIDCredential`.
    func signInWithApple(
        identityToken: Data,
        fullName: String?,
        using deps: PRVDependencies,
        session: UserSession
    ) async {
        phase = .working
        do {
            let user = try await deps.auth.signInWithApple(
                identityToken: identityToken,
                fullName: fullName
            )
            complete(with: user, session: session)
        } catch {
            fail(with: error)
        }
    }

    /// Handles a failed Apple authorization. User cancellation is treated as a
    /// non-event; everything else surfaces a friendly error.
    func appleSignInFailed(_ error: any Error) {
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            phase = .idle
            return
        }
        fail(with: error)
    }

    /// Called when Apple returned an authorization without a usable credential.
    func appleSignInMissingCredential() {
        PRVHaptics.error()
        phase = .failed("Apple didn't return a usable credential. Please try again.")
    }

    // MARK: - Private

    private func complete(with user: User, session: UserSession) {
        phase = .idle
        session.signedIn(user)
        PRVHaptics.success()
        PRVLog.auth.info("Signed in with role \(user.role.rawValue, privacy: .public)")
    }

    private func fail(with error: any Error) {
        PRVHaptics.error()
        phase = .failed(Self.friendlyMessage(for: error))
        PRVLog.auth.error("Authentication failed: \(String(describing: error), privacy: .public)")
    }

    // MARK: - Helpers

    /// Pragmatic email shape check: exactly one `@`, a non-empty local part,
    /// and a dotted domain. Full RFC validation belongs on the server.
    nonisolated static func isValidEmail(_ candidate: String) -> Bool {
        guard !candidate.contains(" ") else { return false }
        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first, !local.isEmpty,
              let domain = parts.last, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix(".")
        else { return false }
        return true
    }

    /// Maps transport errors to warm, actionable copy — never raw codes.
    nonisolated static func friendlyMessage(for error: any Error) -> String {
        guard let apiError = error as? APIError else {
            return "Something went wrong. Please try again."
        }
        return switch apiError {
        case .unauthorized, .forbidden:
            "That email and password don't match our records."
        case .conflict:
            "An account with this email already exists — try signing in instead."
        case .offline, .network:
            "You appear to be offline. Check your connection and try again."
        case .rateLimited:
            "Too many attempts. Take a breath and try again in a moment."
        case .server, .decoding, .notFound:
            "Our servers are momentarily busy. Please try again shortly."
        }
    }
}
