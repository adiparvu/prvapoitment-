import Foundation
import PRVFoundation
import PRVModels

/// The live ``AuthService``, backed by Supabase Auth (GoTrue) and the `profiles`
/// table.
///
/// Authentication and identity are two different things here. GoTrue owns
/// credentials and issues the JWT; `profiles` owns who that JWT belongs to —
/// role, name, language — and the `on_auth_user_created` trigger in
/// `0003_functions_triggers.sql` creates the row (and a loyalty profile with a
/// referral code) the moment the auth user exists. Every method therefore ends
/// the same way: adopt the session, then read the profile.
///
/// `User.salonIDs` is assembled from the three relationships
/// `public.is_salon_member(uuid)` recognises — employment, professional
/// attachment, and organization ownership — so what the app lets a user open is
/// exactly what Row Level Security will let them read.
public struct SupabaseAuthService: AuthService {
    private let client: SupabaseClient

    /// The profile columns the `User` value needs; never `select=*`, because
    /// `profiles` also carries fields other users are not entitled to see.
    private static let profileColumns =
        "id,role,first_name,last_name,email,phone,avatar_url,preferred_language,created_at"

    /// The Edge Function that erases an account.
    ///
    /// It does not exist yet — see the handover note. It must delete the row in
    /// `auth.users` with the service role (which cascades to `profiles` and from
    /// there through the schema) after re-verifying the caller's JWT, and must
    /// take the user from that JWT rather than from the request body.
    private static let deleteAccountFunction = "delete-account"

    /// Creates the service.
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Session

    /// Restores a persisted session.
    ///
    /// Loads the stored tokens, refreshes them when the access token has expired,
    /// and resolves the profile. Any failure — no stored session, a refresh token
    /// the server no longer honours, a deleted profile — returns `nil` rather than
    /// throwing, because "not signed in" is a normal launch state, not an error.
    public func restoreSession() async -> User? {
        guard let session = await client.loadPersistedSession() else { return nil }
        do {
            _ = try await client.refreshIfNeeded()
            return try await profile(userID: session.userID)
        } catch {
            PRVLog.auth.notice("Could not restore the Supabase session; continuing signed out")
            return nil
        }
    }

    /// Signs in with e-mail and password.
    ///
    /// - Throws: `APIError.unauthorized` when the credentials are refused.
    public func signIn(email: String, password: String) async throws -> User {
        let body = try await client.encode(
            PasswordGrant(email: email.trimmed.lowercased(), password: password)
        )
        let data = try await client.authData(
            path: "auth/v1/token",
            query: [SupabaseQueryItem(name: "grant_type", value: "password")],
            body: body
        )
        return try await adoptSession(from: data)
    }

    /// Signs in with an Apple identity token.
    ///
    /// Apple discloses the user's name only on the very first authorization, so
    /// `fullName` is written to the profile when it arrives and the profile does
    /// not have a name yet. Later sign-ins never overwrite what the user has
    /// since edited.
    public func signInWithApple(identityToken: Data, fullName: String?) async throws -> User {
        let token = String(decoding: identityToken, as: UTF8.self)
        guard !token.isBlank else { throw APIError.unauthorized }

        let body = try await client.encode(IdentityTokenGrant(provider: "apple", idToken: token))
        let data = try await client.authData(
            path: "auth/v1/token",
            query: [SupabaseQueryItem(name: "grant_type", value: "id_token")],
            body: body
        )
        let user = try await adoptSession(from: data)

        guard let fullName, !fullName.isBlank, user.firstName.isBlank, user.lastName.isBlank else {
            return user
        }
        let (first, last) = Self.split(fullName: fullName)
        let row: ProfileRow = try await client.update(
            "profiles",
            values: ProfileNameUpdate(firstName: first, lastName: last),
            filters: [.equals("id", user.id.rawValue)],
            returning: Self.profileColumns
        )
        return try Self.makeUser(row, salonIDs: user.salonIDs)
    }

