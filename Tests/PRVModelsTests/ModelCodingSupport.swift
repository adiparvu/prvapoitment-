import Foundation
import PRVModels

// MARK: - Any coding key

/// A coding key that carries whatever string a key strategy produces.
struct PRVAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Key case conversion

/// camelCase ↔︎ snake_case conversion that is a genuine **inverse pair**.
///
/// Foundation ships `.convertToSnakeCase` / `.convertFromSnakeCase`, but the two are
/// famously *not* inverses: `salonID → salon_id → salonId`. Every PRV model has
/// `...ID`-suffixed properties, so a payload encoded with Foundation's pair cannot be
/// decoded back — non-optional keys throw `keyNotFound`, optional ones silently
/// decode as `nil`. These tests therefore drive the encoder and decoder with a
/// matched `.custom` pair instead, built around a small acronym registry.
///
/// Round-tripping the registry itself is covered by `KeyStrategyTests`, so the
/// conversion cannot silently rot.
enum PRVKeyCase {
    /// Words that are rendered fully uppercase when converting back to camelCase.
    /// Plural forms are derived (`id → ID`, `ids → IDs`), so only the singular is
    /// listed. This is the project's acronym registry — extend it when a model
    /// introduces a new one.
    static let acronyms: Set<String> = ["id", "url"]

    /// `"heroImageURL" → "hero_image_url"`.
    ///
    /// An underscore is inserted before an uppercase character only when the previous
    /// character is lowercase (or a digit), so runs of capitals stay together and
    /// synthesized enum payload keys such as `_0` pass through untouched.
    static func toSnakeCase(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        var result = ""
        result.reserveCapacity(key.count + 4)
        var previous: Character?

        for character in key {
            if character.isUppercase {
                if let previous, previous != "_", !previous.isUppercase {
                    result.append("_")
                }
                result.append(contentsOf: character.lowercased())
            } else {
                result.append(character)
            }
            previous = character
        }
        return result
    }

    /// `"hero_image_url" → "heroImageURL"`. Leading and trailing underscores survive.
    static func toCamelCase(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        let characters = Array(key)

        var leading = 0
        while leading < characters.count, characters[leading] == "_" { leading += 1 }
        guard leading < characters.count else { return key }

        var trailing = 0
        while trailing < characters.count - leading,
              characters[characters.count - 1 - trailing] == "_" {
            trailing += 1
        }

        let core = String(characters[leading ..< (characters.count - trailing)])
        let components = core.split(separator: "_")
        guard let first = components.first else { return key }

        var body = String(first)
        for component in components.dropFirst() {
            body += displayForm(of: String(component))
        }
        return String(repeating: "_", count: leading) + body + String(repeating: "_", count: trailing)
    }

    private static func displayForm(of component: String) -> String {
        let lowered = component.lowercased()
        if acronyms.contains(lowered) {
            return lowered.uppercased()
        }
        if lowered.hasSuffix("s"), acronyms.contains(String(lowered.dropLast())) {
            return String(lowered.dropLast()).uppercased() + "s"
        }
        return lowered.prefix(1).uppercased() + String(lowered.dropFirst())
    }
}

// MARK: - Wire codec

/// The JSON shape PRV models travel in: ISO-8601 timestamps and snake_case keys —
/// the Supabase/PostgREST convention the backend serves.
enum PRVWireJSON {
    /// A fresh encoder. Keys are sorted so wire output is byte-stable across runs.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .custom { codingPath -> any CodingKey in
            guard let last = codingPath.last else { return PRVAnyCodingKey(stringValue: "") }
            return PRVAnyCodingKey(stringValue: PRVKeyCase.toSnakeCase(last.stringValue))
        }
        return encoder
    }

    /// A fresh decoder configured as the exact inverse of ``encoder``.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .custom { codingPath -> any CodingKey in
            guard let last = codingPath.last else { return PRVAnyCodingKey(stringValue: "") }
            return PRVAnyCodingKey(stringValue: PRVKeyCase.toCamelCase(last.stringValue))
        }
        return decoder
    }

    /// Encodes then decodes a value through the wire format.
    static func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        let data = try encoder.encode(value)
        return try decoder.decode(Value.self, from: data)
    }

    /// The raw JSON object a value encodes to, for asserting on wire keys.
    static func wireObject(for value: some Encodable) throws -> [String: Any] {
        let data = try encoder.encode(value)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// The top-level wire keys a value encodes to.
    static func wireKeys(for value: some Encodable) throws -> Set<String> {
        Set(try wireObject(for: value).keys)
    }
}

// MARK: - Fixtures

/// Deterministic model fixtures.
///
/// Every timestamp is a whole number of seconds since the epoch: the ISO-8601 coding
/// strategy carries no fractional seconds, so sub-second precision would make a
/// round-trip *look* lossy when the format is behaving exactly as designed. Doubles
/// are chosen to be exactly representable in binary for the same reason — these tests
/// are about the coding pipeline, not about floating point.
enum ModelFixtures {
    // MARK: Time

    /// 2026-03-02T12:00:00Z, to the second.
    static let reference = Date(timeIntervalSince1970: 1_772_452_800)
    static let oneHourLater = Date(timeIntervalSince1970: 1_772_456_400)

    // MARK: Identifiers

