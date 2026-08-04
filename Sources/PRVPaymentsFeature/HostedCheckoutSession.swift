import Foundation
import PRVFoundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The `prvbeauty://` callbacks a Stripe-hosted page hands control back through.
///
/// Registered as a custom URL scheme in the app's `Info.plist`, and configured
/// on the Stripe side as the `success_url` / `cancel_url` of the hosted session.
/// Kept out of ``HostedCheckoutSession`` so it can be read from anywhere,
/// including the non-main-actor code that builds an Edge Function request.
public enum PaymentReturnURL {
    /// The URL scheme registered by the app for payment callbacks.
    public static let scheme = "prvbeauty"

    /// Where a hosted page hands control back to.
    public enum Endpoint: String, Hashable, Sendable {
        /// `prvbeauty://payment-return` — the end of a checkout.
        case payment = "payment-return"
        /// `prvbeauty://card-return` — the end of a card vaulting flow.
        case card = "card-return"
    }

    /// The callback URL the backend must redirect to when a hosted page ends.
    ///
    /// Built rather than written as a literal so there is no force-unwrapped
    /// `URL(string:)` in payment code; a `nil` result means the scheme itself
    /// is malformed, which callers surface as "not configured".
    public static func url(for endpoint: Endpoint) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = endpoint.rawValue
        return components.url
    }
}

/// What came back from a Stripe-hosted page.
public enum HostedPageOutcome: Hashable, Sendable {
    /// The page redirected to the app's callback scheme.
    case returned(URL)
    /// The client dismissed the browser without finishing.
    case cancelled
    /// The page could not be opened, or closed with an error.
    case failed(String)
}

/// Presents a Stripe-hosted page inside `ASWebAuthenticationSession` and waits
/// for it to hand control back through the app's callback scheme.
///
/// ## Why a web session rather than an SDK
///
/// Taking card numbers without linking Stripe's SDK means the card has to be
/// entered somewhere this process cannot see. `ASWebAuthenticationSession` is
/// the system's answer to exactly that shape of problem: it runs the page in a
/// browser context the app has no access to — no `WKWebView` handle, no
/// JavaScript bridge, no cookie jar — and returns nothing but the callback URL.
/// The app therefore stays out of PCI scope by construction rather than by
/// discipline.
///
/// ## What the callback does and does not mean
///
/// The callback URL is a *hint*. It says the browser finished; it does not say
/// the money moved, and it is trivially forgeable by anything that can open a
/// `prvbeauty://` URL. Only `stripe-webhook` marks an order paid, so callers
/// use the redirect solely to stop waiting and then read the order back. The
/// one status worth acting on directly is `cancelled`, because there is nothing
/// to wait for.
///
/// ## Notes on the presentation
///
/// - `prefersEphemeralWebBrowserSession` is on. A payment page has no business
///   inheriting Safari's cookies, and the ephemeral mode also spares the client
///   the "…wants to use stripe.com to sign in" consent alert, which reads as
///   alarming in the middle of a checkout.
/// - The anchor window is resolved from the active foreground scene. This is
///   the one place in the feature that touches UIKit: `ASPresentationAnchor`
///   *is* a `UIWindow`, and SwiftUI exposes no substitute.
@MainActor
final class HostedCheckoutSession {
    #if canImport(AuthenticationServices)
    private var session: ASWebAuthenticationSession?
    #endif
    #if canImport(AuthenticationServices) && canImport(UIKit)
    private var anchorProvider: HostedPageAnchorProvider?
    #endif

    /// Creates a session host. One instance drives one presentation.
    init() {}

    /// Presents `url` and waits for the browser to hand control back.
    ///
    /// Always returns: a dismissal resolves to ``HostedPageOutcome/cancelled``
    /// rather than leaving the caller suspended.
    func present(_ url: URL) async -> HostedPageOutcome {
        #if canImport(AuthenticationServices) && canImport(UIKit)
        guard let anchor = Self.activeAnchor() else {
            PRVLog.payments.error("No foreground window to anchor the hosted payment page to")
            return .failed("PRV Beauty couldn't open the secure payment page. Bring the app to the foreground and try again.")
        }

        let provider = HostedPageAnchorProvider(anchor: anchor)
        let relay = ContinuationRelay<HostedPageOutcome>()

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: PaymentReturnURL.scheme
        ) { callbackURL, error in
            relay.resolve(Self.classify(callbackURL: callbackURL, error: error))
        }
        session.presentationContextProvider = provider
        session.prefersEphemeralWebBrowserSession = true

        self.session = session
        self.anchorProvider = provider
        defer {
            self.session = nil
            self.anchorProvider = nil
        }

        guard session.start() else {
            PRVLog.payments.error("Hosted payment page refused to start")
            return .failed("The secure payment page couldn't open. Try Apple Pay, or settle at the salon.")
        }

        return await withCheckedContinuation { continuation in
            relay.attach(continuation)
        }
        #else
        return .failed("Card payments need a device that can open Stripe's secure page.")
        #endif
    }

    #if canImport(AuthenticationServices)
    /// Turns the session's `(URL?, Error?)` pair into an outcome.
    ///
    /// `nonisolated` because `ASWebAuthenticationSession` makes no promise
    /// about the context its completion runs on.
    private nonisolated static func classify(
        callbackURL: URL?,
        error: (any Error)?
    ) -> HostedPageOutcome {
        if let error {
            if let sessionError = error as? ASWebAuthenticationSessionError,
               sessionError.code == .canceledLogin {
                return .cancelled
            }
            PRVLog.payments.error("Hosted payment page failed: \(String(describing: error), privacy: .public)")
            return .failed("The secure payment page closed before it finished. Nothing has been charged.")
        }
        guard let callbackURL else { return .cancelled }
        return .returned(callbackURL)
    }
    #endif

    #if canImport(AuthenticationServices) && canImport(UIKit)
    /// The window a modal browser can be anchored to: the key window of the
    /// active foreground scene, falling back to any window the app owns.
    private static func activeAnchor() -> ASPresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }
    #endif
}

#if canImport(AuthenticationServices) && canImport(UIKit)

/// Supplies the window `ASWebAuthenticationSession` presents over.
///
/// The anchor is captured on the main actor when the session is built and only
/// read back — never mutated, never used to touch the window's own API — which
/// is why a plain stored reference is enough.
final class HostedPageAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    /// Captures the window to present over.
    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    /// The window the session presents over.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

#endif
