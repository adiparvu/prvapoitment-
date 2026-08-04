import Foundation
import PRVModels
import PRVNetworking
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `URLSessionAPIClient` driven entirely through a `URLProtocol` stub: no
/// socket, no server, no flake — every status code, retry, and header the
/// live repositories depend on is asserted here.
///
/// The retry tests are deliberately real-time: the client's backoff is
/// `2^attempt × 500 ms`, so an exhausted retry costs ~3 s. Swift Testing runs
/// these in parallel, and the alternative — injecting a clock — would change
/// the shipping type's signature for the benefit of its own test.
@Suite("URLSessionAPIClient transport")
struct URLSessionAPIClientTests {
    // MARK: - Success

    @Test("A 2xx response returns its body bytes untouched")
    func successReturnsBody() async throws {
        let api = StubbedAPI.make(script: [.json(#"{"ok":true}"#)])
        defer { api.forget() }

        let data = try await api.send()

        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
        #expect(api.attemptCount == 1)
    }

    @Test("A 204 with an empty body still succeeds")
    func emptySuccessBodyIsFine() async throws {
        let api = StubbedAPI.make(script: [.status(204)])
        defer { api.forget() }

        let data = try await api.send(method: .delete)

        #expect(data.isEmpty)
        #expect(api.recordedRequests.first?.method == "DELETE")
    }

    @Test("A decoded GET converts snake_case columns to acronym-correct properties")
    func decodedGetUsesTheWireCoder() async throws {
        let api = StubbedAPI.make(script: [.json(WireFixtures.salonRow)])
        defer { api.forget() }

        let salon: Salon = try await api.get()

        #expect(salon.name == "Maison Lumière")
        #expect(salon.galleryURLs.count == 2)
        #expect(salon.heroImageURL != nil)
    }

    @Test("A POST puts its encoded body on the wire")
    func postSendsItsBody() async throws {
        let api = StubbedAPI.make(script: [.json(#"{"accepted":true}"#)])
        defer { api.forget() }

        let payload = try JSONCoding.encoder.encode(NetworkingFixtures.groupAppointment)
        _ = try await api.send(method: .post, body: payload)

        let request = try #require(api.recordedRequests.first)
        #expect(request.method == "POST")
        let sent = try #require(request.body)
        let object = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        #expect(object?["salon_id"] != nil)
        #expect(object?["additional_client_ids"] != nil)
        #expect(object?["salonID"] == nil)
    }

    // MARK: - Headers and query

    @Test("A bearer token is attached when the provider supplies one")
    func bearerTokenIsAttached() async throws {
        let api = StubbedAPI.make(script: [.status(200)], token: "session-token")
        defer { api.forget() }

        _ = try await api.send()

        let request = try #require(api.recordedRequests.first)
        #expect(request.header("Authorization") == "Bearer session-token")
        #expect(request.header("Content-Type") == "application/json")
    }

    @Test("No Authorization header is sent for an anonymous client")
    func anonymousRequestsCarryNoToken() async throws {
        let api = StubbedAPI.make(script: [.status(200)])
        defer { api.forget() }

        _ = try await api.send()

        #expect(api.recordedRequests.first?.header("Authorization") == nil)
    }

    @Test("Query items reach the URL")
    func queryItemsAreSent() async throws {
        let api = StubbedAPI.make(script: [.status(200)])
        defer { api.forget() }

        _ = try await api.send(query: ["select": "*", "salon_id": "eq.abc"])

        let query = try #require(api.recordedRequests.first?.query)
        #expect(query["select"] == "*")
        #expect(query["salon_id"] == "eq.abc")
    }

    // MARK: - Terminal failures

    @Test("401 is unauthorized and is never retried")
    func unauthorizedIsTerminal() async {
        let api = StubbedAPI.make(script: [.status(401)])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        #expect(error?.kind == .unauthorized)
        #expect(api.attemptCount == 1)
    }

    @Test("403 is forbidden")
    func forbiddenIsTerminal() async {
        let api = StubbedAPI.make(script: [.status(403)])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        #expect(error?.kind == .forbidden)
        #expect(api.attemptCount == 1)
    }

    @Test("404 is notFound — the shape every repository turns into an empty state")
    func notFoundIsTerminal() async {
        let api = StubbedAPI.make(script: [.status(404)])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        #expect(error?.kind == .notFound)
        #expect(api.attemptCount == 1)
    }

    @Test("409 carries the server's body, because the body is the reason")
    func conflictCarriesItsBody() async {
        let message = #"{"message":"That slot was just taken."}"#
        let api = StubbedAPI.make(script: [.status(409, text: message)])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send(method: .post, body: Data("{}".utf8))
        }

        #expect(error?.kind == .conflict(message))
        #expect(api.attemptCount == 1)
    }

    @Test("An unmapped status is reported as a server error")
    func unmappedStatusIsAServerError() async {
        let api = StubbedAPI.make(script: [.status(418)])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        // The client maps anything outside its known statuses to `.server`,
        // and `.server` is on the retryable list — so an unmapped status is
        // retried to exhaustion before it surfaces. Documented here because it
        // is the one place the status→error map and the retry map disagree
        // about what "unknown" means.
        #expect(error?.kind == .server(status: 418, message: nil))
        #expect(api.attemptCount == 3)
    }

    @Test("A non-HTTP response is a network error, not a crash")
    func nonHTTPResponseIsANetworkError() async {
        let api = StubbedAPI.make(script: [.nonHTTP])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        #expect(error?.kind == .network)
        #expect(api.attemptCount == 1)
    }

    // MARK: - Retries

    @Test("A 429 is retried and the next attempt's success is returned")
    func rateLimitRetriesThenSucceeds() async throws {
        let api = StubbedAPI.make(script: [
            .rateLimited(retryAfterSeconds: 1),
            .json(#"{"ok":true}"#),
        ])
        defer { api.forget() }

        let data = try await api.send()

        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
        #expect(api.attemptCount == 2)
    }

    @Test("A 500 is retried and the next attempt's success is returned")
    func serverErrorRetriesThenSucceeds() async throws {
        let api = StubbedAPI.make(script: [
            .status(500, text: "boom"),
            .json(#"{"ok":true}"#),
        ])
        defer { api.forget() }

        let data = try await api.send()

        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
        #expect(api.attemptCount == 2)
    }

    @Test("A dropped connection is retried and the next attempt's success is returned")
    func transportFailureRetriesThenSucceeds() async throws {
        let api = StubbedAPI.make(script: [
            .transportFailure(.networkConnectionLost),
            .json(#"{"ok":true}"#),
        ])
        defer { api.forget() }

        let data = try await api.send()

        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)
        #expect(api.attemptCount == 2)
    }

    @Test("Three server errors exhaust the retries and surface the last one")
    func serverErrorExhaustsRetries() async {
        let api = StubbedAPI.make(script: [.status(503, text: "unavailable")])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        #expect(error?.serverStatus == 503)
        #expect(error?.kind == .server(status: 503, message: "unavailable"))
        // Three attempts total: the first plus two backed-off retries.
        #expect(api.attemptCount == 3)
    }

    @Test("Sustained rate limiting surfaces as rateLimited, carrying Retry-After")
    func rateLimitExhaustsRetries() async {
        let api = StubbedAPI.make(script: [.rateLimited(retryAfterSeconds: 30)])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        #expect(error?.kind == .rateLimited(30))
        #expect(api.attemptCount == 3)
    }

    @Test("A connection that never comes back surfaces as a network error")
    func transportFailureExhaustsRetries() async {
        let api = StubbedAPI.make(script: [.transportFailure(.notConnectedToInternet)])
        defer { api.forget() }

        let error = await apiError {
            _ = try await api.send()
        }

        #expect(error?.kind == .network)
        #expect(api.attemptCount == 3)
    }

    @Test("Retries back off rather than hammering the server")
    func retriesBackOff() async {
        let api = StubbedAPI.make(script: [.status(503), .status(503), .json("{}")])
        defer { api.forget() }

        let started = Date.now
        _ = try? await api.send()
        let elapsed = Date.now.timeIntervalSince(started)

        // 2^1 × 500 ms + 2^2 × 500 ms = 3 s of scheduled delay; the assertion
        // stays under it so a loaded machine cannot make this flaky.
        #expect(elapsed > 2.0)
        #expect(api.attemptCount == 3)
    }

    // MARK: - Decoding

    @Test("A malformed body fails at the decode step, not silently")
    func malformedJSONFailsToDecode() async {
        let api = StubbedAPI.make(script: [.json("{ this is not json")])
        defer { api.forget() }

        // `URLSessionAPIClient.send` is byte-level and succeeds here; the
        // failure surfaces from `JSONCoding.decoder` inside `APIClient.get`.
        // `SupabaseClient.decode(_:as:)` is the layer that maps this to
        // `APIError.decoding` before it reaches a repository's caller.
        await #expect(throws: DecodingError.self) {
            let _: Salon = try await api.get()
        }
    }

    @Test("A well-formed body of the wrong shape is a decoding failure too")
    func wrongShapeFailsToDecode() async {
        let api = StubbedAPI.make(script: [.json(#"{"id":"not-a-uuid"}"#)])
        defer { api.forget() }

        await #expect(throws: DecodingError.self) {
            let _: Salon = try await api.get()
        }
    }
}
