import Foundation
import PRVModels
import Testing

@Suite("Wire format round-trips")
struct CodableRoundTripTests {
    // MARK: Aggregates

    @Test("Salon survives an ISO-8601 + snake_case round-trip unchanged")
    func salonRoundTrips() throws {
        let original = ModelFixtures.salon
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        // The optional, ID-suffixed field that a naive snake_case pair silently drops.
        #expect(decoded.organizationID == ModelFixtures.organizationID)
        #expect(decoded.heroImageURL == original.heroImageURL)
        #expect(decoded.galleryURLs == original.galleryURLs)
        #expect(decoded.openingHours == original.openingHours)
        #expect(decoded.prepaymentPolicy == original.prepaymentPolicy)
    }

    @Test("Appointment survives a round-trip, nested items and all")
    func appointmentRoundTrips() throws {
        let original = ModelFixtures.appointment
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        #expect(decoded.items.first?.addOnIDs == original.items.first?.addOnIDs)
        #expect(decoded.recurrence == original.recurrence)
        #expect(decoded.start == original.start)
        #expect(decoded.totalPrice == Money(185))
    }

    @Test("Order survives a round-trip with exact decimal money")
    func orderRoundTrips() throws {
        let original = ModelFixtures.order
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        #expect(decoded.subtotal == original.subtotal)
        #expect(decoded.total == original.total)
        #expect(decoded.outstandingBalance == original.outstandingBalance)
        #expect(decoded.vatPercent == 21)
        #expect(decoded.lines[1].referenceID == ModelFixtures.productReference)
    }

    // MARK: Enum payloads

    @Test("A text message payload round-trips")
    func textContentRoundTrips() throws {
        let original = ModelFixtures.message(.text("See you Thursday at 14:00 ✨"))
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        guard case .text(let text) = decoded.content else {
            Issue.record("Expected a text payload, got \(decoded.content)")
            return
        }
        #expect(text == "See you Thursday at 14:00 ✨")
    }

    @Test("Photo and video payloads round-trip with their optional captions")
    func mediaContentRoundTrips() throws {
        let photoURL = ModelFixtures.url("https://cdn.prv.beauty/chat/photo.jpg")
        let photo = try PRVWireJSON.roundTrip(ModelFixtures.message(.photo(photoURL, caption: "Inspo")))
        #expect(photo.content == .photo(photoURL, caption: "Inspo"))

        let videoURL = ModelFixtures.url("https://cdn.prv.beauty/chat/clip.mp4")
        let video = try PRVWireJSON.roundTrip(ModelFixtures.message(.video(videoURL, caption: nil)))
        #expect(video.content == .video(videoURL, caption: nil))
    }

    @Test("A voice payload round-trips with its duration")
    func voiceContentRoundTrips() throws {
        let voiceURL = ModelFixtures.url("https://cdn.prv.beauty/chat/note.m4a")
        let decoded = try PRVWireJSON.roundTrip(ModelFixtures.message(.voice(voiceURL, durationSeconds: 12)))

        #expect(decoded.content == .voice(voiceURL, durationSeconds: 12))
    }

    @Test("A structured appointment request round-trips, labels and dates intact")
    func appointmentRequestContentRoundTrips() throws {
        let original = ModelFixtures.message(
            .appointmentRequest(serviceID: ModelFixtures.serviceID, preferredDate: ModelFixtures.reference)
        )
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        guard case .appointmentRequest(let serviceID, let preferredDate) = decoded.content else {
            Issue.record("Expected an appointment request payload, got \(decoded.content)")
            return
        }
        #expect(serviceID == ModelFixtures.serviceID)
        #expect(preferredDate == ModelFixtures.reference)
    }

    @Test("An assistant recommendation payload round-trips with every nested ID array")
    func recommendationContentRoundTrips() throws {
        let original = ModelFixtures.message(.recommendation(ModelFixtures.recommendation))
        let decoded = try PRVWireJSON.roundTrip(original)

        #expect(decoded == original)
        guard case .recommendation(let recommendation) = decoded.content else {
            Issue.record("Expected a recommendation payload, got \(decoded.content)")
            return
        }
        #expect(recommendation.serviceIDs == [ModelFixtures.serviceID])
        #expect(recommendation.salonIDs == [ModelFixtures.salonID])
        #expect(recommendation.suggestedSlots.first?.optimizationScore == 0.75)
    }

