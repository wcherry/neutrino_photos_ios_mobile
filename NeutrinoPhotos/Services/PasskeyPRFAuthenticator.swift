import AuthenticationServices
import CryptoKit
import Foundation
import Sodium
import UIKit
import os.log

// MARK: - PasskeyPRFError

enum PasskeyPRFError: LocalizedError, Equatable {
    case unsupportedOS
    case unsupportedKDF(String)
    case invalidParams
    case cancelled
    case noPRFOutput
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Unlocking with a passkey needs iOS 18 or later. Use your encryption password or recovery code instead."
        case .unsupportedKDF(let kdf):
            return "This passkey uses an unsupported derivation ('\(kdf)'). Update the app and try again."
        case .invalidParams:
            return "This passkey's stored details are malformed."
        case .cancelled:
            return "Passkey unlock was cancelled."
        case .noPRFOutput:
            return """
                   Your passkey did not return the value that unwraps your key. Unlock with your \
                   encryption password or recovery code instead.
                   """
        case .failed(let message):
            return message
        }
    }
}

// MARK: - PasskeyPRFAuthenticator

/// Asks a platform passkey for the PRF value that unwraps the vault's master key.
///
/// ## Why a passkey can do this at all
///
/// A passkey is a *signing* credential, so "sign a fixed challenge and hash the signature" does not
/// work — WebAuthn signs over `authenticatorData`, whose counter changes on every assertion. The
/// `prf` extension (CTAP2's `hmac-secret`) exists for this: the authenticator holds a per-credential
/// secret and returns HMAC(secret, salt), deterministic for a given salt, never extractable, and
/// released only after a user gesture. Those 32 bytes are the key-encryption key for the vault's
/// master key — no further derivation on either side, which is what
/// `web/packages/e2e-crypto/src/prf.ts` does too.
///
/// ## What this deliberately does not do
///
/// Enrolling a *new* passkey. Enrolment needs the master key in hand to re-wrap it, and the vault is
/// created on the web; this app only ever opens one. Nothing here is authentication either — the
/// user already holds a valid token, the challenge is random client-side bytes, and no assertion is
/// verified server-side. Forging a credential ID gains an attacker nothing, because they still
/// cannot produce the PRF output that opens the blob.
///
/// ## Requirements this cannot satisfy from inside the app
///
/// The relying-party ID is the Neutrino web host, so iOS will only hand this app that host's
/// passkeys if the `webcredentials:` associated domain in `project.yml` is matched by a
/// `webcredentials` section in the domain's `apple-app-site-association`. That file lives with the
/// server. Until it lists this app, an assertion fails with a domain error rather than silently
/// returning the wrong key — which is why the failure text below points at the password path.
@MainActor
final class PasskeyPRFAuthenticator: NSObject {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "PasskeyPRF")

    /// The relying-party ID a Neutrino passkey was registered against.
    ///
    /// The web client passes no explicit `rp.id`, so WebAuthn defaults it to the page's effective
    /// domain — the host the user signs in on. Reading it back off `AuthService.baseURL` keeps a
    /// self-hosted server working, and keeps this from drifting if the default host changes.
    static var relyingPartyID: String {
        URL(string: AuthService.baseURL)?.host ?? "www.getneutrino.app"
    }

    /// True when this OS can perform a PRF assertion at all. iOS 16 and 17 have passkeys but no
    /// `prf` extension, so the unlock screen hides the option rather than offering one that always
    /// fails.
    static var isSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Prompts for the passkey named by `params` and returns its 32-byte PRF output.
    func prfOutput(for params: PasskeyParams) async throws -> Bytes {
        guard #available(iOS 18.0, *) else { throw PasskeyPRFError.unsupportedOS }
        guard params.kdf == "webauthn-prf" else {
            throw PasskeyPRFError.unsupportedKDF(params.kdf)
        }
        guard let salt = KeyVaultCrypto.decodeBase64URL(params.prfSalt),
              let credentialID = KeyVaultCrypto.decodeBase64URL(params.credentialId) else {
            throw PasskeyPRFError.invalidParams
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: Self.randomChallenge())
        request.allowedCredentials = [
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: Data(credentialID))
        ]
        // The gesture is the point — it is what gates access to the key, not the assertion itself.
        request.userVerificationPreference = .required
        request.prf = .inputValues(
            .init(saltInput1: Data(salt), saltInput2: nil)
        )

        let assertion = try await perform(request)
        guard let prf = assertion.prf else {
            logger.error("assertion returned no PRF output")
            throw PasskeyPRFError.noPRFOutput
        }
        return prf.first.withUnsafeBytes { Bytes($0) }
    }

    // MARK: - Ceremony

    /// Retains the controller for the life of the request: `ASAuthorizationController` is not held
    /// by the system, and one that goes out of scope takes its delegate callbacks with it — the
    /// continuation would then never resume and the unlock screen would spin forever.
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>?

    @available(iOS 18.0, *)
    private func perform(
        _ request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>) {
        controller = nil
        // Nil'd before resuming: a `CheckedContinuation` resumed twice is a crash, and the system
        // does call back more than once in some cancellation paths.
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private static func randomChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension PasskeyPRFAuthenticator: ASAuthorizationControllerDelegate {

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let assertion = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            finish(.failure(PasskeyPRFError.failed("The system returned an unexpected credential type.")))
            return
        }
        finish(.success(assertion))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            finish(.failure(PasskeyPRFError.cancelled))
        } else {
            finish(.failure(PasskeyPRFError.failed(error.localizedDescription)))
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension PasskeyPRFAuthenticator: ASAuthorizationControllerPresentationContextProviding {

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // The key window of the foreground scene. A passkey sheet has nowhere to appear without
        // one, and there is exactly one window in this app.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first ?? ASPresentationAnchor()
    }
}
