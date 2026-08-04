import Foundation
import Testing
import PRVModels
import PRVNetworking

// Shared helpers for the networking suites: a comparable summary of
// `APIError`, canonical PostgREST-shaped payloads, and small JSON utilities.

/// A comparable summary of an ``APIError``.
///
/// `APIError` is deliberately not `Equatable` in the shipping module — adding
/// a retroactive conformance from a test target would be worse than the small
/// projection below, which also keeps the assertion messages readable.
enum APIErrorKind: Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case conflict(String)
    case rateLimited(TimeInterval?)
    case server(status: Int, message: String?)
    case network
    case decoding
    case offline
}

extension APIError {
    /// This error reduced to something a test can compare.
    var kind: APIErrorKind {
        switch self {
        case .unauthorized: .unauthorized
        case .forbidden: .forbidden
        case .notFound: .notFound
        case .conflict(let body): .conflict(body)
        case .rateLimited(let retryAfter): .rateLimited(retryAfter)
        case .server(let status, let message): .server(status: status, message: message)
        case .network: .network
        case .decoding: .decoding
        case .offline: .offline
        }
    }

    /// The status of a `.server` error, or `nil` for every other case.
    var serverStatus: Int? {
        guard case .server(let status, _) = self else { return nil }
        return status
    }
}

/// Wire-shaped payloads and JSON helpers.
enum WireFixtures {
    /// A salon row as PostgREST serves it: snake_case columns, ISO-8601
    /// timestamps, and every acronym-suffixed key Foundation's built-in
    /// strategies mangle.
    static let salonRow = """
    {
      "id": "00000000-0000-0000-0001-000000000001",
      "name": "Maison Lumière",
      "tagline": "Luxury hair & beauty atelier",
      "about": "An award-winning atelier.",
      "categories": ["hair_salon", "makeup_studio"],
      "address": {
        "street": "Schuttershofstraat 24",
        "city": "Antwerp",
        "postal_code": "2000",
        "country": "BE",
        "coordinate": { "latitude": 51.2178, "longitude": 4.4041 }
      },
      "phone": "+32 3 123 45 67",
      "email": null,
      "hero_image_url": "https://cdn.prv.beauty/salons/lumiere/hero.jpg",
      "hero_video_url": null,
      "gallery_urls": [
        "https://cdn.prv.beauty/salons/lumiere/1.jpg",
        "https://cdn.prv.beauty/salons/lumiere/2.jpg"
      ],
      "instagram_handle": "maisonlumiere",
      "tik_tok_handle": null,
      "virtual_tour_url": null,
      "amenities": ["luxury", "parking", "wifi"],
      "languages": ["en", "nl", "fr"],
      "opening_hours": [{ "weekday": 2, "intervals": [{ "open_minutes": 540, "close_minutes": 1140 }] }],
      "policies": {
        "free_cancellation_hours": 24,
        "late_cancellation_fee_percent": 50,
        "no_show_fee_percent": 100,
        "late_grace_minutes": 10,
        "children_allowed": true,
        "notes": null
      },
      "prepayment_policy": {
        "offered_percents": [20, 50, 100],
        "full_prepayment_discount_percent": 10,
        "reward_points_multiplier": 2,
        "cashback_percent": 2,
        "grants_priority_booking": true
      },
      "rating": 4.9,
      "review_count": 482,
      "is_verified": true,
      "currency": "EUR",
      "organization_id": "00000000-0000-0000-0009-000000000001",
      "certificates": ["L'Oréal Colour Specialist"],
      "awards": ["Belgian Hair Awards 2025"],
      "created_at": "2026-01-05T09:30:00Z"
    }
    """

    /// The wire representation of `value`, as a dictionary of top-level keys.
    static func wireObject(for value: some Encodable) throws -> [String: Any] {
        let data = try JSONCoding.encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    /// Every top-level key `value` writes to the wire.
    static func wireKeys(for value: some Encodable) throws -> Set<String> {
        Set(try wireObject(for: value).keys)
    }

    /// Encodes then decodes `value` through the shared wire coder.
    static func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONCoding.decoder.decode(Value.self, from: JSONCoding.encoder.encode(value))
    }

    /// Decodes a JSON literal with the shared wire coder.
    static func decode<Value: Decodable>(
        _ type: Value.Type = Value.self,
        from json: String
    ) throws -> Value {
        try JSONCoding.decoder.decode(Value.self, from: Data(json.utf8))
    }
}

