import Foundation
import PRVModels
import PRVNetworking
import Testing

/// The wire layer's first contract: the Supabase schema is snake_case, the
/// domain models are camelCase with acronyms, and ``PRVKeyCase`` is the only
/// thing standing between them.
@Suite("Wire coding — PRVKeyCase and JSONCoding")
struct WireCodingTests {
    // MARK: - Key conversion

    @Test("snake_case columns become the acronym-correct camelCase properties")
    func snakeToCamelKeepsAcronymsUppercase() {
        #expect(PRVKeyCase.toCamelCase("salon_id") == "salonID")
        #expect(PRVKeyCase.toCamelCase("client_id") == "clientID")
        #expect(PRVKeyCase.toCamelCase("gallery_urls") == "galleryURLs")
        #expect(PRVKeyCase.toCamelCase("hero_image_url") == "heroImageURL")
        #expect(PRVKeyCase.toCamelCase("additional_client_ids") == "additionalClientIDs")
        #expect(PRVKeyCase.toCamelCase("pdf_url") == "pdfURL")
        #expect(PRVKeyCase.toCamelCase("organization_id") == "organizationID")
        #expect(PRVKeyCase.toCamelCase("tik_tok_handle") == "tikTokHandle")
        #expect(PRVKeyCase.toCamelCase("id") == "id")
    }

    @Test("camelCase properties become the exact columns the schema declares")
    func camelToSnakeMatchesTheSchema() {
        #expect(PRVKeyCase.toSnakeCase("salonID") == "salon_id")
        #expect(PRVKeyCase.toSnakeCase("galleryURLs") == "gallery_urls")
        #expect(PRVKeyCase.toSnakeCase("heroImageURL") == "hero_image_url")
        #expect(PRVKeyCase.toSnakeCase("additionalClientIDs") == "additional_client_ids")
        #expect(PRVKeyCase.toSnakeCase("pdfURL") == "pdf_url")
        #expect(PRVKeyCase.toSnakeCase("tikTokHandle") == "tik_tok_handle")
        #expect(PRVKeyCase.toSnakeCase("vatPercent") == "vat_percent")
        #expect(PRVKeyCase.toSnakeCase("id") == "id")
    }

