import Foundation
import PRVModels

extension PRVDependencies {
    /// Wires every repository to one live Supabase project.
    ///
    /// Injected once, at the app root, opposite `PRVDependencies.inMemory()`:
    ///
    /// ```swift
    /// RootView()
    ///     .environment(\.prvDependencies, .live(
    ///         url: AppEnvironment.current.supabaseURL,
    ///         anonKey: configuration.supabaseAnonKey,
    ///         tokenStore: KeychainTokenStore()
    ///     ))
    /// ```
    ///
    /// Every repository shares one ``SupabaseClient``, which is what makes the
    /// session single-valued: a token refreshed because the wallet screen got a
    /// 401 is the token the booking screen's next request presents, and a burst of
    /// concurrent 401s collapses into one refresh rather than a stampede.
    ///
    /// The container is built synchronously and holds no session yet. Call
    /// `deps.auth.restoreSession()` at launch to load the persisted tokens and
    /// resolve the signed-in `User`; until then every request travels with the
    /// publishable key and sees exactly what Row Level Security grants `anon`.
    ///
    /// - Parameters:
    ///   - url: The Supabase project URL.
    ///   - anonKey: The project's publishable (anon) key. Not a secret — RLS is
    ///     what protects the data — but it does identify the project, so it
    ///     belongs in the build configuration rather than in source.
    ///   - tokenStore: Durable storage for the session. Shipping builds pass a
    ///     Keychain-backed store; previews and tests can pass
    ///     ``EphemeralSupabaseTokenStore``.
    public static func live(
        url: URL,
        anonKey: String,
        tokenStore: any SupabaseTokenStore
    ) -> PRVDependencies {
        live(client: SupabaseClient(url: url, anonKey: anonKey, tokenStore: tokenStore))
    }

    /// Wires every repository to an already-configured client.
    ///
    /// Use this when the client is built elsewhere — a custom `URLSession`, a
    /// pre-seeded session in a UI test, or a second project in a migration.
    public static func live(client: SupabaseClient) -> PRVDependencies {
        PRVDependencies(
            auth: SupabaseAuthService(client: client),
            salons: SupabaseSalonRepository(client: client),
            appointments: SupabaseAppointmentRepository(client: client),
            payments: SupabasePaymentRepository(client: client),
            memberships: SupabaseMembershipRepository(client: client),
            loyalty: SupabaseLoyaltyRepository(client: client),
            chat: SupabaseChatRepository(client: client),
            notifications: SupabaseNotificationRepository(client: client),
            crm: SupabaseCRMRepository(client: client),
            team: SupabaseTeamRepository(client: client),
            inventory: SupabaseInventoryRepository(client: client),
            marketing: SupabaseMarketingRepository(client: client),
            analytics: SupabaseAnalyticsRepository(client: client)
        )
    }
}
