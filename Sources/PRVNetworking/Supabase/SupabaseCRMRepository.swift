import Foundation
import PRVFoundation
import PRVModels

/// A column that is written even when its value is `nil`.
///
/// Swift synthesizes `encodeIfPresent` for an optional stored property, so a
/// `nil` simply disappears from the request body — and a PostgREST upsert
/// resolved with `merge-duplicates` then leaves whatever the column already held
/// in place. That silently turns "the user cleared this field" into "nothing
/// changed", and on `coupons` it is worse than cosmetic: moving a discount from
/// `percent` to `fixed` has to null `discount_percent` or the
/// `coupons_percent_payload` check constraint from `0001_schema.sql` rejects the
/// row outright.
///
/// Wrapping the value makes the property non-optional, so the synthesized
/// encoder always calls `encode(_:forKey:)` and this type writes an explicit
/// JSON `null`. An upsert built from a whole domain value therefore replaces the
/// row exactly the way `InMemoryBackend` replaces its element.
///
/// Shared by the business-side repositories — CRM, team, inventory, marketing.
struct SupabaseNullableColumn<Wrapped: Encodable & Sendable>: Encodable, Sendable {
    /// The value to write, or `nil` to write SQL `NULL`.
    let wrapped: Wrapped?

    /// Wraps a value that must reach the server even when it is absent.
    init(_ wrapped: Wrapped?) {
        self.wrapped = wrapped
    }

    /// Encodes the value, or an explicit `null`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrapped {
            try container.encode(wrapped)
        } else {
            try container.encodeNil()
        }
    }
}

/// The live ``CRMRepository``, backed by the `client_records`,
/// `client_favorite_products`, `client_notes`, and `consent_forms` tables.
///
/// CRM is the most tightly scoped data in the platform. `0002_rls.sql` gives
/// `client_records` a select policy of "the client themselves, or salon staff
/// holding `viewClients`" and a write policy of "salon staff holding
/// `manageCRM`"; colour formulas in `client_notes` never leave the salon that
/// wrote them, not even to the client they describe. Nothing here re-implements
/// any of that — a caller simply sees what the policies grant.
///
/// A client record absorbs one child table (`client_favorite_products`), which
/// is embedded on every read so a profile is a single round trip.
public struct SupabaseCRMRepository: CRMRepository, Sendable {
    private let client: SupabaseClient

    /// Widest set of rows any list endpoint returns, so one careless filter can
    /// never page a salon's whole client book into memory.
    private static let listLimit = 200

    /// The client projection: the row plus the favourites its value type absorbs.
    private static let clientColumns = "*,client_favorite_products(product_id)"

    /// Creates the repository.
    ///
    /// - Parameter client: The shared Supabase transport.
    public init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: - Client records

    /// The salon's clients, optionally narrowed by a free-text search.
    ///
    /// Search is a case-insensitive substring match across `first_name` and
    /// `last_name`, combined with `or`. `InMemoryBackend` matches the same needle
    /// against the joined `fullName`; splitting it over the two columns is the
    /// closest a single indexed query gets, and it is what a receptionist typing
    /// half a surname actually wants.
    public func clients(salonID: Salon.ID, searchText: String) async throws -> [ClientRecord] {
        var request = PostgRESTQuery("client_records")
            .selecting(Self.clientColumns)
            .filter(.equals("salon_id", salonID.rawValue))
            .order("last_name")
            .order("first_name")
            .limited(to: Self.listLimit)

        let needle = searchText.trimmed
        if !needle.isEmpty {
            request = request.filter(.any(of: [
                .caseInsensitiveContains("first_name", needle),
                .caseInsensitiveContains("last_name", needle),
            ]))
        }

        let rows: [ClientRecordRow] = try await client.select(request)
        return try rows.map(Self.makeClientRecord)
    }

    /// One client record, with its favourite products.
    public func client(id: ClientRecord.ID) async throws -> ClientRecord {
        let row: ClientRecordRow = try await client.select(
            PostgRESTQuery("client_records")
                .selecting(Self.clientColumns)
                .filter(.equals("id", id.rawValue))
                .single()
        )
        return try Self.makeClientRecord(row)
    }

