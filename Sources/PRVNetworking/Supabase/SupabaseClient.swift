import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in a separate module on non-Apple platforms, where the
// repository contracts are built for domain testing.
import FoundationNetworking
#endif
import PRVFoundation

// MARK: - Session

/// The credentials Supabase Auth (GoTrue) hands back after a successful sign-in.
///
/// The client keeps exactly one of these in memory. Durable storage is the app's
/// concern — `PRVAuthFeature.SessionStore` puts it in the Keychain — which is why
/// it is `Codable` and why the client only ever talks to a ``SupabaseTokenStore``.
public struct SupabaseSession: Codable, Hashable, Sendable {
    /// Short-lived JWT sent as `Authorization: Bearer …` on every authenticated call.
    public var accessToken: String
    /// Long-lived token exchanged for a new access token once the access token expires.
    public var refreshToken: String
    /// The instant `accessToken` stops being accepted.
    public var expiresAt: Date
    /// `auth.users.id`, which is also `profiles.id` for this user.
    public var userID: UUID

    /// Creates a session.
    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
    }

    /// Whether the access token has expired, or is close enough to expiry that a
    /// request started now would likely arrive after it did.
    ///
    /// - Parameters:
    ///   - now: The instant to judge against.
    ///   - leeway: Seconds of head-room treated as "already expired".
    public func isExpired(now: Date = .now, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// Durable storage for the current ``SupabaseSession``.
///
/// The networking layer never decides *where* tokens live: on device the app
/// backs this with the Keychain, previews and tests use
/// ``EphemeralSupabaseTokenStore``.
public protocol SupabaseTokenStore: Sendable {
    /// The persisted session, or `nil` when the user has never signed in.
    func load() async -> SupabaseSession?
    /// Persists `session`, replacing any previously stored one.
    func save(_ session: SupabaseSession) async
    /// Erases the stored session — sign-out, account deletion, failed refresh.
    func clear() async
}

/// A token store that keeps the session in memory for the lifetime of the process.
///
/// Suitable for previews, tests, and demo mode. Shipping builds use a
/// Keychain-backed store so a session survives relaunch.
public actor EphemeralSupabaseTokenStore: SupabaseTokenStore {
    private var session: SupabaseSession?

    /// Creates an empty store, optionally seeded with a session.
    public init(session: SupabaseSession? = nil) {
        self.session = session
    }

    /// The session held in memory.
    public func load() async -> SupabaseSession? { session }

    /// Replaces the in-memory session.
    public func save(_ session: SupabaseSession) async { self.session = session }

    /// Drops the in-memory session.
    public func clear() async { session = nil }
}

// MARK: - Request vocabulary

/// The HTTP verbs the Supabase REST surface uses.
public enum SupabaseMethod: String, Hashable, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Which credential a request presents.
public enum SupabaseAuthorization: Hashable, Sendable {
    /// The publishable (anon) key only — sign-in, sign-up, token refresh.
    case anonymous
    /// The signed-in user's access token, falling back to the anon key when the
    /// user is a guest. Row Level Security does the rest.
    case session
}

/// One `name=value` pair of a PostgREST query string.
///
/// PostgREST legitimately repeats a name (`starts_at=gte.…&starts_at=lt.…`), so
/// query strings are modelled as an ordered list rather than a dictionary.
public struct SupabaseQueryItem: Hashable, Sendable {
    /// The parameter name — a column, or a PostgREST keyword such as `select`.
    public let name: String
    /// The parameter value, before percent-encoding.
    public let value: String

    /// Creates a query item.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

// MARK: - Filters

/// A single PostgREST filter, already rendered as the `name=value` pair it
/// becomes in the query string.
///
/// Values are quoted only when they contain a character the PostgREST parser
/// treats as structure, so ordinary UUIDs, enum names, and timestamps stay
/// readable in logs.
public struct PostgRESTFilter: Hashable, Sendable {
    /// The query parameter name — a column, or `or` for a disjunction.
    public let name: String
    /// The operator-prefixed value, e.g. `eq.4d1f…` or `gte.2026-08-04T00:00:00Z`.
    public let value: String

    /// Creates a filter from an already-rendered pair.
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// `column = value`.
    public static func equals(_ column: String, _ value: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "eq.\(literal(value))")
    }

    /// `column = id`.
    public static func equals(_ column: String, _ id: UUID) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "eq.\(id.uuidString.lowercased())")
    }

    /// `column <> value`.
    public static func notEquals(_ column: String, _ value: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "neq.\(literal(value))")
    }

    /// `column > value`.
    public static func greaterThan(_ column: String, _ value: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "gt.\(literal(value))")
    }

    /// `column >= value`.
    public static func atLeast(_ column: String, _ value: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "gte.\(literal(value))")
    }

    /// `column < value`.
    public static func lessThan(_ column: String, _ value: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "lt.\(literal(value))")
    }

    /// `column <= value`.
    public static func atMost(_ column: String, _ value: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "lte.\(literal(value))")
    }

    /// `column IN (values)`. An empty list matches nothing.
    public static func within(_ column: String, _ values: [String]) -> PostgRESTFilter {
        let list = values.map(literal).joined(separator: ",")
        return PostgRESTFilter(name: column, value: "in.(\(list))")
    }

    /// `column IN (ids)`. An empty list matches nothing.
    public static func within(_ column: String, _ ids: [UUID]) -> PostgRESTFilter {
        within(column, ids.map { $0.uuidString.lowercased() })
    }

    /// Case-insensitive substring match (`ILIKE '%needle%'`).
    ///
    /// Characters that would terminate a filter or an `or(…)` group are replaced
    /// with `*`, PostgREST's wildcard, so free-text search never has to be quoted
    /// and never breaks the parser.
    public static func caseInsensitiveContains(_ column: String, _ needle: String) -> PostgRESTFilter {
        let sanitized = String(needle.map { character in
            ",()\"\\{}".contains(character) ? "*" : character
        })
        return PostgRESTFilter(name: column, value: "ilike.*\(sanitized)*")
    }

    /// Array column overlaps `values` (`&&`) — "has at least one of".
    public static func overlaps(_ column: String, _ values: [String]) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "ov.\(arrayLiteral(values))")
    }

    /// Array column contains all of `values` (`@>`).
    public static func containsAll(_ column: String, _ values: [String]) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "cs.\(arrayLiteral(values))")
    }

    /// Array column is contained by `values` (`<@`).
    public static func containedBy(_ column: String, _ values: [String]) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "cd.\(arrayLiteral(values))")
    }

    /// `column IS NULL`.
    public static func isNull(_ column: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "is.null")
    }

    /// `column IS NOT NULL`.
    public static func isNotNull(_ column: String) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "not.is.null")
    }

    /// `column IS TRUE` / `column IS FALSE`.
    public static func isTrue(_ column: String, _ expected: Bool = true) -> PostgRESTFilter {
        PostgRESTFilter(name: column, value: "is.\(expected)")
    }

    /// The disjunction of `filters` — `or=(a.eq.1,b.eq.2)`.
    ///
    /// A single-element list is returned unchanged, and an empty list yields a
    /// filter that matches nothing rather than everything.
    public static func any(of filters: [PostgRESTFilter]) -> PostgRESTFilter {
        guard let first = filters.first else {
            return PostgRESTFilter(name: "or", value: "()")
        }
        guard filters.count > 1 else { return first }
        let group = filters.map { "\($0.name).\($0.value)" }.joined(separator: ",")
        return PostgRESTFilter(name: "or", value: "(\(group))")
    }

    /// Quotes a scalar only when it contains PostgREST structure characters.
    private static func literal(_ value: String) -> String {
        let reserved = CharacterSet(charactersIn: ",()\"\\{}")
        guard value.isEmpty || value.rangeOfCharacter(from: reserved) != nil else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Renders `{a,b,c}` — the Postgres array literal PostgREST expects.
    private static func arrayLiteral(_ values: [String]) -> String {
        "{\(values.map(literal).joined(separator: ","))}"
    }
}

