import Foundation
import PRVModels
import Testing

@Suite("PRVID")
struct IdentifierTests {
    private static let uuidString = "00000000-0000-0000-0001-000000000001"

    @Test("Identifiers of different entities never mix, even from the same UUID")
    func typedIdentifiersAreDistinctTypes() throws {
        let uuid = try #require(UUID(uuidString: Self.uuidString))
        let salonID = Salon.ID(uuid)
        let orderID = Order.ID(uuid)

        // The compiler already forbids `salonID == orderID`; what the runtime
        // guarantees is that both faithfully carry the same underlying value.
        #expect(salonID.rawValue == orderID.rawValue)
        #expect(salonID == Salon.ID(uuid))
        #expect(salonID != Salon.ID())
    }

    @Test("The literal initializer accepts a well-formed UUID string")
    func literalInitializerParsesUUIDs() throws {
        let id = Salon.ID("00000000-0000-0000-0001-000000000001")
        let uuid = try #require(UUID(uuidString: Self.uuidString))

        #expect(id.rawValue == uuid)
        #expect(id.description == uuid.uuidString)
        #expect(id.description == "00000000-0000-0000-0001-000000000001")
    }

    @Test("Freshly minted identifiers are unique")
    func mintedIdentifiersAreUnique() {
        let ids = (0 ..< 512).map { _ in Appointment.ID() }

        #expect(Set(ids).count == 512)
    }

    @Test("Identifiers hash consistently, so they work as dictionary keys")
    func identifiersHashConsistently() throws {
        let uuid = try #require(UUID(uuidString: Self.uuidString))
        var index: [Salon.ID: String] = [:]
        index[Salon.ID(uuid)] = "Maison Lumière"

        #expect(index[Salon.ID(uuid)] == "Maison Lumière")
        #expect(index[Salon.ID()] == nil)
    }

    @Test("Identifiers encode as a bare UUID string, not a wrapper object")
    func identifiersEncodeAsBareUUIDStrings() throws {
        let id = Salon.ID("00000000-0000-0000-0001-000000000001")
        let data = try PRVWireJSON.encoder.encode([id])
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json == "[\"00000000-0000-0000-0001-000000000001\"]")

        let decoded = try PRVWireJSON.decoder.decode([Salon.ID].self, from: data)
        #expect(decoded == [id])
    }

    @Test("Identifiers survive a round-trip nested inside a model")
    func identifiersRoundTripInsideModels() throws {
        let decoded = try PRVWireJSON.roundTrip(ModelFixtures.appointment)

        #expect(decoded.id == ModelFixtures.appointmentID)
        #expect(decoded.salonID == ModelFixtures.salonID)
        #expect(decoded.clientID == ModelFixtures.clientID)
        #expect(decoded.orderID == ModelFixtures.orderID)
        #expect(decoded.additionalClientIDs.count == 1)
        #expect(decoded.items.first?.serviceID == ModelFixtures.serviceID)
        #expect(decoded.items.first?.professionalID == ModelFixtures.professionalID)
    }

    @Test("A missing optional identifier decodes as nil rather than throwing")
    func optionalIdentifiersTolerateAbsence() throws {
        var appointment = ModelFixtures.appointment
        appointment.orderID = nil
        appointment.items[0].professionalID = nil
        appointment.items[0].professionalName = nil

        let decoded = try PRVWireJSON.roundTrip(appointment)

        #expect(decoded.orderID == nil)
        #expect(decoded.items[0].professionalID == nil)
        #expect(decoded == appointment)
    }
}
