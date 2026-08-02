import Foundation
import PRVFoundation

public enum APIError: Error, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case conflict(String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case network(underlying: String)
    case decoding(String)
    case offline
}

public struct APIRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public var method: Method
    public var path: String
    public var query: [String: String]
    public var body: Data?

    public init(method: Method = .get, path: String, query: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }
}

/// Transport abstraction over the Supabase REST/Edge Function API.
/// Implementations must be safe to call from any task.
public protocol APIClient: Sendable {
    func send(_ request: APIRequest) async throws -> Data
}

extension APIClient {
    public func get<Response: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await send(APIRequest(method: .get, path: path, query: query))
        return try JSONCoding.decoder.decode(Response.self, from: data)
    }

    public func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let payload = try JSONCoding.encoder.encode(body)
        let data = try await send(APIRequest(method: .post, path: path, body: payload))
        return try JSONCoding.decoder.decode(Response.self, from: data)
    }
}

/// Shared JSON coding configuration: ISO-8601 dates and snake_case keys, matching the
/// Supabase/PostgREST wire format.
///
/// Keys go through ``PRVKeyCase`` rather than Foundation's
/// `.convertFromSnakeCase` / `.convertToSnakeCase`, because that pair is not an inverse
/// and mangles every acronym the domain models use: `salon_id` would decode as
/// `salonId` (never `salonID`) and `galleryURLs` would encode as `gallery_ur_ls`
/// (never `gallery_urls`).
public enum JSONCoding {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .custom { codingPath -> any CodingKey in
            guard let last = codingPath.last else { return PRVAnyCodingKey(stringValue: "") }
            return PRVAnyCodingKey(stringValue: PRVKeyCase.toCamelCase(last.stringValue))
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .custom { codingPath -> any CodingKey in
            guard let last = codingPath.last else { return PRVAnyCodingKey(stringValue: "") }
            return PRVAnyCodingKey(stringValue: PRVKeyCase.toSnakeCase(last.stringValue))
        }
        return encoder
    }()
}

/// URLSession-backed client that authenticates against Supabase and retries
/// transient failures with exponential backoff.
public struct URLSessionAPIClient: APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: @Sendable () async -> String?

    public init(
        baseURL: URL = AppEnvironment.current.supabaseURL,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func send(_ request: APIRequest) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: false
        )
        if !request.query.isEmpty {
            components?.queryItems = request.query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw APIError.network(underlying: "Malformed URL for path \(request.path)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider() {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var lastError: APIError = .network(underlying: "No attempts made")
        for attempt in 0 ..< 3 {
            if attempt > 0 {
                let backoff = UInt64(pow(2.0, Double(attempt)) * 500_000_000)
                try await Task.sleep(nanoseconds: backoff)
            }
            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError.network(underlying: "Non-HTTP response")
                }
                switch http.statusCode {
                case 200 ..< 300:
                    return data
                case 401: throw APIError.unauthorized
                case 403: throw APIError.forbidden
                case 404: throw APIError.notFound
                case 409:
                    throw APIError.conflict(String(data: data, encoding: .utf8) ?? "Conflict")
                case 429:
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    lastError = .rateLimited(retryAfter: retryAfter)
                    continue
                case 500 ..< 600:
                    lastError = .server(status: http.statusCode, message: String(data: data, encoding: .utf8))
                    continue
                default:
                    throw APIError.server(status: http.statusCode, message: nil)
                }
            } catch let error as APIError {
                switch error {
                case .rateLimited, .server:
                    lastError = error
                    continue
                default:
                    throw error
                }
            } catch {
                lastError = .network(underlying: String(describing: error))
                continue
            }
        }
        PRVLog.network.error("Request failed after retries: \(request.path, privacy: .public)")
        throw lastError
    }
}