    /// Creates or replaces a client record, returning it as stored.
    ///
    /// The row is upserted on its primary key, so the same call serves the "new
    /// client" sheet and every later edit — which is exactly what
    /// `InMemoryBackend.upsertClient(_:)` does with its array.
    ///
    /// `favoriteProductIDs` lives in the `client_favorite_products` join table
    /// rather than in a column, so it is reconciled against what the upsert
    /// returned: only genuinely added rows are written and only genuinely removed
    /// ones are deleted. An unchanged favourites list costs no extra round trip.
    ///
    /// `created_at` is never sent — the database is the single clock — and
    /// `updated_at` is stamped by the `client_records_set_updated_at` trigger.
    public func upsertClient(_ record: ClientRecord) async throws -> ClientRecord {
        let payload = ClientRecordUpsert(
            id: record.id.rawValue,
            salonID: record.salonID.rawValue,
            userID: SupabaseNullableColumn(record.userID?.rawValue),
            firstName: record.firstName,
            lastName: record.lastName,
            email: SupabaseNullableColumn(record.email),
            phone: SupabaseNullableColumn(record.phone),
            avatarURL: SupabaseNullableColumn(record.avatarURL?.absoluteString),
            birthday: SupabaseNullableColumn(record.birthday.map { Self.calendarDateString(from: $0) }),
            skinType: SupabaseNullableColumn(record.skinType),
            hairType: SupabaseNullableColumn(record.hairType),
            allergies: record.allergies,
            preferences: record.preferences,
            totalVisits: record.totalVisits,
            totalSpendAmount: record.totalSpend.amount,
            totalSpendCurrency: record.totalSpend.currency.rawValue,
            lastVisitAt: SupabaseNullableColumn(record.lastVisitAt.map(SupabaseTimestamp.string(from:)))
        )
        let stored: ClientRecordRow = try await client.upsert(
            into: "client_records",
            values: payload,
            onConflict: "id",
            returning: Self.clientColumns
        )

        let desired = Set(record.favoriteProductIDs.map(\.rawValue))
        let current = Set((stored.clientFavoriteProducts?.values ?? []).map(\.productID))
        guard desired != current else { return try Self.makeClientRecord(stored) }

        let removed = current.subtracting(desired)
        if !removed.isEmpty {
            try await client.deleteRows(
                from: "client_favorite_products",
                filters: [
                    .equals("client_record_id", record.id.rawValue),
                    .within("product_id", Array(removed)),
                ]
            )
        }

        let added = desired.subtracting(current)
        if !added.isEmpty {
            let rows = added.map {
                FavoriteProductUpsert(clientRecordID: record.id.rawValue, productID: $0)
            }
            _ = try await client.upsert(
                into: "client_favorite_products",
                values: rows,
                onConflict: "client_record_id,product_id",
                returning: "product_id",
                singleRow: false,
                as: [FavoriteProductRow].self
            )
        }

        var reconciled = try Self.makeClientRecord(stored)
        reconciled.favoriteProductIDs = record.favoriteProductIDs
        return reconciled
    }

    // MARK: - Notes