    @Test("The pair is a true inverse for every key shape the models use")
    func conversionIsLossless() {
        let keys = [
            "id", "salonID", "clientID", "appointmentID", "orderID", "organizationID",
            "entityID", "professionalID", "conversationID", "clientRecordID",
            "additionalClientIDs", "addOnIDs", "serviceIDs", "packageIDs", "professionalIDs",
            "heroImageURL", "heroVideoURL", "virtualTourURL", "galleryURLs", "photoURLs",
            "videoURLs", "avatarURL", "pdfURL", "authorAvatarURL", "imageURL",
            "tikTokHandle", "instagramHandle", "isStartingPrice", "requiresPrepayment",
            "vatPercent", "amountPaid", "pointsEarned", "discountReason", "unitPrice",
            "totalOccupancyMinutes", "preparationMinutes", "cleanupMinutes", "bufferMinutes",
            "lastDailyRewardAt", "currentStreakDays", "spendablePoints", "referralCode",
            "createdAt", "updatedAt", "paidAt", "sentAt", "expiresAt", "attemptCount",
        ]

        for key in keys {
            let wire = PRVKeyCase.toSnakeCase(key)
            #expect(
                PRVKeyCase.toCamelCase(wire) == key,
                "\(key) → \(wire) → \(PRVKeyCase.toCamelCase(wire))"
            )
        }
    }

    @Test("Synthesized enum payload keys survive untouched")
    func enumPayloadKeysSurvive() {
        // `_0` is what the compiler emits for a single-associated-value case;
        // mangling it would break every `Coupon.Discount` on the wire.
        #expect(PRVKeyCase.toSnakeCase("_0") == "_0")
        #expect(PRVKeyCase.toCamelCase("_0") == "_0")
        #expect(PRVKeyCase.toCamelCase("_") == "_")
        #expect(PRVKeyCase.toSnakeCase("") == "")
        #expect(PRVKeyCase.toCamelCase("") == "")
    }

    @Test("Foundation's own strategies cannot do this job")
    func foundationStrategiesAreNotInverses() throws {
        struct Row: Codable {
            var salonID: String
            var galleryURLs: [String]
        }

        let row = Row(salonID: "abc", galleryURLs: ["https://example.com/1.jpg"])

        // Encoding: Foundation splits the acronym into nonsense columns.
        let foundationEncoder = JSONEncoder()
        foundationEncoder.keyEncodingStrategy = .convertToSnakeCase
        let foundationKeys = try keys(of: foundationEncoder.encode(row))
        #expect(foundationKeys.contains("gallery_ur_ls"))
        #expect(!foundationKeys.contains("gallery_urls"))

        // Decoding: Foundation produces `salonId`, which matches no property.
        let foundationDecoder = JSONDecoder()
        foundationDecoder.keyDecodingStrategy = .convertFromSnakeCase
        let wireRow = Data(#"{"salon_id":"abc","gallery_urls":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try foundationDecoder.decode(Row.self, from: wireRow)
        }

        // JSONCoding handles both directions.
        let prvKeys = try keys(of: JSONCoding.encoder.encode(row))
        #expect(prvKeys.contains("gallery_urls"))
        #expect(prvKeys.contains("salon_id"))
        let decoded = try JSONCoding.decoder.decode(Row.self, from: wireRow)
        #expect(decoded.salonID == "abc")
    }

    // MARK: - Decoding PostgREST rows

    @Test("A PostgREST salon row decodes with every acronym field populated")
    func salonRowDecodes() throws {
        let salon: Salon = try WireFixtures.decode(from: WireFixtures.salonRow)

        #expect(salon.id == PreviewData.salonLumiere.id)
        #expect(salon.name == "Maison Lumière")
        #expect(salon.galleryURLs.count == 2)
        #expect(salon.heroImageURL?.absoluteString == "https://cdn.prv.beauty/salons/lumiere/hero.jpg")
        #expect(salon.organizationID != nil)
        #expect(salon.tikTokHandle == nil)
        #expect(salon.isVerified)
        #expect(salon.reviewCount == 482)
        #expect(salon.currency == .eur)
    }

    @Test("Nested objects convert their keys too")
    func nestedKeysConvert() throws {
        let salon: Salon = try WireFixtures.decode(from: WireFixtures.salonRow)

        #expect(salon.address.postalCode == "2000")
        #expect(salon.openingHours.first?.intervals.first?.openMinutes == 540)
        #expect(salon.openingHours.first?.intervals.first?.closeMinutes == 1_140)
        #expect(salon.policies.freeCancellationHours == 24)
        #expect(salon.policies.lateCancellationFeePercent == 50)
        #expect(salon.prepaymentPolicy.fullPrepaymentDiscountPercent == 10)
        #expect(salon.prepaymentPolicy.grantsPriorityBooking)
    }

    @Test("Columns the client does not know about are ignored, not fatal")
    func unknownColumnsAreIgnored() throws {
        // PostgREST returns every column of a table; a migration that adds one
        // must not break clients that have not shipped yet.
        let augmented = WireFixtures.salonRow.replacingOccurrences(
            of: "\"name\":",
            with: "\"loyalty_multiplier\": 3, \"name\":"
        )
        let salon: Salon = try WireFixtures.decode(from: augmented)

        #expect(salon.name == "Maison Lumière")
    }

    @Test("Timestamps are ISO-8601 in both directions")
    func timestampsAreISO8601() throws {
        let salon: Salon = try WireFixtures.decode(from: WireFixtures.salonRow)
        let expected = ISO8601DateFormatter().date(from: "2026-01-05T09:30:00Z")
        #expect(salon.createdAt == expected)

        let object = try WireFixtures.wireObject(for: NetworkingFixtures.salon)
        let createdAt = try #require(object["created_at"] as? String)
        #expect(createdAt.contains("T"))
        #expect(createdAt.hasSuffix("Z"))
        #expect(ISO8601DateFormatter().date(from: createdAt) == NetworkingFixtures.reference)
    }

    // MARK: - Encoding domain values

    @Test("Encoding a salon writes the columns the schema declares")
    func salonEncodesToSchemaColumns() throws {
        let keys = try WireFixtures.wireKeys(for: NetworkingFixtures.salon)

        #expect(keys.contains("gallery_urls"))
        #expect(keys.contains("hero_image_url"))
        #expect(keys.contains("tik_tok_handle"))
        #expect(keys.contains("instagram_handle"))
        #expect(keys.contains("organization_id"))
        #expect(keys.contains("review_count"))
        #expect(keys.contains("is_verified"))
        #expect(keys.contains("prepayment_policy"))
        #expect(keys.contains("created_at"))
        #expect(!keys.contains("galleryURLs"))
        #expect(!keys.contains("gallery_ur_ls"))
        #expect(!keys.contains("salonID"))
    }

    @Test("A group appointment round-trips with its nested items intact")
    func appointmentRoundTrips() throws {
        let original = NetworkingFixtures.groupAppointment
        let decoded = try WireFixtures.roundTrip(original)

        #expect(decoded == original)
        #expect(decoded.additionalClientIDs == original.additionalClientIDs)
        #expect(decoded.items.first?.addOnIDs == original.items.first?.addOnIDs)
        #expect(decoded.items.first?.professionalID == PreviewData.stylistAmelie.id)
        #expect(decoded.recurrence?.frequency == .every4Weeks)
        #expect(decoded.start == original.start)

        let keys = try WireFixtures.wireKeys(for: original)
        #expect(keys.contains("additional_client_ids"))
        #expect(keys.contains("salon_id"))
        #expect(keys.contains("client_id"))
        #expect(keys.contains("client_notes"))
    }

    @Test("A salon round-trips unchanged through the wire coder")
    func salonRoundTrips() throws {
        let original = NetworkingFixtures.salon
        let decoded = try WireFixtures.roundTrip(original)

        #expect(decoded == original)
        #expect(decoded.galleryURLs == original.galleryURLs)
        #expect(decoded.organizationID == original.organizationID)
        #expect(decoded.openingHours == original.openingHours)
    }

    @Test("Money keeps exact decimal precision across the wire")
    func moneyKeepsPrecision() throws {
        // Amounts are built from strings, never float literals: these tests are
        // about the coding pipeline, not about binary floating point.
        let line = OrderLine(
            kind: .service,
            title: "Balayage & Gloss",
            unitPrice: NetworkingFixtures.money("185.55")
        )
        let order = Order(
            salonID: PreviewData.salonLumiere.id,
            clientID: PreviewData.client.id,
            lines: [line],
            status: .awaitingPayment,
            discount: NetworkingFixtures.money("10.05"),
            vatPercent: 21,
            currency: .eur,
            createdAt: NetworkingFixtures.reference
        )

        let decoded = try WireFixtures.roundTrip(order)

        #expect(decoded.lines.first?.unitPrice == NetworkingFixtures.money("185.55"))
        #expect(decoded.discount == NetworkingFixtures.money("10.05"))
        #expect(decoded.total == NetworkingFixtures.money("175.50"))
        #expect(decoded.currency == .eur)
    }

    @Test("Enum raw values keep their own spelling — the key strategy never touches them")
    func enumRawValuesAreUntouched() throws {
        let object = try WireFixtures.wireObject(for: NetworkingFixtures.groupAppointment)

        #expect(object["status"] as? String == "confirmed")
        let recurrence = try #require(object["recurrence"] as? [String: Any])
        #expect(recurrence["frequency"] as? String == "every_4_weeks")

        let salonObject = try WireFixtures.wireObject(for: NetworkingFixtures.salon)
        let categories = try #require(salonObject["categories"] as? [String])
        #expect(categories.contains("hair_salon"))
        #expect(categories.contains("makeup_studio"))
    }

    // MARK: - Helpers

    /// Top-level keys of an encoded JSON object.
    private func keys(of data: Data) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: data)
        return Set((object as? [String: Any] ?? [:]).keys)
    }
}
