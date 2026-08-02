import Foundation

/// A strongly-typed identifier. `PRVID<Salon>` can never be confused with
/// `PRVID<Appointment>` at compile time.
public struct PRVID<Entity>: Hashable, Sendable {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Creates an identifier from a UUID string. Crashes on malformed input —
    /// intended for compile-time-known values (previews, fixtures).
    public init(_ string: StaticString) {
        guard let uuid = UUID(uuidString: "\(string)") else {
            fatalError("Invalid UUID literal: \(string)")
        }
        self.rawValue = uuid
    }
}

extension PRVID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PRVID: CustomStringConvertible {
    public var description: String { rawValue.uuidString }
}