    // MARK: Wire shape

    @Test("Keys really are snake_case on the wire")
    func wireKeysAreSnakeCase() throws {
        let orderKeys = try PRVWireJSON.wireKeys(for: ModelFixtures.order)

        #expect(orderKeys.contains("salon_id"))
        #expect(orderKeys.contains("client_id"))
        #expect(orderKeys.contains("appointment_id"))
        #expect(orderKeys.contains("discount_reason"))
        #expect(orderKeys.contains("vat_percent"))
        #expect(orderKeys.contains("amount_paid"))
        #expect(orderKeys.contains("points_earned"))
        #expect(orderKeys.contains("created_at"))
        #expect(orderKeys.contains("paid_at"))
        #expect(!orderKeys.contains("salonID"))

        let salonKeys = try PRVWireJSON.wireKeys(for: ModelFixtures.salon)
        #expect(salonKeys.contains("hero_image_url"))
        #expect(salonKeys.contains("gallery_urls"))
        #expect(salonKeys.contains("tik_tok_handle"))
        #expect(salonKeys.contains("organization_id"))
        #expect(salonKeys.contains("prepayment_policy"))
    }

    @Test("Timestamps are ISO-8601 strings, not epoch numbers")
    func timestampsAreISO8601() throws {
        let object = try PRVWireJSON.wireObject(for: ModelFixtures.order)
        let createdAt = try #require(object["created_at"] as? String)

        #expect(createdAt.hasSuffix("Z"))
        #expect(createdAt.contains("T"))

        let formatter = ISO8601DateFormatter()
        #expect(formatter.date(from: createdAt) == ModelFixtures.reference)
    }

    @Test("Enum raw values keep their own snake_case spelling on the wire")
    func enumRawValuesAreUntouched() throws {
        let object = try PRVWireJSON.wireObject(for: ModelFixtures.order)

        #expect(object["status"] as? String == "partially_paid")
        #expect(object["currency"] as? String == "EUR")

        let appointment = try PRVWireJSON.wireObject(for: ModelFixtures.appointment)
        #expect(appointment["status"] as? String == "confirmed")
    }

    // MARK: The key strategy itself

    @Test("The snake_case strategy is a true inverse for every model key shape")
    func keyStrategyIsLossless() {
        let keys = [
            "id", "salonID", "clientID", "appointmentID", "orderID", "organizationID",
            "additionalClientIDs", "addOnIDs", "serviceIDs", "packageIDs", "professionalIDs",
            "heroImageURL", "heroVideoURL", "virtualTourURL", "galleryURLs", "avatarURL", "pdfURL",
            "tikTokHandle", "instagramHandle", "preferredLanguage", "isFromAssistant",
            "vatPercent", "amountPaid", "pointsEarned", "discountReason", "unitPrice",
            "referenceID", "durationMinutes", "openMinutes", "closeMinutes", "postalCode",
            "lastFour", "expiryMonth", "isDefault", "optimizationScore", "maintenanceAdvice",
            "freeCancellationHours", "lateCancellationFeePercent", "noShowFeePercent",
            "fullPrepaymentDiscountPercent", "rewardPointsMultiplier", "grantsPriorityBooking",
            "createdAt", "updatedAt", "paidAt", "sentAt", "_0",
        ]

        for key in keys {
            #expect(
                PRVKeyCase.toCamelCase(PRVKeyCase.toSnakeCase(key)) == key,
                "\(key) → \(PRVKeyCase.toSnakeCase(key)) → \(PRVKeyCase.toCamelCase(PRVKeyCase.toSnakeCase(key)))"
            )
        }

        #expect(PRVKeyCase.toSnakeCase("salonID") == "salon_id")
        #expect(PRVKeyCase.toSnakeCase("galleryURLs") == "gallery_urls")
        #expect(PRVKeyCase.toSnakeCase("_0") == "_0")
        #expect(PRVKeyCase.toCamelCase("hero_image_url") == "heroImageURL")
    }
}
