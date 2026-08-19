import Foundation
import CryptoKit
import os.log

// MARK: - AuthError

enum AuthError: LocalizedError, Equatable {
    case invalidCredentials
    case stateMismatch
    case missingCode
    case tokenExchangeFailed(String)
    case networkError(String)
    case serverError(statusCode: Int)
    case configuration

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:           return "Invalid email or password."
        case .stateMismatch:                return "Authorization failed — security check failed."
        case .missingCode:                  return "Authorization failed — no code returned."
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .networkError:                 return "A network error occurred. Please check your connection."
        case .serverError(let code):        return "Server error (\(code)). Please try again later."
        case .configuration:                return "Authentication is misconfigured."
        }
    }
}

// MARK: - UserProfile

/// The signed-in account, as `GET /api/v1/auth/me` reports it.
///
/// The server serializes this one camelCase already, so it needs no key strategy — only
/// `DriveDate`'s date handling, because `created_at` is a zone-less `NaiveDateTime`.
struct UserProfile: Decodable, Equatable {
    let id: String
    let email: String
    let name: String
    let createdAt: Date
    let role: String
    let totpEnabled: Bool
}

// MARK: - AuthService

/// Three-step OAuth PKCE flow (no browser required), shared with Neutrino Drive, Docs, and Notes:
///
///   1. `POST /api/v1/auth/login`      → short-lived session token
///   2. `GET  /api/v1/oauth/authorize` → 302 `Location: <redirect_uri>?code=…&state=…`
///      (Bearer session token, redirect suppressed, code read from the Location header)
///   3. `POST /api/v1/oauth/token`     → long-lived access + refresh tokens
///
/// Step 1 also carries the `X-Device-Name` header, which is how a device registers itself with the
/// Neutrino auth service — see `DeviceIdentity`.
@MainActor
final class AuthService: ObservableObject {

    // MARK: - Published State

    @Published var isAuthenticated: Bool = false
    @Published var loginError: String?
    @Published var isLoggingIn: Bool = false

    /// The signed-in account, once `loadProfile()` has answered. Nil while it is in flight, and on
    /// a launch that never reached the server — the app is usable without it, so nothing waits.
    @Published private(set) var profile: UserProfile?

    // MARK: - Keychain Keys

    /// `nphoto.` prefixed so Photos' tokens sit alongside — rather than on top of — Drive's `nd.*`,
    /// Notes' `nn.*`, and Docs' `ndoc.*` entries on a device that has several installed.
    nonisolated static let accessTokenKey  = "nphoto.access_token"
    nonisolated static let refreshTokenKey = "nphoto.refresh_token"
    nonisolated static let tokenExpiryKey  = "nphoto.token_expiry"

    // MARK: - OAuth Configuration

    nonisolated static let serverHostKey = "nphoto.server_host"
    nonisolated static let defaultHost   = "https://www.getneutrino.app"

    /// The server this app talks to. Settings writes it; every service reads it — including from
    /// off the main actor, hence `nonisolated`.
    nonisolated static var baseURL: String {
        UserDefaults.standard.string(forKey: serverHostKey) ?? defaultHost
    }