// MARK: - Ordering

/// One `ORDER BY` term.
public struct PostgRESTOrder: Hashable, Sendable {
    /// The column to sort on.
    public let column: String
    /// Ascending when `true`.
    public let isAscending: Bool
    /// Whether `NULL`s sort first.
    public let nullsFirst: Bool

    /// Creates an ordering term.
    public init(column: String, isAscending: Bool = true, nullsFirst: Bool = false) {
        self.column = column
        self.isAscending = isAscending
        self.nullsFirst = nullsFirst
    }

    /// The `order` query fragment, e.g. `starts_at.asc.nullsfirst`.
    public var fragment: String {
        "\(column).\(isAscending ? "asc" : "desc").\(nullsFirst ? "nullsfirst" : "nullslast")"
    }
}

// MARK: - Query

/// A type-safe PostgREST query.
///
/// Built by chaining rather than by string concatenation at the call site, so a
/// repository can never accidentally emit `?salon_id=` twice with different
/// spellings or forget to encode a filter value:
///
/// ```swift
/// let query = PostgRESTQuery("appointments")
///     .selecting("*,appointment_items(*)")
///     .filter(.equals("salon_id", salonID.rawValue))
///     .filter(.atLeast("starts_at", SupabaseTimestamp.string(from: start)))
///     .order("starts_at")
/// ```
public struct PostgRESTQuery: Hashable, Sendable {
    /// The table or view being queried.
    public let table: String
    /// The `select` projection, including embedded resources.
    public private(set) var columns: String
    /// Applied filters, in the order they were added.
    public private(set) var filters: [PostgRESTFilter]
    /// Applied ordering terms, in precedence order.
    public private(set) var orders: [PostgRESTOrder]
    /// Maximum number of rows.
    public private(set) var limit: Int?
    /// Number of rows to skip.
    public private(set) var offset: Int?
    /// Whether exactly one row is expected.
    public private(set) var wantsSingleRow: Bool

