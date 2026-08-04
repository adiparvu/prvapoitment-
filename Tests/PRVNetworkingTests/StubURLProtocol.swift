import Foundation
import PRVNetworking
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A network-free transport for `URLSessionAPIClient`.
//
// `URLProtocol` is the only seam URLSession offers that does not require a
// socket: a session configured with `protocolClasses = [StubURLProtocol.self]`
// hands every request to this class instead of the network stack. Each test
// installs a *script* — an ordered list of outcomes — against a private path,
// so retry behaviour ("503, 503, then 200") is expressible and the suite can
// still run in parallel without tests colliding.

/// One scripted HTTP outcome.
enum StubOutcome: Sendable {
    /// A real HTTP response with a status code, body, and headers.
    case http(status: Int, body: Data, headers: [String: String])
    /// A response that is not an `HTTPURLResponse` — the case
    /// `URLSessionAPIClient` rejects as `APIError.network`.
    case nonHTTP
    /// A transport-level failure, e.g. a dropped connection.
    case transportFailure(URLError.Code)

    /// A response carrying only a status code.
    static func status(_ status: Int) -> StubOutcome {
        .http(status: status, body: Data(), headers: [:])
    }

    /// A response carrying a status code and a plain-text body.
    static func status(_ status: Int, text: String) -> StubOutcome {
        .http(status: status, body: Data(text.utf8), headers: [:])
    }

    /// A JSON response. Defaults to `200 OK`.
    static func json(_ text: String, status: Int = 200) -> StubOutcome {
        .http(
            status: status,
            body: Data(text.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }

    /// A rate-limit response carrying a `Retry-After` header.
    static func rateLimited(retryAfterSeconds: Int) -> StubOutcome {
        .http(
            status: 429,
            body: Data(),
            headers: ["Retry-After": String(retryAfterSeconds)]
        )
    }
}

/// A request as the stub observed it, captured so tests can assert on the
/// method, headers, query, and body the client actually put on the wire.
struct StubbedRequest: Sendable {
    /// Full request URL, including query items.
    var url: URL?
    /// HTTP method, e.g. `"POST"`.
    var method: String?
    /// All request headers, keyed exactly as URLSession sent them.
    var headers: [String: String]
    /// Request body, read from either `httpBody` or `httpBodyStream`.
    var body: Data?

    /// Captures a request handed to the stub.
    init(_ request: URLRequest) {
        url = request.url
        method = request.httpMethod
        headers = request.allHTTPHeaderFields ?? [:]
        body = StubbedRequest.body(of: request)
    }

    /// The value of a header, case-insensitively.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Query items as a dictionary, or empty when the URL carries none.
    var query: [String: String] {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return [:] }
        return items.reduce(into: [:]) { result, item in
            result[item.name] = item.value ?? ""
        }
    }

    /// Reads a request body from wherever URLSession left it.
    ///
    /// URLSession moves `httpBody` into `httpBodyStream` before a `URLProtocol`
    /// sees the request, so reading only `httpBody` would report every POST as
    /// bodyless — the classic way a stub silently stops asserting anything.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        let capacity = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The scripts and recordings shared between the tests and the `URLProtocol`.
///
/// `URLProtocol` instances are created by URLSession on its own threads and
/// its entry points are synchronous, so an actor cannot be used here. A lock
/// around the two dictionaries is the whole synchronization story, which is
/// why the `@unchecked Sendable` is safe: no stored state escapes the lock.
final class StubRegistry: @unchecked Sendable {
    /// The process-wide registry the `URLProtocol` reads from.
    static let shared = StubRegistry()

    private let lock = NSLock()
    private var scripts: [String: [StubOutcome]] = [:]
    private var recordings: [String: [StubbedRequest]] = [:]

    private init() {}

    /// Installs the outcomes a path will answer with, in order.
    func install(_ script: [StubOutcome], at path: String) {
        lock.lock()
        defer { lock.unlock() }
        scripts[path] = script
        recordings[path] = []
    }

    /// Pops the next outcome for a path.
    ///
    /// The final scripted outcome repeats, so a test that scripts a single
    /// `503` still describes "every attempt fails" rather than depending on
    /// how many attempts the client makes.
    func nextOutcome(for path: String) -> StubOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard var remaining = scripts[path], !remaining.isEmpty else {
            return .transportFailure(.unsupportedURL)
        }
        let outcome = remaining.removeFirst()
        if !remaining.isEmpty {
            scripts[path] = remaining
        }
        return outcome
    }

    /// Records a request the stub served.
    func record(_ request: StubbedRequest, at path: String) {
        lock.lock()
        defer { lock.unlock() }
        recordings[path, default: []].append(request)
    }

    /// Every request served for a path, oldest first.
    func requests(at path: String) -> [StubbedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordings[path] ?? []
    }

    /// Forgets a path's script and recordings.
    func forget(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        scripts.removeValue(forKey: path)
        recordings.removeValue(forKey: path)
    }
}

/// The `URLProtocol` that answers from ``StubRegistry`` instead of the network.
final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let key = url.path
        StubRegistry.shared.record(StubbedRequest(request), at: key)

        switch StubRegistry.shared.nextOutcome(for: key) {
        case .http(let status, let body, let headers):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)

        case .nonHTTP:
            let response = URLResponse(
                url: url,
                mimeType: "application/json",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)

        case .transportFailure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

/// A `URLSessionAPIClient` wired to a scripted, network-free transport.
struct StubbedAPI: Sendable {
    /// The path to hand to ``APIRequest``. Unique per instance, so tests that
    /// run in parallel never share a script.
    let requestPath: String
    /// The client under test.
    let client: URLSessionAPIClient

    /// Base URL every stubbed client is built from.
    ///
    /// The host resolves nowhere: if a test ever escapes the stub, it fails
    /// fast instead of reaching a real server.
    static var baseURL: URL {
        guard let url = URL(string: "https://stub.prv.invalid") else {
            preconditionFailure("The stub base URL is a literal and always parses.")
        }
        return url
    }

    /// Builds a client whose transport answers with `script`, in order.
    /// - Parameters:
    ///   - script: Outcomes to serve. The last one repeats.
    ///   - token: Bearer token the client should attach, or `nil` for none.
    static func make(script: [StubOutcome], token: String? = nil) -> StubbedAPI {
        let requestPath = "rest/v1/stub-\(UUID().uuidString)"
        StubRegistry.shared.install(script, at: "/" + requestPath)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let client = URLSessionAPIClient(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            tokenProvider: { token }
        )
        return StubbedAPI(requestPath: requestPath, client: client)
    }

    /// Every request the client actually sent, oldest first.
    var recordedRequests: [StubbedRequest] {
        StubRegistry.shared.requests(at: "/" + requestPath)
    }

    /// How many times the client hit the transport — the retry count.
    var attemptCount: Int { recordedRequests.count }

    /// Sends a request against this stub's path.
    func send(
        method: APIRequest.Method = .get,
        query: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Data {
        try await client.send(
            APIRequest(method: method, path: requestPath, query: query, body: body)
        )
    }

    /// Sends a GET and decodes it with the shared wire coder.
    func get<Response: Decodable>(as type: Response.Type = Response.self) async throws -> Response {
        try await client.get(requestPath, as: Response.self)
    }

    /// Releases the script and recordings.
    func forget() {
        StubRegistry.shared.forget("/" + requestPath)
    }
}