    private enum AuthConfig {
        static var baseURL: String { AuthService.baseURL }
        static var loginURL:     String { baseURL + "/api/v1/auth/login" }
        static var authorizeURL: String { baseURL + "/api/v1/oauth/authorize" }
        static var tokenURL:     String { baseURL + "/api/v1/oauth/token" }
        static var meURL:        String { baseURL + "/api/v1/auth/me" }
        static let clientID    = "neutrino-photos-ios"
        static let redirectURI = "neutrino://oauth/callback"
    }

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "AuthService")

    /// Both sessions are built from this. Injected in tests as a configuration carrying
    /// `MockURLProtocol`, which is what makes the whole login flow — including the redirect step —
    /// exercisable without a server.
    private let configuration: URLSessionConfiguration

    private lazy var session = URLSession(configuration: configuration)

    /// Step 2 needs the 302 itself, not what it points at.
    private lazy var noRedirectSession = URLSession(configuration: configuration,
                                                    delegate: NoRedirectDelegate(),
                                                    delegateQueue: nil)

    // MARK: - Init

    init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        isAuthenticated = KeychainService.load(forKey: AuthService.accessTokenKey) != nil
    }

    // MARK: - Public API

    /// Runs the full three-step flow, registering this device by name along the way.
    /// Sets `loginError` rather than throwing — the login screen binds to it.
    func login(email: String, password: String) async {
        loginError = nil
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let sessionToken = try await step1Login(email: email, password: password)
            let (verifier, challenge) = Self.pkceValues()
            let state = Self.randomBase64URL(byteCount: 16)
            let code = try await step2Authorize(sessionToken: sessionToken, challenge: challenge,
                                                state: state, expectedState: state)
            try await step3Exchange(code: code, verifier: verifier)
            logger.debug("login succeeded")
            // Not part of the exchange, and deliberately after it: the session is established
            // whether or not the profile call answers, so a failure here must not fail the login.
            await loadProfile()
        } catch let error as AuthError {
            logger.error("login failed: \(error.localizedDescription, privacy: .public)")
            loginError = error.localizedDescription
        } catch {
            logger.error("login failed: \(error.localizedDescription, privacy: .public)")
            loginError = error.localizedDescription
        }
    }

    /// Clears the session. The encryption key pair is deliberately *not* removed — signing back in
    /// should not mean re-importing a key, and Settings offers key removal explicitly.
    func logout() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        KeychainService.delete(forKey: AuthService.refreshTokenKey)
        KeychainService.delete(forKey: AuthService.tokenExpiryKey)
        isAuthenticated = false
        loginError = nil
        profile = nil
        logger.debug("logged out")
    }

    func accessToken() -> String? {
        KeychainService.load(forKey: AuthService.accessTokenKey)
    }

    /// Loads the signed-in account from `GET /api/v1/auth/me` and publishes it as `profile`.
    ///
    /// Called after a successful sign-in and once at launch for a session restored from the
    /// Keychain. Everything the app *does* is addressed by the token's `sub` claim (see
    /// `AccessToken`), so this exists to show the user which account they are in rather than to
    /// unlock anything — which is why it answers nil on failure instead of throwing.
    ///
    /// A 401 is the exception: `refreshTokenIfNeeded` has already run, so a token still rejected
    /// here is revoked rather than stale, and the session is over.
    @discardableResult
    func loadProfile() async -> UserProfile? {
        guard let url = URL(string: AuthConfig.meURL) else { return nil }
        await refreshTokenIfNeeded()
        guard let token = accessToken() else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await perform(request, on: session)
            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode == 401 {
                logger.error("profile rejected; signing out")
                logout()
                return nil
            }
            guard (200...299).contains(http.statusCode) else {
                throw AuthError.serverError(statusCode: http.statusCode)
            }

            let profile = try DriveDate.makeDecoder().decode(UserProfile.self, from: data)
            self.profile = profile
            logger.debug("profile loaded")
            return profile
        } catch {
            // Offline, 5xx, or a shape this build doesn't know. The library is browsable without
            // knowing the account's display name.
            logger.error("profile load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Refreshes the access token when it is within a minute of expiring. Every service calls this
    /// before an authorized request, so it must stay cheap in the common case — the expiry check is
    /// a keychain read and a date comparison, with no network traffic.
    func refreshTokenIfNeeded() async {
        if let raw = KeychainService.load(forKey: AuthService.tokenExpiryKey),
           let expiry = ISO8601DateFormatter().date(from: raw),
           expiry.timeIntervalSinceNow > 60 {
            return
        }

        guard let refreshToken = KeychainService.load(forKey: AuthService.refreshTokenKey) else {
            logout()
            return
        }

        do {
            let response = try await postToken(formFields: [
                "grant_type":    "refresh_token",
                "refresh_token": refreshToken,
                "client_id":     AuthConfig.clientID,
            ])
            persist(response)
            logger.debug("token refreshed")
        } catch AuthError.invalidCredentials {
            // The refresh token itself was rejected — the session is over, not merely stale.
            logger.error("refresh rejected; signing out")
            logout()
        } catch {
            // Anything else (offline, 5xx) leaves the existing token in place: an unreachable
            // server is not a reason to sign somebody out of a library they can still browse.
            logger.error("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Step 1: Session login

    private func step1Login(email: String, password: String) async throws -> String {
        guard let url = URL(string: AuthConfig.loginURL) else { throw AuthError.configuration }

        struct Body: Encodable { let email: String; let password: String }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Device registration: this is what populates `device_name` on the session row the
        // server creates, which `GET /auth/sessions` later lists.
        request.setValue(DeviceIdentity.deviceName, forHTTPHeaderField: DeviceIdentity.deviceNameHeader)
        request.httpBody = try JSONEncoder().encode(Body(email: email, password: password))

        let (data, response) = try await perform(request, on: session)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            struct SessionResponse: Decodable { let accessToken: String }
            return try JSONDecoder().decode(SessionResponse.self, from: data).accessToken
        case 401:
            throw AuthError.invalidCredentials
        default:
            throw AuthError.serverError(statusCode: http.statusCode)
        }
    }

    // MARK: - Step 2: Authorize (redirect suppressed)

    private func step2Authorize(sessionToken: String, challenge: String,
                                state: String, expectedState: String) async throws -> String {
        guard var components = URLComponents(string: AuthConfig.authorizeURL) else {
            throw AuthError.configuration
        }
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: AuthConfig.clientID),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "redirect_uri",          value: AuthConfig.redirectURI),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state",                 value: state),
        ]
        guard let url = components.url else { throw AuthError.configuration }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request, on: noRedirectSession)

        guard let http = response as? HTTPURLResponse,
              (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let redirectURL = URL(string: location),
              let redirectComponents = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)
        else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw AuthError.tokenExchangeFailed(body)
        }

        guard let code = redirectComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingCode
        }

        // Checked before the code is used: a mismatched state means the response is not an answer
        // to the request this client made.
        let returnedState = redirectComponents.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        guard returnedState == expectedState else { throw AuthError.stateMismatch }

        return code
    }

    // MARK: - Step 3: Exchange code for tokens

    private func step3Exchange(code: String, verifier: String) async throws {
        let response = try await postToken(formFields: [
            "grant_type":    "authorization_code",
            "code":          code,
            "code_verifier": verifier,
            "redirect_uri":  AuthConfig.redirectURI,
            "client_id":     AuthConfig.clientID,
        ])
        persist(response)
    }

    // MARK: - Token endpoint

    private func postToken(formFields: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: AuthConfig.tokenURL) else { throw AuthError.configuration }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formFields
            .map { key, value in "\(key)=\(Self.formEncode(value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await perform(request, on: session)
        guard let http = response as? HTTPURLResponse else { throw AuthError.serverError(statusCode: 0) }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        case 401:
            throw AuthError.invalidCredentials
        default:
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw AuthError.tokenExchangeFailed(body)
        }
    }

    // MARK: - Helpers

    private func perform(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw AuthError.networkError(error.localizedDescription)
        }
    }

    private func persist(_ response: TokenResponse) {
        KeychainService.save(response.accessToken,  forKey: AuthService.accessTokenKey)
        KeychainService.save(response.refreshToken, forKey: AuthService.refreshTokenKey)
        let expiry = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        KeychainService.save(ISO8601DateFormatter().string(from: expiry), forKey: AuthService.tokenExpiryKey)
        isAuthenticated = true
    }

    // MARK: - Encoding

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - PKCE

    /// Verifier and its S256 challenge, per RFC 7636.
    static func pkceValues() -> (verifier: String, challenge: String) {
        let verifier = randomBase64URL(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, base64URLEncode(Data(digest)))
    }

    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }
}

// MARK: - Redirect suppression

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Models

private struct TokenResponse: Decodable {
    let accessToken:  String
    let refreshToken: String
    let expiresIn:    Int
    let tokenType:    String

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
    }
}
