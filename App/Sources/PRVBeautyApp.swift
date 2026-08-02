import SwiftUI
import PRVFoundation
import PRVModels
import PRVNetworking

@main
struct PRVBeautyApp: App {
    @State private var session = UserSession()
    @State private var router = AppRouter()
    @State private var hasRestoredSession = false
    @Environment(\.scenePhase) private var scenePhase

    // Demo mode ships with the in-memory backend; production wiring swaps in
    // Supabase-backed repositories behind the same protocols.
    private let dependencies: PRVDependencies = .inMemory()

    var body: some Scene {
        WindowGroup {
            RootView(hasRestoredSession: hasRestoredSession)
                .environment(session)
                .environment(router)
                .environment(\.prvDependencies, dependencies)
                .task { await restoreSession() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        PRVLog.app.info("Scene became active")
                    }
                }
        }
    }

    private func restoreSession() async {
        guard !hasRestoredSession else { return }
        if let user = await dependencies.auth.restoreSession() {
            session.signedIn(user)
        }
        hasRestoredSession = true
    }
}
