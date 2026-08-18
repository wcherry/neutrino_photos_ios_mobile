import XCTest
@testable import NeutrinoPhotos

// MARK: - AuthServiceTests

/// The whole three-step login, driven through `MockURLProtocol` — including the redirect step,
/// which is the part with no equivalent anywhere else in the app.
@MainActor
final class AuthServiceTests: XCTestCase {

    private var configuration: URLSessionConfiguration!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.use()
        configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        super.tearDown()
    }

    // MARK: - Happy path

    func testLoginStoresTokensAndRegistersTheDevice() async {
        stubFullLoginFlow()

        let sut = AuthService(configuration: configuration)
        await sut.login(email: "someone@example.com", password: "hunter2")

        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertNil(sut.loginError)
        XCTAssertEqual(KeychainService.load(forKey: AuthService.accessTokenKey), "access-token")
        XCTAssertEqual(KeychainService.load(forKey: AuthService.refreshTokenKey), "refresh-token")

        let loginRequest = MockURLProtocol.request { $0.url?.path.hasSuffix("/auth/login") == true }
        XCTAssertEqual(loginRequest?.value(forHTTPHeaderField: DeviceIdentity.deviceNameHeader),
                       DeviceIdentity.deviceName,
                       "login must name the device — that is what registers it server-side")
    }

    func testAuthorizeSendsPKCEChallenge() async {
        stubFullLoginFlow()

        let sut = AuthService(configuration: configuration)
        await sut.login(email: "someone@example.com", password: "hunter2")

        let authorize = MockURLProtocol.request { $0.url?.path.hasSuffix("/oauth/authorize") == true }
        let query = URLComponents(url: authorize!.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertNotNil(query?.first { $0.name == "code_challenge" }?.value)
        XCTAssertEqual(query?.first { $0.name == "client_id" }?.value, "neutrino-photos-ios")
    }

    // MARK: - Failures

    func testBadCredentialsSurfaceAsAnError() async {
        MockURLProtocol.respond(json: #"{"error":"nope"}"#, statusCode: 401)

        let sut = AuthService(configuration: configuration)
        await sut.login(email: "someone@example.com", password: "wrong")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.loginError, AuthError.invalidCredentials.errorDescription)
    }

    func testMismatchedStateIsRejected() async {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                return (Self.response(for: request, status: 200),
                        Data(#"{"accessToken":"session-token"}"#.utf8))
            }
            // A code returned with somebody else's state is not an answer to this client's
            // request, and must not be exchanged.
            let location = "neutrino://oauth/callback?code=the-code&state=not-the-state-we-sent"
            return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                    headerFields: ["Location": location])!,
                    Data())
        }

        let sut = AuthService(configuration: configuration)
        await sut.login(email: "someone@example.com", password: "hunter2")

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertEqual(sut.loginError, AuthError.stateMismatch.errorDescription)
    }

    // MARK: - Refresh

    func testRefreshIsSkippedWhileTheTokenIsFresh() async {
        TestTokens.install()
        let sut = AuthService(configuration: configuration)

        await sut.refreshTokenIfNeeded()

        XCTAssertEqual(MockURLProtocol.requestCount, 0,
                       "a token good for another hour must not cost a round trip")
    }

    func testExpiredTokenWithoutARefreshTokenSignsOut() async {
        KeychainService.save("stale", forKey: AuthService.accessTokenKey)
        KeychainService.save(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
                             forKey: AuthService.tokenExpiryKey)

        let sut = AuthService(configuration: configuration)
        await sut.refreshTokenIfNeeded()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNil(KeychainService.load(forKey: AuthService.accessTokenKey))
    }

    func testRefreshFailureKeepsTheSession() async {
        TestTokens.install()
        KeychainService.save(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
                             forKey: AuthService.tokenExpiryKey)
        KeychainService.save("refresh-token", forKey: AuthService.refreshTokenKey)
        // A 500 is an unreachable server, not a rejected session.
        MockURLProtocol.respond(json: #"{"error":"server"}"#, statusCode: 500)

        let sut = AuthService(configuration: configuration)
        await sut.refreshTokenIfNeeded()

        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertNotNil(KeychainService.load(forKey: AuthService.accessTokenKey))
    }

    func testLogoutKeepsTheEncryptionKey() {
        TestTokens.install()
        TestKeys.install()
        defer { TestKeys.remove() }

        let sut = AuthService(configuration: configuration)
        sut.logout()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertTrue(KeyImportService.hasStoredKeys(),
                      "signing back in should not mean importing the key again")
    }

    // MARK: - Helpers

    /// Answers all three legs: session login, the 302 carrying the code, and the token exchange.
    private func stubFullLoginFlow() {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/auth/login") {
                return (Self.response(for: request, status: 200),
                        Data(#"{"accessToken":"session-token"}"#.utf8))
            }
            if path.hasSuffix("/oauth/authorize") {
                let state = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "state" }?.value ?? ""
                let location = "neutrino://oauth/callback?code=the-code&state=\(state)"
                return (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                        headerFields: ["Location": location])!,
                        Data())
            }
            return (Self.response(for: request, status: 200), Data("""
            {"access_token":"access-token","refresh_token":"refresh-token",
             "expires_in":3600,"token_type":"Bearer"}
            """.utf8))
        }
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
