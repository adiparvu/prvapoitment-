import Foundation
import PRVFoundation
import PRVModels
import PRVNetworking
import PRVPersistence

/// Assembles the offline-first stack and joins it to the live backend.
///
/// `PRVPersistence` deliberately does not import `PRVNetworking`: the queue
/// knows how to store, order, and retry operations, and nothing about HTTP. The
/// two meet exactly here — this file supplies the sender that posts a queued
/// operation, maps the transport outcome onto the engine's vocabulary, and
/// hands back the server's canonical row when the server wins a conflict.
///
/// The demo backend composes no stack: its writes are already local and
/// immediate, so a queue would have nothing to carry.
@MainActor
struct OfflineStack {
    let cache: SwiftDataCacheStore
    let sync: PRVSyncEngine

    /// Builds the stack against a Supabase client, or returns `nil` when the
    /// on-disk store cannot be opened.
    ///
    /// A failure here is recoverable — the app runs online-only rather than
    /// refusing to launch, which is the right trade for a cache.
    init?(client: SupabaseClient) {
        guard let cache = try? SwiftDataCacheStore.make() else {
            PRVLog.persistence.error("Offline cache unavailable; running online-only")
            return nil
        }
        self.cache = cache

        // The payload came off the wire, so the applier must decode it with the
        // wire coder (snake_case, acronym-aware) rather than the cache's own
        // symmetric format.
        let applier = CacheServerVersionApplier(cache: cache, coder: WireCoder())
        self.sync = PRVSyncEngine(
            store: cache,
            applyServerVersion: applier.handler(),
            send: Self.sender(client: client)
        )
    }

    // MARK: - The network boundary

    /// Posts one queued operation and classifies the result.
    ///
    /// Mapping `APIError` onto `SyncSendResult` is the reason this lives in the
    /// app target:
    ///
    /// * `.conflict` — the server holds a competing version. For bookings and
    ///   payments the engine's server-authoritative policy then discards the
    ///   local operation instead of retrying, so an offline device can never
    ///   overwrite a confirmed slot or a settled charge.
    /// * `.unauthorized` / `.forbidden` / `.notFound` / `.decoding` — retrying
    ///   cannot help, so the operation is dropped rather than left blocking
    ///   everything queued behind it.
    /// * `.offline` — stops the drain until connectivity returns.
    /// * everything else — transient, so the engine backs off and retries.
    private static func sender(client: SupabaseClient) -> SyncSender {
        { attempt in
            do {
                let representation = try await replay(
                    attempt.operation,
                    overwritingServerVersion: attempt.overwritesServerVersion,
                    using: client
                )
                return .delivered(serverPayload: representation)
            } catch let error as APIError {
                switch error {
                case .conflict:
                    return .conflict(serverPayload: nil)
                case .unauthorized, .forbidden, .notFound:
                    return .rejected(reason: String(describing: error))
                case .decoding(let detail):
                    return .rejected(reason: detail)
                case .offline:
                    return .offline
                case .network(let underlying):
                    return .retryable(reason: underlying)
                case .rateLimited:
                    return .retryable(reason: "Rate limited")
                case .server(let status, let message):
                    return .retryable(reason: message ?? "Server error \(status)")
                }
            } catch {
                return .retryable(reason: String(describing: error))
            }
        }
    }
}

extension OfflineStack {
    /// Replays one queued mutation against PostgREST.
    ///
    /// `SyncOperation.payload` is the row exactly as it should reach the
    /// server — already snake_case, because it was encoded with the wire coder
    /// when it was queued. It is therefore decoded into an untyped `JSONValue`
    /// and forwarded verbatim rather than re-mapped through a domain type,
    /// which would risk mangling keys a second time.
    ///
    /// - Parameter overwritingServerVersion: Set after the engine has ruled the
    ///   local write newer on a last-write-wins entity. The row is then upserted
    ///   with `resolution=merge-duplicates` instead of repeating an update the
    ///   server already refused.
    /// - Returns: The server's canonical row, when it returned one.
    static func replay(
        _ operation: SyncOperation,
        overwritingServerVersion: Bool,
        using client: SupabaseClient
    ) async throws -> Data? {
        let identifier = PostgRESTFilter.equals("id", operation.entityID)

        switch operation.kind {
        case .delete:
            try await client.deleteRows(from: operation.entity, filters: [identifier])
            return nil

        case .create:
            let body = try JSONValue(data: operation.payload)
            let row: JSONValue = try await client.insert(into: operation.entity, values: body)
            return try row.encoded()

        case .update:
            let body = try JSONValue(data: operation.payload)
            let row: JSONValue
            if overwritingServerVersion {
                row = try await client.upsert(into: operation.entity, values: body)
            } else {
                row = try await client.update(operation.entity, values: body, filters: [identifier])
            }
            return try row.encoded()
        }
    }
}

/// An untyped JSON value, used to carry an already-encoded row to the server
/// and the server's reply back without either passing through a domain type.
enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Decodes a raw JSON document.
    init(data: Data) throws {
        // A plain decoder: the bytes are already in wire shape, so applying the
        // snake_case key strategy again would corrupt them.
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Re-encodes to raw JSON, likewise without any key transformation.
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Adapts `PRVNetworking`'s wire coding to the persistence module's coder
/// protocol, so a server payload decodes with the same key and date handling
/// that produced it.
private struct WireCoder: PersistenceCoding {
    func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONCoding.encoder.encode(value)
    }

    func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONCoding.decoder.decode(type, from: data)
    }
}