    /// Creates a query over `table` selecting every column.
    public init(_ table: String) {
        self.table = table
        self.columns = "*"
        self.filters = []
        self.orders = []
        self.wantsSingleRow = false
    }

    /// Replaces the projection. Embedded resources use PostgREST's syntax,
    /// e.g. `"*,appointment_items(*)"`.
    public func selecting(_ columns: String) -> PostgRESTQuery {
        var copy = self
        copy.columns = columns
        return copy
    }

    /// Adds one filter.
    public func filter(_ filter: PostgRESTFilter) -> PostgRESTQuery {
        var copy = self
        copy.filters.append(filter)
        return copy
    }

    /// Adds several filters, conjoined.
    public func filter(_ filters: [PostgRESTFilter]) -> PostgRESTQuery {
        var copy = self
        copy.filters.append(contentsOf: filters)
        return copy
    }

    /// Adds an ordering term; call repeatedly for tie-breakers.
    public func order(
        _ column: String,
        ascending: Bool = true,
        nullsFirst: Bool = false
    ) -> PostgRESTQuery {
        var copy = self
        copy.orders.append(PostgRESTOrder(column: column, isAscending: ascending, nullsFirst: nullsFirst))
        return copy
    }

    /// Caps the number of returned rows.
    public func limited(to count: Int) -> PostgRESTQuery {
        var copy = self
        copy.limit = max(0, count)
        return copy
    }

    /// Selects the inclusive row range `lowerBound…upperBound`, expressed as the
    /// `offset`/`limit` pair PostgREST accepts on the query string (so no
    /// `Content-Range` header parsing is needed on the way back).
    public func range(from lowerBound: Int, to upperBound: Int) -> PostgRESTQuery {
        var copy = self
        copy.offset = max(0, lowerBound)
        copy.limit = max(0, upperBound - lowerBound + 1)
        return copy
    }

    /// Requests exactly one row: the response decodes as an object rather than
    /// an array, and "no rows" becomes `APIError.notFound`.
    public func single() -> PostgRESTQuery {
        var copy = self
        copy.wantsSingleRow = true
        return copy
    }

    /// The REST path this query addresses.
    public var path: String { "rest/v1/\(table)" }

    /// The full query string, ready to be percent-encoded.
    public var queryItems: [SupabaseQueryItem] {
        var items = [SupabaseQueryItem(name: "select", value: columns)]
        items.append(contentsOf: filters.map { SupabaseQueryItem(name: $0.name, value: $0.value) })
        if !orders.isEmpty {
            items.append(SupabaseQueryItem(
                name: "order",
                value: orders.map(\.fragment).joined(separator: ",")
            ))
        }
        if let offset {
            items.append(SupabaseQueryItem(name: "offset", value: String(offset)))
        }
        if let limit {
            items.append(SupabaseQueryItem(name: "limit", value: String(limit)))
        }
        return items
    }
}

// MARK: - Embedded resources

/// A PostgREST embedded resource, tolerant of the two shapes the server uses.
///
/// A child collection comes back as an array; a one-to-one embed (such as
/// `prepayment_policies`, whose primary key *is* the foreign key) comes back as a
/// single object on PostgREST 9+ and as a one-element array on older builds.
/// Decoding either into the same value keeps repositories free of that detail.
public struct SupabaseEmbedded<Value: Decodable & Sendable>: Decodable, Sendable {
    /// Every embedded row, in the order the server returned them.
    public let values: [Value]

    /// Decodes an array, a single object, or `null`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            values = []
        } else if let array = try? container.decode([Value].self) {
            values = array
        } else {
            values = [try container.decode(Value.self)]
        }
    }

    /// The first embedded row, if any.
    public var first: Value? { values.first }
}

// MARK: - Timestamps

