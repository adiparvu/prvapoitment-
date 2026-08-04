import Foundation
import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVPaymentsFeature
import PRVPersistence

/// The composition root: the single place where the app decides what it is
/// talking to and assembles every dependency accordingly.
///
/// Two backends exist and both are real code paths:
///
/// * **Live** — Supabase-backed repositories, a Keychain-persisted session, and
///   payments settled server-side. Selected whenever the build carries a
///   Supabase URL and anon key.
/// * **Demo** — the seeded `InMemoryBackend`. Selected when no credentials are
///   configured, or when `-PRVBackend demo` is passed, so the app is always
///   runnable and demonstrable without a project behind it.
///
/// Nothing downstream knows which is in play: features resolve repositories
/// from `\.prvDependencies` and behave identically either way.
@MainActor
struct AppComposition {
    /// Which backend the process is running against.
    enum Backend: String, Sendable {
        case live
        case demo
    }

    let backend: Backend
    let dependencies: PRVDependencies
    let paymentService: any PaymentServiceProtocol
    let cardTokenizer: any CardTokenizer
    /// Present only for the live backend — the demo backend's writes are
    /// already local, so there is nothing to queue or reconcile.
    let offline: OfflineStack?

    /// Builds the composition for this launch.
    init() {
        let configuration = SupabaseConfiguration.current
        let forcedDemo = UserDefaults.standard.string(forKey: "PRVBackend") == Backend.demo.rawValue

        if let configuration, !forcedDemo {
            let client = SupabaseClient(
                url: configuration.url,
                anonKey: configuration.anonKey,
                tokenStore: KeychainTokenStore()
            )
            backend = .live
            dependencies = .live(client: client)
            // Payments go through the same client, so a checkout call presents
            // the same session — and refreshes it on the same single flight —
            // as every other request.
            let gateway = EdgeFunctionPaymentGateway(functions: client)
            paymentService = StripePaymentService(gateway: gateway)
            cardTokenizer = HostedCardTokenizer(gateway: gateway)
            offline = OfflineStack(client: client)
            PRVLog.app.info("Composed against the live backend")
        } else {
            backend = .demo
            dependencies = .sharedInMemory
            paymentService = DemoPaymentService()
            cardTokenizer = UnconfiguredCardTokenizer()
            offline = nil
            PRVLog.app.info("Composed against the demo backend")
        }
    }

    /// True when the app is running on seeded data rather than a real project.
    var isDemo: Bool { backend == .demo }
}

// MARK: - Configuration

/// The Supabase credentials for this build.
///
/// Read from the Info.plist — populated from an xcconfig, which is
/// `.gitignore`d — so no project URL or key is ever committed. The anon key is
/// safe to ship: it grants nothing on its own, because row-level security is
/// the actual boundary (see docs/SECURITY.md §3).
struct SupabaseConfiguration: Sendable {
    let url: URL
    let anonKey: String

    /// The configuration for this build, or `nil` when the build carries none
    /// and the app should run on demo data.
    static var current: SupabaseConfiguration? {
        let bundle = Bundle.main
        guard
            let rawURL = bundle.object(forInfoDictionaryKey: "PRVSupabaseURL") as? String,
            let anonKey = bundle.object(forInfoDictionaryKey: "PRVSupabaseAnonKey") as? String,
            !rawURL.isBlank,
            !anonKey.isBlank,
            // An unsubstituted xcconfig variable reaches us verbatim; treat it
            // as absent rather than trying to reach `$(PRV_SUPABASE_URL)`.
            !rawURL.hasPrefix("$("),
            let url = URL(string: rawURL)
        else { return nil }
        return SupabaseConfiguration(url: url, anonKey: anonKey)
    }
}

// MARK: - Environment injection

extension View {
    /// Injects everything the composition root owns.
    ///
    /// Applied once at the app root so no feature has to know how the app was
    /// composed — including the payment service and card tokenizer, which
    /// otherwise fall back to their unconfigured demo defaults.
    func prvComposition(_ composition: AppComposition) -> some View {
        environment(\.prvDependencies, composition.dependencies)
            .environment(\.prvPaymentService, composition.paymentService)
            .environment(\.prvCardTokenizer, composition.cardTokenizer)
    }
}