/// Domain fixtures the networking suites assert against.
enum NetworkingFixtures {
    /// A fixed instant so encoded timestamps are comparable.
    static let reference = Date(timeIntervalSince1970: 1_772_000_000)

    /// A salon carrying every acronym-suffixed field at once.
    static var salon: Salon {
        Salon(
            id: PreviewData.salonLumiere.id,
            name: "Maison Lumière",
            tagline: "Luxury hair & beauty atelier",
            about: "An award-winning atelier.",
            categories: [.hairSalon, .makeupStudio],
            address: Address(
                street: "Schuttershofstraat 24",
                city: "Antwerp",
                postalCode: "2000",
                country: "BE",
                coordinate: GeoCoordinate(latitude: 51.2178, longitude: 4.4041)
            ),
            heroImageURL: url("https://cdn.prv.beauty/salons/lumiere/hero.jpg"),
            galleryURLs: [
                url("https://cdn.prv.beauty/salons/lumiere/1.jpg"),
                url("https://cdn.prv.beauty/salons/lumiere/2.jpg"),
            ],
            instagramHandle: "maisonlumiere",
            tikTokHandle: "maisonlumiere",
            amenities: [.luxury, .parking, .wifi],
            languages: ["en", "nl", "fr"],
            openingHours: [OpeningHours(weekday: 2, intervals: [.init(openMinutes: 540, closeMinutes: 1_140)])],
            rating: 4.9,
            reviewCount: 482,
            isVerified: true,
            organizationID: PRVID<Organization>("00000000-0000-0000-0009-000000000001"),
            createdAt: reference
        )
    }

    /// A group appointment: nested items plus the `additional_client_ids`
    /// array that a naive snake_case pair silently drops.
    static var groupAppointment: Appointment {
        Appointment(
            id: PreviewData.upcomingAppointment.id,
            salonID: PreviewData.salonLumiere.id,
            salonName: "Maison Lumière",
            clientID: PreviewData.client.id,
            additionalClientIDs: [User.ID("00000000-0000-0000-0000-000000000021")],
            items: [
                AppointmentItem(
                    serviceID: PreviewData.serviceBalayage.id,
                    serviceName: "Balayage & Gloss",
                    professionalID: PreviewData.stylistAmelie.id,
                    professionalName: "Amélie Dubois",
                    start: reference,
                    durationMinutes: 150,
                    price: Money(185),
                    addOnIDs: [ServiceAddOn.ID("00000000-0000-0000-0007-000000000001")]
                ),
            ],
            status: .confirmed,
            recurrence: RecurrenceRule(frequency: .every4Weeks, occurrences: 6),
            clientNotes: "Please keep it dimensional.",
            createdAt: reference,
            updatedAt: reference
        )
    }

    /// Exact decimal money, built from a string so no binary floating-point
    /// approximation ever reaches an assertion.
    static func money(_ literal: String, _ currency: Currency = .eur) -> Money {
        Money(Decimal(string: literal) ?? 0, currency)
    }

    /// A URL literal, without a force unwrap.
    static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Fixture URL is a literal and always parses: \(string)")
        }
        return url
    }
}

// MARK: - Capturing a thrown APIError

/// Runs `operation` and returns the ``APIError`` it throws.
///
/// `#expect(throws:)` only asserts that something was thrown — it does not hand
/// the error back — so inspecting the case requires catching it. This keeps the
/// call sites to one line while still recording a proper issue (rather than
/// crashing) when the call unexpectedly succeeds or throws something else.
func apiError(
    _ operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> APIError? {
    do {
        try await operation()
        Issue.record("Expected an APIError, but the call succeeded.", sourceLocation: sourceLocation)
        return nil
    } catch let error as APIError {
        return error
    } catch {
        Issue.record("Expected an APIError, got \(error).", sourceLocation: sourceLocation)
        return nil
    }
}

/// Synchronous counterpart of ``apiError(_:sourceLocation:)``.
func apiError(
    _ operation: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) -> APIError? {
    do {
        try operation()
        Issue.record("Expected an APIError, but the call succeeded.", sourceLocation: sourceLocation)
        return nil
    } catch let error as APIError {
        return error
    } catch {
        Issue.record("Expected an APIError, got \(error).", sourceLocation: sourceLocation)
        return nil
    }
}