    /// Creates an account.
    ///
    /// The names travel as GoTrue user metadata so `handle_new_auth_user()` can
    /// seed `profiles` in the same transaction that creates the auth user; the
    /// upsert afterwards makes them authoritative for the case where the row
    /// already existed (a re-registration after an unconfirmed sign-up).
    ///
    /// When the project requires e-mail confirmation, GoTrue answers with a user
    /// and no session. The account exists, so a `User` is returned, but nothing is
    /// persisted and `restoreSession()` will keep returning `nil` until the
    /// address is confirmed and the client signs in.
    public func signUp(
        email: String,
        password: String,
        firstName: String,
        lastName: String
    ) async throws -> User {
        let address = email.trimmed.lowercased()
        let body = try await client.encode(SignUpPayload(
            email: address,
            password: password,
            data: SignUpMetadata(firstName: firstName.trimmed, lastName: lastName.trimmed)
        ))
        let data = try await client.authData(path: "auth/v1/signup", body: body)
        let response: SupabaseAuthResponse = try await client.decode(data)

        guard let session = response.session() else {
            guard let identifier = response.userID else {
                throw APIError.server(status: 500, message: "Sign-up returned no account")
            }
            PRVLog.auth.notice("Sign-up needs e-mail confirmation before a session is issued")
            return User(
                id: User.ID(identifier),
                role: .client,
                firstName: firstName.trimmed,
                lastName: lastName.trimmed,
                email: response.emailAddress ?? address
            )
        }

        await client.adopt(session)
        let row: ProfileRow = try await client.upsert(
            into: "profiles",
            values: ProfileUpsert(
                id: session.userID,
                email: address,
                firstName: firstName.trimmed,
                lastName: lastName.trimmed
            ),
            onConflict: "id",
            returning: Self.profileColumns
        )
        return try Self.makeUser(row, salonIDs: [])
    }

    /// Signs out.
    ///
    /// The local credentials are cleared whatever the server says: a device that
    /// cannot reach the network must still be able to sign out, and a refresh
    /// token that outlives the app's copy of it is revoked on the next attempt to
    /// use it.
    public func signOut() async {
        do {
            _ = try await client.authData(
                path: "auth/v1/logout",
                body: try await client.encode(EmptyBody()),
                authorization: .session
            )
        } catch {
            PRVLog.auth.notice("Supabase logout failed; clearing the local session anyway")
        }
        await client.discardSession()
    }

    /// Erases the account.
    ///
    /// Deletion needs the service role — a client JWT cannot touch `auth.users` —
    /// so it is an Edge Function call. The caller is identified by the JWT the
    /// invocation carries, never by anything in the body.
    ///
    /// - Throws: The server's error when the erasure did not happen; the local
    ///   session is kept in that case, so the user is not stranded signed-out with
    ///   their data still present.
    public func deleteAccount() async throws {
        guard await client.currentUserID != nil else { throw APIError.unauthorized }
        _ = try await client.invokeRaw(function: Self.deleteAccountFunction, body: EmptyBody())
        await client.discardSession()
    }

    // MARK: - Profile

    /// Adopts the session in an auth response and resolves the profile behind it.
    private func adoptSession(from data: Data) async throws -> User {
        let response: SupabaseAuthResponse = try await client.decode(data)
        guard let session = response.session() else { throw APIError.unauthorized }
        await client.adopt(session)
        return try await profile(userID: session.userID)
    }

    /// Reads a profile and the salons it belongs to.
    private func profile(userID: UUID) async throws -> User {
        async let rowTask: ProfileRow = client.select(
            PostgRESTQuery("profiles")
                .selecting(Self.profileColumns)
                .filter(.equals("id", userID))
                .single()
        )
        async let salonsTask = salonIDs(userID: userID)
        let row = try await rowTask
        let salons = try await salonsTask
        return try Self.makeUser(row, salonIDs: salons)
    }