    /// A client's notes, newest first.
    public func notes(clientRecordID: ClientRecord.ID) async throws -> [ClientNote] {
        let request = PostgRESTQuery("client_notes")
            .filter(.equals("client_record_id", clientRecordID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [ClientNoteRow] = try await client.select(request)
        return try rows.map(Self.makeNote)
    }

    /// Appends a note to a client record.
    ///
    /// `author_id` travels with the note because `client_notes_write_staff`
    /// requires it to equal `auth.uid()` — the database refuses a note attributed
    /// to anyone but its writer. `created_at` is left to the server.
    public func addNote(_ note: ClientNote) async throws -> ClientNote {
        let payload = ClientNoteInsert(
            id: note.id.rawValue,
            clientRecordID: note.clientRecordID.rawValue,
            authorID: note.authorID.rawValue,
            kind: note.kind.rawValue,
            text: note.text,
            photoURLs: note.photoURLs.map(\.absoluteString),
            appointmentID: note.appointmentID?.rawValue
        )
        let row: ClientNoteRow = try await client.insert(into: "client_notes", values: payload)
        return try Self.makeNote(row)
    }

    // MARK: - Consent

    /// A client's consent forms, newest first.
    public func consentForms(clientRecordID: ClientRecord.ID) async throws -> [ConsentForm] {
        let request = PostgRESTQuery("consent_forms")
            .filter(.equals("client_record_id", clientRecordID.rawValue))
            .order("created_at", ascending: false)
            .limited(to: Self.listLimit)
        let rows: [ConsentFormRow] = try await client.select(request)
        return rows.map(Self.makeConsentForm)
    }

    /// Creates or replaces a consent form, returning it as stored.
    ///
    /// Forms are versioned so a salon can prove which text was signed:
    /// `consent_forms_version_key` is unique on
    /// `(client_record_id, title, version)`, so re-signing under a new version
    /// adds a row rather than overwriting the evidence. The upsert resolves on
    /// the primary key, which is what makes signing an existing draft an update
    /// and a new version an insert.
    public func saveConsentForm(_ form: ConsentForm) async throws -> ConsentForm {
        let payload = ConsentFormUpsert(
            id: form.id.rawValue,
            clientRecordID: form.clientRecordID.rawValue,
            title: form.title,
            version: form.version,
            documentURL: SupabaseNullableColumn(form.documentURL?.absoluteString),
            signedAt: SupabaseNullableColumn(form.signedAt.map(SupabaseTimestamp.string(from:)))
        )
        let row: ConsentFormRow = try await client.upsert(
            into: "consent_forms",
            values: payload,
            onConflict: "id"
        )
        return Self.makeConsentForm(row)
    }

    // MARK: - Calendar dates

    /// Renders a birthday as the plain `YYYY-MM-DD` a `date` column stores.
    ///
    /// A birthday is a calendar date, not an instant. Rendering the picked
    /// `Date` in UTC would move it a day for anyone far enough east or west of
    /// Greenwich, so the device's calendar decides which day was meant and that
    /// day is what is stored.
    private static func calendarDateString(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1_970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Parses a `date` column back into local midnight on that calendar day.
    ///
    /// PostgREST renders a `date` without a time part, which
    /// ``SupabaseTimestamp`` deliberately rejects, so the three fields are read
    /// here and handed to the calendar that wrote them.
    private static func calendarDate(from text: String?, calendar: Calendar = .current) -> Date? {
        guard let trimmedText = text?.trimmed, !trimmedText.isEmpty else { return nil }
        let fields = trimmedText.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let year = Int(fields[0]),
              let month = Int(fields[1]),
              let day = Int(fields[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    // MARK: - Row mapping

    private static func makeClientRecord(_ row: ClientRecordRow) throws -> ClientRecord {
        ClientRecord(
            id: ClientRecord.ID(row.id),
            salonID: Salon.ID(row.salonID),
            userID: row.userID.map { User.ID($0) },
            firstName: row.firstName,
            lastName: row.lastName,
            email: row.email,
            phone: row.phone,
            avatarURL: row.avatarURL.flatMap(URL.init(string:)),
            birthday: calendarDate(from: row.birthday),
            skinType: row.skinType,
            hairType: row.hairType,
            allergies: row.allergies,
            preferences: row.preferences,
            favoriteProductIDs: (row.clientFavoriteProducts?.values ?? []).map { Product.ID($0.productID) },
            totalVisits: row.totalVisits,
            totalSpend: Money(
                row.totalSpendAmount,
                Currency(rawValue: row.totalSpendCurrency.trimmed) ?? .eur
            ),
            lastVisitAt: SupabaseTimestamp.optionalDate(from: row.lastVisitAt),
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }

    private static func makeNote(_ row: ClientNoteRow) throws -> ClientNote {
        ClientNote(
            id: ClientNote.ID(row.id),
            clientRecordID: ClientRecord.ID(row.clientRecordID),
            authorID: User.ID(row.authorID),
            kind: ClientNote.Kind(rawValue: row.kind) ?? .general,
            text: row.text,
            photoURLs: row.photoURLs.compactMap(URL.init(string:)),
            appointmentID: row.appointmentID.map { Appointment.ID($0) },
            createdAt: try SupabaseTimestamp.date(from: row.createdAt)
        )
    }

    private static func makeConsentForm(_ row: ConsentFormRow) -> ConsentForm {
        ConsentForm(
            id: ConsentForm.ID(row.id),
            clientRecordID: ClientRecord.ID(row.clientRecordID),
            title: row.title,
            version: row.version,
            documentURL: row.documentURL.flatMap(URL.init(string:)),
            signedAt: SupabaseTimestamp.optionalDate(from: row.signedAt)
        )
    }
}

// MARK: - Rows

extension SupabaseCRMRepository {
    /// A `client_records` row plus its embedded favourite products.
    fileprivate struct ClientRecordRow: Decodable, Sendable {
        let id: UUID
        let salonID: UUID
        let userID: UUID?
        let firstName: String
        let lastName: String
        let email: String?
        let phone: String?
        let avatarURL: String?
        let birthday: String?
        let skinType: String?
        let hairType: String?
        let allergies: [String]
        let preferences: [String]
        let totalVisits: Int
        let totalSpendAmount: Decimal
        let totalSpendCurrency: String
        let lastVisitAt: String?
        let createdAt: String
        let clientFavoriteProducts: SupabaseEmbedded<FavoriteProductRow>?
    }

    /// A `client_favorite_products` join row.
    fileprivate struct FavoriteProductRow: Decodable, Sendable {
        let productID: UUID
    }

    /// A `client_notes` row.
    fileprivate struct ClientNoteRow: Decodable, Sendable {
        let id: UUID
        let clientRecordID: UUID
        let authorID: UUID
        let kind: String
        let text: String
        let photoURLs: [String]
        let appointmentID: UUID?
        let createdAt: String
    }

    /// A `consent_forms` row.
    fileprivate struct ConsentFormRow: Decodable, Sendable {
        let id: UUID
        let clientRecordID: UUID
        let title: String
        let version: String
        let documentURL: String?
        let signedAt: String?
    }
}

// MARK: - Payloads

extension SupabaseCRMRepository {
    /// A whole client record, merged onto the primary key.
    fileprivate struct ClientRecordUpsert: Encodable, Sendable {
        let id: UUID
        let salonID: UUID
        let userID: SupabaseNullableColumn<UUID>
        let firstName: String
        let lastName: String
        let email: SupabaseNullableColumn<String>
        let phone: SupabaseNullableColumn<String>
        let avatarURL: SupabaseNullableColumn<String>
        let birthday: SupabaseNullableColumn<String>
        let skinType: SupabaseNullableColumn<String>
        let hairType: SupabaseNullableColumn<String>
        let allergies: [String]
        let preferences: [String]
        let totalVisits: Int
        let totalSpendAmount: Decimal
        let totalSpendCurrency: String
        let lastVisitAt: SupabaseNullableColumn<String>
    }

    /// One `client_favorite_products` link.
    fileprivate struct FavoriteProductUpsert: Encodable, Sendable {
        let clientRecordID: UUID
        let productID: UUID
    }

    /// A new `client_notes` row.
    fileprivate struct ClientNoteInsert: Encodable, Sendable {
        let id: UUID
        let clientRecordID: UUID
        let authorID: UUID
        let kind: String
        let text: String
        let photoURLs: [String]
        let appointmentID: UUID?
    }

    /// A whole consent form, merged onto the primary key.
    fileprivate struct ConsentFormUpsert: Encodable, Sendable {
        let id: UUID
        let clientRecordID: UUID
        let title: String
        let version: String
        let documentURL: SupabaseNullableColumn<String>
        let signedAt: SupabaseNullableColumn<String>
    }
}