/// Conversion between Postgres `timestamptz` text and `Date`.
///
/// `JSONCoding.decoder` uses Foundation's `.iso8601` strategy, which rejects the
/// fractional seconds Postgres emits for anything defaulted from `now()`
/// (`2026-08-04T09:15:32.481920+00:00`). Repositories therefore decode timestamp
/// columns as `String` and convert here, where every shape Postgres can produce —
/// `Z`, `+HH`, `+HH:MM`, `+HHMM`, with or without a fractional part — is handled
/// explicitly. Values produced by the `book_appointment` / `appointment_payload`
/// RPCs are already normalised to whole seconds and decode as `Date` directly.
public enum SupabaseTimestamp {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = utc
        }
        return calendar
    }()

    /// Parses a Postgres timestamp.
    ///
    /// - Throws: `APIError.decoding` when `text` is not a timestamp.
    public static func date(from text: String) throws -> Date {
        guard let date = optionalDate(from: text) else {
            throw APIError.decoding("Not an ISO-8601 timestamp: \(text)")
        }
        return date
    }

    /// Parses a Postgres timestamp, returning `nil` for a missing or malformed value.
    public static func optionalDate(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }

        // Split "<date>T<time><zone>"; Postgres uses "T" in JSON and a space in
        // some text outputs.
        let body = text.trimmed
        guard let separatorIndex = body.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }) else {
            return nil
        }
        let datePart = String(body[body.startIndex ..< separatorIndex])
        var timePart = String(body[body.index(after: separatorIndex)...])

        let dateFields = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateFields.count == 3,
              let year = Int(dateFields[0]),
              let month = Int(dateFields[1]),
              let day = Int(dateFields[2])
        else { return nil }

        // Peel the zone designator off the end.
        var offsetSeconds = 0
        if timePart.hasSuffix("Z") || timePart.hasSuffix("z") {
            timePart.removeLast()
        } else if let signIndex = timePart.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = String(timePart[timePart.index(after: signIndex)...])
            let sign = timePart[signIndex] == "-" ? -1 : 1
            timePart = String(timePart[timePart.startIndex ..< signIndex])
            guard let seconds = zoneOffsetSeconds(zone) else { return nil }
            offsetSeconds = sign * seconds
        }

        let timeFields = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard timeFields.count >= 2,
              let hour = Int(timeFields[0]),
              let minute = Int(timeFields[1])
        else { return nil }

        var second = 0
        var fraction: TimeInterval = 0
        if timeFields.count > 2 {
            let secondFields = timeFields[2].split(separator: ".", omittingEmptySubsequences: false)
            guard let whole = Int(secondFields[0]) else { return nil }
            second = whole
            if secondFields.count > 1, let digits = Double(secondFields[1]) {
                fraction = digits / pow(10, Double(secondFields[1].count))
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        guard let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// Renders `date` as UTC ISO-8601 with whole seconds — the form Postgres and
    /// `JSONCoding.decoder` both accept.
    public static func string(from date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.year ?? 1970,
            parts.month ?? 1,
            parts.day ?? 1,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    /// Parses `HH`, `HHMM`, or `HH:MM` into seconds.
    private static func zoneOffsetSeconds(_ zone: String) -> Int? {
        if zone.contains(":") {
            let fields = zone.split(separator: ":")
            guard let hours = Int(fields[0]) else { return nil }
            let minutes = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
            return hours * 3_600 + minutes * 60
        }
        switch zone.count {
        case 2:
            return Int(zone).map { $0 * 3_600 }
        case 4:
            guard let hours = Int(zone.prefix(2)), let minutes = Int(zone.suffix(2)) else { return nil }
            return hours * 3_600 + minutes * 60
        default:
            return nil
        }
    }
}

// MARK: - Auth payloads

/// A GoTrue token / sign-up response.
///
/// `/auth/v1/token` returns a session with the user nested inside it, while
/// `/auth/v1/signup` returns a bare user when the project requires e-mail
/// confirmation. Every field is optional so one type decodes both.
public struct SupabaseAuthResponse: Decodable, Sendable {
    /// The user object nested inside a session response.
    public struct AuthUser: Decodable, Sendable {
        /// `auth.users.id`.
        public let id: UUID?
        /// The account e-mail, when the project stores one.
        public let email: String?
    }

    /// Access token, when a session was issued.
    public let accessToken: String?
    /// Refresh token, when a session was issued.
    public let refreshToken: String?
    /// Access-token lifetime in seconds.
    public let expiresIn: Int?
    /// The nested user of a session response.
    public let user: AuthUser?
    /// The id of a bare user response.
    public let id: UUID?
    /// The e-mail of a bare user response.
    public let email: String?

    /// The user's id, wherever the server put it.
    public var userID: UUID? { user?.id ?? id }

    /// The user's e-mail, wherever the server put it.
    public var emailAddress: String? { user?.email ?? email }

    /// The session this response carries, or `nil` when the account still needs
    /// to confirm its e-mail address.
    public func session(now: Date = .now) -> SupabaseSession? {
        guard let accessToken, let refreshToken, let userID else { return nil }
        return SupabaseSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn ?? 3_600)),
            userID: userID
        )
    }
}