    /// The salons a user belongs to.
    ///
    /// Mirrors `public.is_salon_member(uuid)`: a current employment, an active
    /// professional record, or ownership of the organization the salon belongs to.
    /// Ownership needs two reads because RLS scopes `organizations` to the owner
    /// already, which makes the second query a plain `IN` over ids.
    private func salonIDs(userID: UUID) async throws -> [Salon.ID] {
        async let employedTask: [SalonReferenceRow] = client.select(
            PostgRESTQuery("employees")
                .selecting("salon_id")
                .filter(.equals("user_id", userID))
                .filter(.isNull("terminated_at"))
        )
        async let attachedTask: [SalonReferenceRow] = client.select(
            PostgRESTQuery("professionals")
                .selecting("salon_id")
                .filter(.equals("user_id", userID))
                .filter(.isNotNull("salon_id"))
        )
        async let ownedTask: [IdentifierRow] = client.select(
            PostgRESTQuery("organizations")
                .selecting("id")
                .filter(.equals("owner_id", userID))
        )

        let employed = try await employedTask
        let attached = try await attachedTask
        let organizations = try await ownedTask

        var identifiers: [UUID] = []
        identifiers.append(contentsOf: employed.compactMap { $0.salonID })
        identifiers.append(contentsOf: attached.compactMap { $0.salonID })

        if !organizations.isEmpty {
            let rows: [IdentifierRow] = try await client.select(
                PostgRESTQuery("salons")
                    .selecting("id")
                    .filter(.within("organization_id", organizations.map { $0.id }))
            )
            identifiers.append(contentsOf: rows.map { $0.id })
        }

        var seen = Set<UUID>()
        return identifiers
            .filter { seen.insert($0).inserted }
            .map { Salon.ID($0) }
    }

    private static func makeUser(_ row: ProfileRow, salonIDs: [Salon.ID]) throws -> User {
        User(
            id: User.ID(row.id),
            role: UserRole(rawValue: row.role) ?? .client,
            firstName: row.firstName,
            lastName: row.lastName,
            email: row.email,
            phone: row.phone,
            avatarURL: row.avatarURL.flatMap(URL.init(string:)),
            preferredLanguage: row.preferredLanguage,
            createdAt: try SupabaseTimestamp.date(from: row.createdAt),
            salonIDs: salonIDs
        )
    }

    /// Splits a display name into the two columns `profiles` stores.
    private static func split(fullName: String) -> (first: String, last: String) {
        let parts = fullName.trimmed.split(separator: " ").map(String.init)
        guard let first = parts.first else { return ("", "") }
        return (first, parts.dropFirst().joined(separator: " "))
    }
}

// MARK: - Rows and payloads

extension SupabaseAuthService {
    /// A `profiles` row.
    fileprivate struct ProfileRow: Decodable, Sendable {
        let id: UUID
        let role: String
        let firstName: String
        let lastName: String
        let email: String
        let phone: String?
        let avatarURL: String?
        let preferredLanguage: String
        let createdAt: String
    }

    /// A `salon_id` projection.
    fileprivate struct SalonReferenceRow: Decodable, Sendable {
        let salonID: UUID?
    }

    /// An `id` projection.
    fileprivate struct IdentifierRow: Decodable, Sendable {
        let id: UUID
    }

    /// `POST /auth/v1/token?grant_type=password`.
    fileprivate struct PasswordGrant: Encodable, Sendable {
        let email: String
        let password: String
    }

    /// `POST /auth/v1/token?grant_type=id_token` — Sign in with Apple.
    fileprivate struct IdentityTokenGrant: Encodable, Sendable {
        let provider: String
        let idToken: String
    }

    /// `POST /auth/v1/signup`. `data` becomes `auth.users.raw_user_meta_data`,
    /// which `handle_new_auth_user()` reads to seed the profile.
    fileprivate struct SignUpPayload: Encodable, Sendable {
        let email: String
        let password: String
        let data: SignUpMetadata
    }

    /// The metadata carried through sign-up.
    fileprivate struct SignUpMetadata: Encodable, Sendable {
        let firstName: String
        let lastName: String
    }

    /// The profile columns sign-up owns. `role` is deliberately absent: a client
    /// must never be able to name its own role.
    fileprivate struct ProfileUpsert: Encodable, Sendable {
        let id: UUID
        let email: String
        let firstName: String
        let lastName: String
    }

    /// The name columns Sign in with Apple backfills.
    fileprivate struct ProfileNameUpdate: Encodable, Sendable {
        let firstName: String
        let lastName: String
    }

    /// `{}` — for endpoints that authenticate by JWT and need no arguments.
    fileprivate struct EmptyBody: Encodable, Sendable {}
}
