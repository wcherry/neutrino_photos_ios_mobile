import Foundation
import os.log

// MARK: - APIError

enum APIError: LocalizedError {
    case notAuthenticated
    case network(underlying: Error)
    case server(statusCode: Int)
    case decoding(underlying: Error)
    case notFound

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:       return "You are not signed in."
        case .network:                return "A network error occurred. Please check your connection."
        case .server(let code):       return "Server error (\(code))."
        case .decoding(let err):      return "Failed to read server response: \(err.localizedDescription)"
        case .notFound:               return "That item is no longer available."
        }
    }
}

// MARK: - APIClient

/// Every authorized request this app makes to Neutrino goes through here.
///
/// The three services above it — library, albums, media content — differ in what they ask for, not
/// in how they ask: refresh the token, attach it, check the status, decode. Written once because
/// the parts that are easy to get subtly wrong (a 404 that means "no key" rather than "failed", a
/// cancelled upload that must stay distinguishable from a failed one) should have exactly one
/// implementation to get right.
///
/// The token is read from the Keychain per request rather than held, so a refresh that happens
/// between two calls is picked up by the second without anything being notified.
///
/// `ObservableObject` only so the composition root can hold it in a `@StateObject` alongside the
/// services that use it — it publishes nothing, and a view has no reason to observe it. Held that
/// way because SwiftUI may re-create an `App` value, and a client rebuilt behind services still
/// pointing at the old one would be handed the `authService` reference they never see.
@MainActor
final class APIClient: ObservableObject {

    // MARK: - Dependencies

    /// Set once at app launch. Every request gives it the chance to refresh an expiring token
    /// first, which is why no service has to think about expiry.
    weak var authService: AuthService?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "APIClient")

    private let session: URLSession

    var baseURL: String { AuthService.baseURL }

    // MARK: - Init

    /// - Parameter session: injected in tests as a `MockURLProtocol`-backed session.
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - JSON

    func get<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T {
        try await decode(try await send(method: "GET", path: path), with: decoder)
    }

    /// A GET whose 404 and 403 are facts rather than failures — "this file has no key ref", "this
    /// item is not shared with you" — and which answers nil for them.
    func getIfPresent<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T? {
        let request = try makeRequest(method: "GET", path: path)
        let (data, http) = try await execute(request)
        if http.statusCode == 404 || http.statusCode == 403 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.server(statusCode: http.statusCode)
        }
        return try await decode(data, with: decoder)
    }

    @discardableResult
    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil,
                            decoder: JSONDecoder) async throws -> T {
        try await decode(try await send(method: "POST", path: path, json: body), with: decoder)
    }

    @discardableResult
    func patch<T: Decodable>(_ path: String, body: any Encodable, decoder: JSONDecoder) async throws -> T {
        try await decode(try await send(method: "PATCH", path: path, json: body), with: decoder)
    }

    /// A request whose response body is of no interest — the several endpoints that answer 204.
    func send(method: String, path: String, json: (any Encodable)? = nil) async throws -> Data {
        let request = try makeRequest(method: method, path: path, json: json)
        let (data, http) = try await execute(request)
        guard (200...299).contains(http.statusCode) else {
            throw APIError.server(statusCode: http.statusCode)
        }
        return data
    }

    // MARK: - Bytes

    /// Raw response bytes — how an encrypted original is fetched, since it is ciphertext rather
    /// than anything a `JSONDecoder` should be pointed at.
    func data(path: String) async throws -> Data {
        try await send(method: "GET", path: path)
    }

    /// Sends `body` and returns the response bytes.
    ///
    /// - Parameter onProgress: fraction of the bytes sent, 0 to 1, reported on the main actor.
    ///   Originals are stored at full resolution, so an import is several megabytes over whatever
    ///   connection the phone has — not something to spin blankly through.
    ///
    /// Cancelling the surrounding `Task` cancels the transfer: `URLSession`'s async methods
    /// propagate cancellation to the underlying task. That is reported as `CancellationError` and
    /// never as a network failure, so a caller can tell "the user stopped it" from "it broke".
    func upload(method: String, path: String, contentType: String, body: Data,
                onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> Data {
        var request = try makeRequest(method: method, path: path)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        try await authorize(&request)

        do {
            let (data, response): (Data, URLResponse)
            if let onProgress {
                let reporter = UploadProgressReporter(onProgress)
                (data, response) = try await session.upload(for: request, from: body, delegate: reporter)
            } else {
                (data, response) = try await session.upload(for: request, from: body)
            }
            guard let http = response as? HTTPURLResponse else { throw APIError.server(statusCode: 0) }
            logger.debug("<-- \(http.statusCode) \(request.url?.path ?? "?", privacy: .public)")
            guard (200...299).contains(http.statusCode) else {
                throw APIError.server(statusCode: http.statusCode)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // `URLSession` reports a cancelled task this way rather than as `CancellationError`.
            throw CancellationError()
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(underlying: error)
        }
    }

    // MARK: - Private

    private func decode<T: Decodable>(_ data: Data, with decoder: JSONDecoder) async throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    private func makeRequest(method: String, path: String, json: (any Encodable)? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else { throw APIError.server(statusCode: 0) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(json)
            } catch {
                throw APIError.decoding(underlying: error)
            }
        }
        return request
    }

    private func authorize(_ request: inout URLRequest) async throws {
        await authService?.refreshTokenIfNeeded()
        guard let token = KeychainService.load(forKey: AuthService.accessTokenKey) else {
            throw APIError.notAuthenticated
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        try await authorize(&request)
        logger.debug("--> \(request.httpMethod ?? "?", privacy: .public) \(request.url?.path ?? "?", privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.server(statusCode: 0) }
        logger.debug("<-- \(http.statusCode) \(request.url?.path ?? "?", privacy: .public)")
        return (data, http)
    }
}

// MARK: - UploadProgressReporter

/// Forwards `URLSession`'s byte counts to the main actor.
///
/// A per-task delegate rather than a session-wide one, so it lives exactly as long as the request
/// it reports on and two concurrent uploads cannot report each other's progress. `URLSession` calls
/// this on its own queue, which is why every report hops actors before it reaches the UI.
final class UploadProgressReporter: NSObject, URLSessionTaskDelegate {

    private let report: @MainActor (Double) -> Void

    init(_ report: @escaping @MainActor (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // A chunked body reports -1 for the expected total, which is not a fraction of anything.
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        let report = report
        Task { @MainActor in report(fraction) }
    }
}