    static let salonID = Salon.ID("00000000-0000-0000-0001-000000000001")
    static let organizationID = Organization.ID("00000000-0000-0000-0007-000000000001")
    static let clientID = User.ID("00000000-0000-0000-0000-000000000001")
    static let professionalID = Professional.ID("00000000-0000-0000-0002-000000000001")
    static let serviceID = SalonService.ID("00000000-0000-0000-0003-000000000001")
    static let appointmentID = Appointment.ID("00000000-0000-0000-0004-000000000001")
    static let appointmentItemID = AppointmentItem.ID("00000000-0000-0000-0004-00000000000A")
    static let orderID = Order.ID("00000000-0000-0000-0008-000000000001")
    static let serviceLineID = OrderLine.ID("00000000-0000-0000-0008-00000000000A")
    static let productLineID = OrderLine.ID("00000000-0000-0000-0008-00000000000B")
    static let conversationID = Conversation.ID("00000000-0000-0000-0009-000000000001")
    static let messageID = ChatMessage.ID("00000000-0000-0000-0009-00000000000A")
    static let recommendationID = AssistantRecommendation.ID("00000000-0000-0000-0009-00000000000B")
    static let productReference = UUID(uuidString: "00000000-0000-0000-000B-000000000001") ?? UUID()

    static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/dev/null")
    }

    /// Exact decimal money, built from a string so no binary floating-point
    /// approximation ever reaches an assertion.
    static func money(_ literal: String, _ currency: Currency = .eur) -> Money {
        Money(Decimal(string: literal) ?? 0, currency)
    }

    // MARK: Models

    static var salon: Salon {
        Salon(
            id: salonID,
            name: "Maison Lumière",
            tagline: "Luxury hair & beauty atelier",
            about: "An award-winning atelier in the heart of Antwerp.",
            categories: [.hairSalon, .makeupStudio],
            address: Address(
                street: "Schuttershofstraat 24",
                city: "Antwerp",
                postalCode: "2000",
                country: "BE",
                coordinate: GeoCoordinate(latitude: 51.25, longitude: 4.375)
            ),
            phone: "+32 3 123 45 67",
            email: "hello@maisonlumiere.be",
            heroImageURL: url("https://cdn.prv.beauty/salons/lumiere/hero.jpg"),
            heroVideoURL: url("https://cdn.prv.beauty/salons/lumiere/tour.mp4"),
            galleryURLs: [
                url("https://cdn.prv.beauty/salons/lumiere/1.jpg"),
                url("https://cdn.prv.beauty/salons/lumiere/2.jpg"),
            ],
            instagramHandle: "maisonlumiere",
            tikTokHandle: "maisonlumiere",
            virtualTourURL: url("https://cdn.prv.beauty/salons/lumiere/360"),
            amenities: [.luxury, .parking, .wheelchairAccess],
            languages: ["en", "nl", "fr"],
            openingHours: [
                OpeningHours(weekday: 2, intervals: [.init(openMinutes: 540, closeMinutes: 1_140)]),
                OpeningHours(weekday: 1, intervals: []),
            ],
            rating: 4.5,
            reviewCount: 482,
            isVerified: true,
            currency: .eur,
            organizationID: organizationID,
            certificates: ["Colour Specialist"],
            awards: ["Belgian Salon of the Year 2025"],
            createdAt: reference
        )
    }

    static var appointment: Appointment {
        Appointment(
            id: appointmentID,
            salonID: salonID,
            salonName: "Maison Lumière",
            clientID: clientID,
            additionalClientIDs: [User.ID("00000000-0000-0000-0000-000000000009")],
            items: [
                AppointmentItem(
                    id: appointmentItemID,
                    serviceID: serviceID,
                    serviceName: "Balayage & Gloss",
                    professionalID: professionalID,
                    professionalName: "Amélie Dubois",
                    start: reference,
                    durationMinutes: 150,
                    price: Money(185),
                    addOnIDs: [ServiceAddOn.ID("00000000-0000-0000-0003-00000000000A")]
                ),
            ],
            status: .confirmed,
            recurrence: RecurrenceRule(frequency: .every4Weeks, occurrences: 6),
            orderID: orderID,
            clientNotes: "Please keep the length.",
            internalNotes: "Allergy: PPD.",
            createdAt: reference,
            updatedAt: oneHourLater
        )
    }

    static var order: Order {
        Order(
            id: orderID,
            salonID: salonID,
            clientID: clientID,
            appointmentID: appointmentID,
            lines: [
                OrderLine(
                    id: serviceLineID,
                    kind: .service,
                    title: "Balayage & Gloss",
                    quantity: 1,
                    unitPrice: Money(185)
                ),
                OrderLine(
                    id: productLineID,
                    kind: .product,
                    title: "Bond Maintenance Shampoo",
                    quantity: 2,
                    unitPrice: Money(32),
                    referenceID: productReference
                ),
            ],
            status: .partiallyPaid,
            discount: Money(24),
            discountReason: "Prepayment discount",
            vatPercent: 21,
            amountPaid: Money(100),
            pointsEarned: 235,
            currency: .eur,
            createdAt: reference,
            paidAt: oneHourLater
        )
    }

    static var recommendation: AssistantRecommendation {
        AssistantRecommendation(
            id: recommendationID,
            headline: "Your bridal countdown plan",
            rationale: "A trial now, gloss the week of.",
            serviceIDs: [serviceID],
            salonIDs: [salonID],
            professionalIDs: [professionalID],
            packageIDs: [ServicePackage.ID("00000000-0000-0000-0006-000000000001")],
            suggestedSlots: [
                TimeSlot(
                    start: reference,
                    end: oneHourLater,
                    professionalID: professionalID,
                    optimizationScore: 0.75
                ),
            ],
            maintenanceAdvice: "Book a gloss refresh 5 days before."
        )
    }

    /// A chat message carrying the given payload, with everything else fixed.
    static func message(_ content: ChatMessage.Content) -> ChatMessage {
        ChatMessage(
            id: messageID,
            conversationID: conversationID,
            senderID: clientID,
            isFromAssistant: false,
            content: content,
            deliveryState: .delivered,
            sentAt: reference
        )
    }
}
