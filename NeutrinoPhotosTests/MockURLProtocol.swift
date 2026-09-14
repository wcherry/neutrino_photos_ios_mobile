import Foundation

/// A `URLProtocol` stub that lets tests intercept `URLSession` traffic without touching the
/// network, so services that make real HTTP calls can be exercised end to end — including
/// request-body capture — in unit tests.
///
/// Usage:
/// ```swift
/// let session = MockURLProtocol.makeSession()
/// MockURLProtocol.respond(json: #"{"photos":[],"total":0}"#)
/// let sut = PhotoLibraryService(api: APIClient(session: session))
/// ```
final class MockURLProtocol: URLProtocol {

    /// Set per test. Receives the outgoing request and returns the response to hand back.
    /// Throwing simulates a network error.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Every request that reached the protocol, in order, so tests can assert on method, path,
    /// and headers.
    private(set) static var requests: [URLRequest] = []

    /// Request bodies, in the order the requests arrived. Multipart bodies arrive via
    /// `httpBodyStream` when `URLSession.upload` is used, so both sources are drained.
    private(set) static var bodies: [Data] = []

    private static let lock = NSLock()

    // MARK: - Setup

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        requests = []
        bodies = []
    }

    // MARK: - Convenience responders

    /// Responds to any request with `json`, status 200.
    static func respond(json: String, statusCode: Int = 200) {
        handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: statusCode,
                             httpVersion: nil, headerFields: nil)!,
             Data(json.utf8))
        }
    }

    /// Fails every request at the transport layer, the way a real `URLSession` reports a phone in
    /// a tunnel or a server that never answered — no response, no status code.
    ///
    /// The distinction the app now draws is between these codes, so a test asserting on the
    /// message has to be able to pick one.
    static func fail(with code: URLError.Code,
                     url: URL = URL(string: "https://photos.test/api/v1/photos")!) {
        handler = { _ in
            throw URLError(code, userInfo: [NSURLErrorFailingURLErrorKey: url])
        }
    }

    /// Responds with raw bytes — for the content endpoints, whose bodies are ciphertext.
    static func respond(data: Data, statusCode: Int = 200) {
        handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: statusCode,
                             httpVersion: nil, headerFields: nil)!,
             data)
        }
    }

    /// Answers successive requests with successive entries, so a test can make the *third* call
    /// fail while the others succeed — which is how a bulk action's partial failure is exercised.
    ///
    /// Requests past the end of the list get the last entry, so a caller that makes one more call
    /// than the test anticipated does not hang or 404 on an unrelated leg.
    static func respondInSequence(_ responses: [(json: String, statusCode: Int)]) {
        precondition(!responses.isEmpty, "respondInSequence needs at least one response")
        let counter = SequenceCounter()
        handler = { request in
            let index = min(counter.next(), responses.count - 1)
            let response = responses[index]
            return (HTTPURLResponse(url: request.url!, statusCode: response.statusCode,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(response.json.utf8))
        }
    }

    /// A counter the handler closure can advance. A class because the handler is escaping and a
    /// captured `var` would be copied rather than shared.
    private final class SequenceCounter {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    /// Routes by path fragment, so a test covering a multi-request flow can answer each leg.
    /// The first match wins; an unmatched request gets a 404 so the omission shows up as a test
    /// failure rather than a hang.
    static func route(_ routes: [(fragment: String, statusCode: Int, body: Data)]) {
        handler = { request in
            let path = request.url?.path ?? ""
            let query = request.url?.query.map { "?\($0)" } ?? ""
            let full = path + query
            for route in routes where full.contains(route.fragment) {
                return (HTTPURLResponse(url: request.url!, statusCode: route.statusCode,
                                        httpVersion: nil, headerFields: nil)!,
                        route.body)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404,
                                    httpVersion: nil, headerFields: nil)!,
                    Data())
        }
    }

    // MARK: - Inspection

    static func request(matching predicate: (URLRequest) -> Bool) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first(where: predicate)
    }

    /// The body of the first request whose path contains `fragment`.
    static func body(forPathContaining fragment: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = requests.firstIndex(where: { ($0.url?.path ?? "").contains(fragment) }),
              index < bodies.count else { return nil }
        return bodies[index]
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    /// The most recent request — what a single-call test asserts the path and method of.
    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            Self.bodies.append(Self.drain(stream))
        } else if let body = request.httpBody {
            Self.bodies.append(body)
        } else {
            Self.bodies.append(Data())
        }
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