// MARK: - Errors

/// A parsed Supabase failure body.
///
/// Three producers, three shapes: PostgREST (`{code, message, details, hint}`),
/// the Edge Functions (`{error: {code, message}}`, see `functions/_shared/errors.ts`),
/// and GoTrue (`{code, error_code, msg}` or `{error, error_description}`). They are
/// read with `JSONSerialization` rather than `Codable` because a failure body is
/// untrusted, occasionally not JSON at all, and never worth throwing over.
struct SupabaseFailure: Sendable {
    /// The machine-readable code, if the body carried one.
    let code: String?
    /// The human-readable message, if the body carried one.
    let message: String?
    /// PostgREST's `hint`, when present.
    let hint: String?

    /// Parses a response body.
    init(data: Data) {
        guard !data.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            let text = String(data: data, encoding: .utf8)?.trimmed
            code = nil
            message = (text?.isEmpty == false) ? text : nil
            hint = nil
            return
        }

        let nested = object["error"] as? [String: Any]
        let payload = nested ?? object

        var resolvedCode = payload["code"] as? String
            ?? payload["error_code"] as? String
            ?? object["error_code"] as? String
        if resolvedCode == nil, nested == nil, let plain = object["error"] as? String {
            resolvedCode = plain
        }
        code = resolvedCode

        message = payload["message"] as? String
            ?? payload["msg"] as? String
            ?? payload["error_description"] as? String
            ?? object["message"] as? String
            ?? object["msg"] as? String
            ?? object["error_description"] as? String
        hint = payload["hint"] as? String ?? object["hint"] as? String
    }

    /// The error this body names, independent of the HTTP status.
    ///
    /// SQLSTATEs come from `migrations/0003_functions_triggers.sql`; the string
    /// codes come from the Edge Functions' shared error envelope.
    func mappedError() -> APIError? {
        guard let code else { return nil }
        let text = message ?? "Request failed"
        switch code {
        case "PRV09", "23505", "23P01", "23503", "conflict", "slot_conflict":
            return .conflict(text)
        case "PRV04", "PGRST116", "42883", "42P01", "not_found":
            return .notFound
        case "PRV01", "42501", "forbidden":
            return .forbidden
        case "PGRST301", "unauthorized", "invalid_grant", "invalid_credentials",
             "bad_jwt", "session_not_found", "refresh_token_not_found",
             "refresh_token_already_used":
            return .unauthorized
        case "over_request_rate_limit", "over_email_send_rate_limit":
            return .rateLimited(retryAfter: nil)
        case "upstream_error":
            return .server(status: 502, message: text)
        default:
            return nil
        }
    }
}

// MARK: - Client

