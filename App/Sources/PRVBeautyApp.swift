import Foundation
import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVPersistence

@main
struct PRVBeautyApp: App {
    @State private var session = UserSession()
    @State private var router = AppRouter()
    @State private var hasRestoredSession = false
    @Environment(\.scenePhase) private var scenePhase

    /// Everything this launch talks to — live Supabase when the build carries
    /// credentials, the seeded demo backend otherwise. See `AppComposition`.
    private let composition = AppComposition()

    private var dependencies: PRVDependencies { composition.dependencies }

    init() {
        // Must happen before the app finishes launching: BackgroundTasks
        // rejects a handler registered any later.
        registerBackgroundRefresh()
    }

    /// Registers the background refresh handler, when there is a queue to drain.
    ///
    /// Demo builds have no sync engine, so there is nothing to register — and
    /// registering a handler that does nothing would only cost the user a wake.
    private func registerBackgroundRefresh() {
        guard let offline = composition.offline else { return }
        // Captured by value: the handler runs on a queue BackgroundTasks owns,
        // so it may close over nothing but Sendable values. `UserSession` is a
        // @MainActor observable and deliberately not among them — the wake
        // resolves the user from the persisted session instead, which is also
        // the only correct answer when the app is not running.
        let dependencies = composition.dependencies

        let job = PRVBackgroundRefresh.Job(
            sync: offline.sync,
            cache: offline.cache,
            refreshSnapshot: {
                let user = await dependencies.auth.restoreSession()
                await WidgetSyncService.refresh(using: dependencies, for: user)
            }
        )
        _ = PRVBackgroundRefresh.register(job: job)
    }

    var body: some Scene {
        WindowGroup {
            RootView(hasRestoredSession: hasRestoredSession)
                .environment(session)
                .environment(router)
                .prvComposition(composition)
                .task { await restoreSession() }
                .prvWidgetSync(session: session, dependencies: dependencies)
                .onOpenURL { url in
                    let experience: DeepLinkHandler.Experience =
                        session.isBusinessExperience ? .business : .client
                    guard let destination = DeepLinkHandler.route(for: url, in: experience) else { return }
                    router.open(destination.route, in: destination.tab)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        PRVLog.app.info("Scene became active")
                    case .background:
                        // Queue the next refresh as the app leaves the
                        // foreground: BackgroundTasks only honours a request
                        // that exists before the process is suspended.
                        PRVBackgroundRefresh.schedule()
                    default:
                        break
                    }
                }
        }
    }

    /// Adopts a persisted session once per launch, then lets `RootView` decide
    /// which experience to show.
    private func restoreSession() async {
        guard !hasRestoredSession else { return }
        if let user = await restoredUser() {
            session.signedIn(user)
        }
        hasRestoredSession = true
    }

    /// Resolves the user this launch starts as.
    ///
    /// Live backends answer from their persisted (Keychain-backed) session.
    /// The in-memory demo backend has nothing to persist — it hands back the
    /// same premium client on every call, which would pin every cold launch to
    /// one persona and leave the welcome screen, guest browsing, and the whole
    /// business experience unreachable. Demo builds therefore take their
    /// persona from ``DemoPersona``, which defaults to signed out.
    private func restoredUser() async -> User? {
        guard dependencies.auth is InMemoryBackend else {
            return await dependencies.auth.restoreSession()
        }
        return DemoPersona.current.user
    }
}

/// Which persona a demo build cold-launches as.
///
/// Pass a launch argument to pick one — `-PRVDemoPersona client` or
/// `-PRVDemoPersona owner`, set in the Xcode scheme or on
/// `xcrun simctl launch`. Without one the app starts signed out so the
/// welcome screen and both role experiences are all reachable from a clean
/// launch.
enum DemoPersona: String, Sendable, CaseIterable {
    /// No session is adopted: the welcome and guest experience are shown.
    case signedOut
    /// The premium client persona, opening the client tab bar.
    case client
    /// The salon owner persona, opening the business tab bar.
    case owner

    /// Launch-argument key. `UserDefaults` surfaces `-Key value` arguments
    /// through its argument domain, so no manual parsing is needed.
    static let defaultsKey = "PRVDemoPersona"

    /// The persona requested for this launch; defaults to ``signedOut``.
    static var current: DemoPersona {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let persona = DemoPersona(rawValue: raw)
        else { return .signedOut }
        return persona
    }

    /// The demo user this persona signs in as, or `nil` to stay signed out.
    var user: User? {
        switch self {
        case .signedOut: nil
        case .client: PreviewData.client
        case .owner: PreviewData.owner
        }
    }
}