/// The PostgREST / Supabase transport every live repository is built on.
///
/// One actor owns the project credentials, the in-flight session, and the single
/// refresh that a burst of concurrent 401s collapses into. Everything above it —
/// ``SupabaseSalonRepository`` and friends — is a thin, stateless mapping between
/// domain models and rows.
///
/// Responsibilities:
/// - build PostgREST requests from ``PostgRESTQuery`` values, never from strings;
/// - attach `apikey`, `Authorization`, `Accept`, `Content-Type`, and `Prefer`;
/// - refresh an expired session **once** on a 401 and retry, or surface
///   `APIError.unauthorized` so the app can sign the user out;
/// - translate PostgREST / GoTrue / Edge Function failure bodies into ``APIError``.
public actor SupabaseClient {
    /// The Supabase project base URL, e.g. `https://abcdefgh.supabase.co`.
    public let projectURL: URL

    private let anonKey: String
    private let urlSession: URLSession
    private let tokenStore: any SupabaseTokenStore
    private var liveSession: SupabaseSession?
    private var refreshTask: Task<SupabaseSession, any Error>?

    private static let maximumRetries = 2
    private static let singleObjectAccept = "application/vnd.pgrst.object+json"

    /// Creates a client for one Supabase project.
    ///
    /// - Parameters:
    ///   - url: The project URL.
    ///   - anonKey: The publishable (anon) key. It is not a secret; Row Level
    ///     Security is what protects the data.
    ///   - tokenStore: Where the session is persisted between launches.
    ///   - urlSession: Transport, injectable for tests.
    public init(
        url: URL,
        anonKey: String,
        tokenStore: any SupabaseTokenStore,
        urlSession: URLSession = .shared
    ) {
        self.projectURL = url
        self.anonKey = anonKey
        self.tokenStore = tokenStore
        self.urlSession = urlSession
    }

    // MARK: Session state

    /// The session held in memory, if the user is signed in.
    public var currentSession: SupabaseSession? { liveSession }

    /// The signed-in user's id, or `nil` for a guest.
    public var currentUserID: UUID? { liveSession?.userID }

    /// Loads the persisted session into memory, returning it when one exists.
    @discardableResult
    public func loadPersistedSession() async -> SupabaseSession? {
        if liveSession == nil {
            liveSession = await tokenStore.load()
        }
        return liveSession
    }

    /// Adopts `session` as the live one and persists it.
    public func adopt(_ session: SupabaseSession) async {
        liveSession = session
        await tokenStore.save(session)
    }

    /// Forgets the session, in memory and in the token store.
    public func discardSession() async {
        liveSession = nil
        refreshTask = nil
        await tokenStore.clear()
    }

    /// Refreshes the access token when it has expired.
    ///
    /// - Returns: The live session, or `nil` when no user is signed in.
    /// - Throws: `APIError.unauthorized` when the refresh token is no longer
    ///   accepted; the local session is cleared first.
    @discardableResult
    public func refreshIfNeeded() async throws -> SupabaseSession? {
        guard let current = liveSession else { return nil }
        guard current.isExpired() else { return current }
        return try await refreshSession()
    }

    // MARK: Reads

    /// Runs `query` and decodes the response.
    ///
    /// - Throws: `APIError.notFound` when the query asked for a single row and
    ///   the server found none.
    public func select<Response: Decodable & Sendable>(
        _ query: PostgRESTQuery,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let request = SupabaseRequest(
            method: .get,
            path: query.path,
            query: query.queryItems,
            headers: query.wantsSingleRow ? ["Accept": Self.singleObjectAccept] : [:]
        )
        let data = try await execute(request)
        return try decode(data)
    }

    // MARK: Writes

    /// Inserts `values` and returns the stored representation.
    public func insert<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        into table: String,
        values: Body,
        returning columns: String = "*",
        singleRow: Bool = true,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await write(
            method: .post,
            table: table,
            values: values,
            filters: [],
            preferences: ["return=representation"],
            extraQuery: [],
            returning: columns,
            singleRow: singleRow
        )
    }

    /// Updates every row matching `filters` and returns the stored representation.
    ///
    /// - Throws: `APIError.server` when `filters` is empty, rather than rewriting
    ///   the whole table.
    public func update<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ table: String,
        values: Body,
        filters: [PostgRESTFilter],
        returning columns: String = "*",
        singleRow: Bool = true,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await write(
            method: .patch,
            table: table,
            values: values,
            filters: filters,
            preferences: ["return=representation"],
            extraQuery: [],
            returning: columns,
            singleRow: singleRow
        )
    }

    /// Inserts `values`, merging into any row that collides on `onConflict`.
    public func upsert<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        into table: String,
        values: Body,
        onConflict: String? = nil,
        returning columns: String = "*",
        singleRow: Bool = true,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await write(
            method: .post,
            table: table,
            values: values,
            filters: [],
            preferences: ["return=representation", "resolution=merge-duplicates"],
            extraQuery: onConflict.map { [SupabaseQueryItem(name: "on_conflict", value: $0)] } ?? [],
            returning: columns,
            singleRow: singleRow
        )
    }

    /// Deletes every row matching `filters` and returns what was removed.
    public func delete<Response: Decodable & Sendable>(
        from table: String,
        filters: [PostgRESTFilter],
        returning columns: String = "*",
        singleRow: Bool = true,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await write(
            method: .delete,
            table: table,
            values: Optional<SupabaseNoBody>.none,
            filters: filters,
            preferences: ["return=representation"],
            extraQuery: [],
            returning: columns,
            singleRow: singleRow
        )
    }

    /// Deletes every row matching `filters`, discarding the representation.
    public func deleteRows(from table: String, filters: [PostgRESTFilter]) async throws {
        guard !filters.isEmpty else {
            throw APIError.server(status: 400, message: "Refusing to delete all of \(table) unfiltered")
        }
        let request = SupabaseRequest(
            method: .delete,
            path: "rest/v1/\(table)",
            query: filters.map { SupabaseQueryItem(name: $0.name, value: $0.value) },
            headers: ["Prefer": "return=minimal"]
        )
        _ = try await execute(request)
    }

    // MARK: Functions

    /// Calls a Postgres function through PostgREST (`/rest/v1/rpc/<name>`).
    ///
    /// Argument names are the function's own — `book_appointment` takes
    /// `p_request`, `award_loyalty_xp` takes `p_user`, `p_xp`, `p_points` — so
    /// `Params` is normally a small `Encodable` struct whose camelCase properties
    /// `JSONCoding.encoder` renders as those snake_case keys.
    public func rpc<Params: Encodable & Sendable, Response: Decodable & Sendable>(
        _ name: String,
        params: Params,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let request = SupabaseRequest(
            method: .post,
            path: "rest/v1/rpc/\(name)",
            body: try encode(params)
        )
        let data = try await execute(request)
        return try decode(data)
    }

    /// Calls a Postgres function that takes no arguments.
    public func rpc<Response: Decodable & Sendable>(
        _ name: String,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await rpc(name, params: SupabaseNoBody(), as: type)
    }

    /// Invokes an Edge Function (`/functions/v1/<function>`) and decodes its reply.
    public func invoke<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        function: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await invokeRaw(function: function, body: body)
        return try decode(data)
    }

    /// Invokes an Edge Function and returns its raw body.
    @discardableResult
    public func invokeRaw<Body: Encodable & Sendable>(
        function: String,
        body: Body
    ) async throws -> Data {
        let request = SupabaseRequest(
            method: .post,
            path: "functions/v1/\(function)",
            body: try encode(body)
        )
        return try await execute(request)
    }

    /// Sends a request to the Supabase Auth (GoTrue) API and returns the raw body.
    ///
    /// Auth payloads are hand-built by ``SupabaseAuthService`` because GoTrue's
    /// request and response shapes are its own, not PostgREST's.
    public func authData(
        method: SupabaseMethod = .post,
        path: String,
        query: [SupabaseQueryItem] = [],
        body: Data? = nil,
        authorization: SupabaseAuthorization = .anonymous
    ) async throws -> Data {
        let request = SupabaseRequest(
            method: method,
            path: path,
            query: query,
            body: body,
            authorization: authorization
        )
        return try await execute(request)
    }

    /// Decodes `data` as JSON using the shared wire coder.
    public func decode<Response: Decodable & Sendable>(
        _ data: Data,
        as type: Response.Type = Response.self
    ) throws -> Response {
        do {
            return try JSONCoding.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Encodes `value` as JSON using the shared wire coder.
    public func encode<Body: Encodable & Sendable>(_ value: Body) throws -> Data {
        do {
            return try JSONCoding.encoder.encode(value)
        } catch {
            throw APIError.decoding("Could not encode request body: \(error)")
        }
    }

    // MARK: - Internals

    /// A request as this client models it, before it becomes a `URLRequest`.
    private struct SupabaseRequest: Sendable {
        var method: SupabaseMethod
        var path: String
        var query: [SupabaseQueryItem] = []
        var body: Data?
        var headers: [String: String] = [:]
        var authorization: SupabaseAuthorization = .session
    }

    /// The stand-in body for requests that carry none.
    private struct SupabaseNoBody: Codable, Sendable {}

    private func write<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        method: SupabaseMethod,
        table: String,
        values: Body?,
        filters: [PostgRESTFilter],
        preferences: [String],
        extraQuery: [SupabaseQueryItem],
        returning columns: String,
        singleRow: Bool
    ) async throws -> Response {
        if method != .post, filters.isEmpty {
            throw APIError.server(
                status: 400,
                message: "Refusing to \(method.rawValue) all of \(table) unfiltered"
            )
        }
        var query = [SupabaseQueryItem(name: "select", value: columns)]
        query.append(contentsOf: filters.map { SupabaseQueryItem(name: $0.name, value: $0.value) })
        query.append(contentsOf: extraQuery)

        var headers = ["Prefer": preferences.joined(separator: ",")]
        if singleRow {
            headers["Accept"] = Self.singleObjectAccept
        }

        let request = SupabaseRequest(
            method: method,
            path: "rest/v1/\(table)",
            query: query,
            body: try values.map { try encode($0) },
            headers: headers
        )
        let data = try await execute(request)
        return try decode(data)
    }

    /// Sends a request, refreshing the session once if the server rejects the token.
    private func execute(_ request: SupabaseRequest) async throws -> Data {
        if request.authorization == .session, let current = liveSession, current.isExpired() {
            _ = try await refreshSession()
        }
        do {
            return try await send(request)
        } catch APIError.unauthorized {
            guard request.authorization == .session, liveSession != nil else {
                throw APIError.unauthorized
            }
            _ = try await refreshSession()
            return try await send(request)
        }
    }

    /// Exchanges the refresh token for a new session, collapsing concurrent
    /// callers onto one in-flight exchange.
    private func refreshSession() async throws -> SupabaseSession {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let refreshToken = liveSession?.refreshToken, !refreshToken.isEmpty else {
            await discardSession()
            throw APIError.unauthorized
        }

        let task = Task<SupabaseSession, any Error> {
            try await self.exchange(refreshToken: refreshToken)
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            refreshTask = nil
            liveSession = refreshed
            await tokenStore.save(refreshed)
            return refreshed
        } catch {
            PRVLog.auth.error("Supabase session refresh failed; clearing local credentials")
            await discardSession()
            throw APIError.unauthorized
        }
    }

    private func exchange(refreshToken: String) async throws -> SupabaseSession {
        let request = SupabaseRequest(
            method: .post,
            path: "auth/v1/token",
            query: [SupabaseQueryItem(name: "grant_type", value: "refresh_token")],
            body: try encode(RefreshPayload(refreshToken: refreshToken)),
            authorization: .anonymous
        )
        let data = try await send(request)
        let response: SupabaseAuthResponse = try decode(data)
        guard let session = response.session() else {
            throw APIError.unauthorized
        }
        return session
    }

    /// The refresh-token grant body.
    private struct RefreshPayload: Encodable, Sendable {
        let refreshToken: String
    }

    /// Performs one HTTP round trip, retrying only what is safe to retry.
    private func send(_ request: SupabaseRequest) async throws -> Data {
        let urlRequest = try makeURLRequest(request)
        var attempt = 0

        while true {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 250_000_000))
            }
            do {
                let (data, response) = try await urlSession.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError.network(underlying: "Non-HTTP response for \(request.path)")
                }
                if (200 ..< 300).contains(http.statusCode) {
                    return data
                }
                let failure = Self.apiError(status: http.statusCode, response: http, data: data)
                guard attempt < Self.maximumRetries,
                      Self.isRetryable(failure, method: request.method)
                else { throw failure }
                attempt += 1
            } catch let error as APIError {
                throw error
            } catch {
                guard request.method == .get, attempt < Self.maximumRetries, !Task.isCancelled else {
                    throw APIError.network(underlying: String(describing: error))
                }
                attempt += 1
            }
        }
    }

    private func makeURLRequest(_ request: SupabaseRequest) throws -> URLRequest {
        let url = try Self.url(base: projectURL, path: request.path, query: request.query)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let bearer: String
        switch request.authorization {
        case .anonymous: bearer = anonKey
        case .session: bearer = liveSession?.accessToken ?? anonKey
        }
        urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    /// Builds the absolute URL, percent-encoding every query value itself so a
    /// PostgREST filter can carry commas, quotes, and braces intact.
    private static func url(base: URL, path: String, query: [SupabaseQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.network(underlying: "Malformed Supabase project URL")
        }
        var basePath = components.path
        if basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.path = basePath + "/" + path
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(escape($0.name))=\(escape($0.value))" }
                .joined(separator: "&")
        }
        guard let url = components.url else {
            throw APIError.network(underlying: "Malformed Supabase URL for \(path)")
        }
        return url
    }

    /// Everything outside this set is percent-encoded; PostgREST decodes the
    /// query before parsing it, so structure characters survive intact.
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~*()!"
    )

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    /// Maps an HTTP failure onto ``APIError``, preferring the body's own code.
    private static func apiError(status: Int, response: HTTPURLResponse, data: Data) -> APIError {
        let failure = SupabaseFailure(data: data)
        if let mapped = failure.mappedError() {
            return mapped
        }
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        // 406 is PostgREST's answer to `Accept: …pgrst.object+json` matching no row.
        case 404, 406:
            return .notFound
        case 409:
            return .conflict(failure.message ?? "That change conflicts with the current state.")
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .server(status: status, message: failure.message)
        }
    }

    /// Rate limiting never executed the request, so any verb may be retried.
    /// A 5xx may have executed, so only reads are retried.
    private static func isRetryable(_ error: APIError, method: SupabaseMethod) -> Bool {
        switch error {
        case .rateLimited: true
        case .server(let status, _): status >= 500 && method == .get
        default: false
        }
    }
}
