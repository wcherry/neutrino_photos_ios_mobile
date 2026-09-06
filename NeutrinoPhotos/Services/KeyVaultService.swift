import Foundation
import Sodium
import os.log
import NeutrinoCrypto

// MARK: - Wire types
//
// The vault endpoints are camelCase on the wire and are decoded with a *plain* `JSONDecoder`. The
// app's snake-case-converting decoder would rewrite `memoryKiB` inside the `params` blob and break
// the Argon2 derivation — see `Argon2Params`.

struct VaultUnlockMethod: Codable, Equatable, Identifiable {
    let id: String
    /// `"password"`, `"passkey"`, or `"recovery"`.
    let method: String
    let label: String
    /// base64url( nonce || ciphertext of the master key ).
    let encryptedMasterKey: String
    /// JSON string: `Argon2Params` for password and recovery, `PasskeyParams` for passkey.
    let params: String
    let createdAt: String?
    let lastUsedAt: String?
}

struct VaultResponse: Codable, Equatable {
    /// base64url( nonce || ciphertext of the Curve25519 secret key ).
    let encryptedIdentity: String
    let publicKey: String
    let version: Int
    let unlocks: [VaultUnlockMethod]
}

// MARK: - KeyVaultError

enum KeyVaultError: LocalizedError, Equatable {
    case noVault
    case methodNotEnrolled(String)
    case unreachable(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .noVault:
            return """
                   This account has no encryption vault yet. Set one up in Neutrino on the web, or \
                   import your key file here.
                   """
        case .methodNotEnrolled(let method):
            switch method {
            case "recovery": return "No recovery code is enrolled for this account."
            case "passkey":  return "No passkey is enrolled for this account."
            default:         return "No encryption password is enrolled for this account."
            }
        case .unreachable(let message):
            return message
        case .decoding:
            return "The server sent a key vault this version of the app does not understand."
        }
    }
}

// MARK: - VaultStatus

/// What this device can currently do with the account's encryption key.
///
/// `locked` is the interesting one. It does **not** mean the app is unusable: the timeline draws
/// plaintext cover thumbnails stored beside each Drive file, so a locked library still browses. What
/// it means is that no original can be opened and nothing can be uploaded — see `LibraryView` and
/// `PhotoImportService`, which are the two places that say so on screen.
enum VaultStatus: Equatable {
    /// Not asked yet — the launch state, before the first `refresh()`.
    case unknown
    /// The identity key is on this device.
    case unlocked
    /// The account has a vault and this device does not hold its key.
    case locked
    /// The account has never created a vault. Only a key file can help.
    case noVault
    /// The vault could not be fetched: offline, or the server said something unexpected.
    case unreachable

    var isUnlocked: Bool { self == .unlocked }
}

// MARK: - KeyVaultService

/// Opens the account's key vault and puts the identity key where the rest of the app already looks
/// for it.
///
/// This is what replaces pasting a key bundle in by hand: the same encryption password the user set
/// on the web unlocks the same identity here, and `KeyImportService` keeps being the single place
/// keys are stored, so nothing downstream — sealing a DEK, opening an original — knows or cares
/// which route the key arrived by.
///
/// ## What is stored, and what is not
///
/// The master key is **not** persisted. It exists for the moment it takes to unwrap the identity and
/// is then dropped; what lands in the Keychain is the Curve25519 identity key it protects. Holding
/// MK afterwards would buy exactly one thing this app does not do — enrolling a new unlock method —
/// in exchange for a second long-lived secret on the device. Both are written with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a background upload after a reboot-and-
/// unlock can still reach the key it needs to seal with.
///
/// ## Nothing here is logged
///
/// Not the password, not the KEK, not the master key, not the identity. File-level facts — which
/// method was used, whether it succeeded — are the most these messages say.
@MainActor
final class KeyVaultService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var status: VaultStatus = .unknown

    /// The account's vault, once fetched. Held so the unlock screen knows which methods are enrolled
    /// and Settings can list them without a second round trip.
    @Published private(set) var vault: VaultResponse?

    /// True when this device holds a key that is *not* this account's — what happens after signing
    /// out and into a different Neutrino account without removing the old key. Worth saying out
    /// loud, because the symptom otherwise is every photograph failing to decrypt.
    @Published private(set) var keyBelongsToAnotherAccount = false

    // MARK: - Dependencies

    private let api: APIClient
    private let passkeys: PasskeyPRFAuthenticator

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "KeyVaultService")

    /// Plain, deliberately: see the note on the wire types above.
    private static let decoder = JSONDecoder()

    // MARK: - Init

    init(api: APIClient, passkeys: PasskeyPRFAuthenticator? = nil) {
        self.api = api
        // Built here rather than as a default argument: `PasskeyPRFAuthenticator` is main-actor
        // isolated and a default argument is evaluated in the caller's context, which need not be.
        self.passkeys = passkeys ?? PasskeyPRFAuthenticator()
    }

    // MARK: - Status

    /// Fetches the vault and works out where this device stands.
    ///
    /// Called at launch and after sign-in. Cheap enough to run every time — one GET — and it is the
    /// only thing that can notice a key left behind from a different account.
    func refresh() async {
        do {
            let vault = try await fetchVault()
            self.vault = vault
            guard let vault else {
                // No vault on the server. A key file imported by hand is still a perfectly good
                // key, so the presence of one still counts as unlocked.
                keyBelongsToAnotherAccount = false
                status = KeyImportService.hasStoredKeys() ? .unlocked : .noVault
                return
            }
            let stored = KeyImportService.storedKeys()
            let matches = stored.map { Self.samePublicKey($0.publicKey, vault.publicKey) } ?? false
            keyBelongsToAnotherAccount = stored != nil && !matches
            status = matches ? .unlocked : .locked
            logger.debug("vault refreshed: \(String(describing: self.status), privacy: .public)")
        } catch {
            // Offline or a 5xx. Fall back to what the Keychain says rather than locking a library
            // the user can still browse — an unreachable server is not a reason to hide photographs.
            logger.error("vault refresh failed: \(error.localizedDescription, privacy: .public)")
            keyBelongsToAnotherAccount = false
            status = KeyImportService.hasStoredKeys() ? .unlocked : .unreachable
        }
    }

    /// Re-reads the Keychain without touching the network. Called after a key file is imported.
    func refreshFromKeychain() {
        guard KeyImportService.hasStoredKeys() else {
            status = vault == nil ? .noVault : .locked
            return
        }
        if let vault, let stored = KeyImportService.storedKeys() {
            let matches = Self.samePublicKey(stored.publicKey, vault.publicKey)
            keyBelongsToAnotherAccount = !matches
            status = matches ? .unlocked : .locked
            return
        }
        keyBelongsToAnotherAccount = false
        status = .unlocked
    }

    /// Removes the identity from this device. The vault on the server is untouched, so unlocking
    /// again is a password away.
    func lock() {
        KeyImportService.removeKeys()
        keyBelongsToAnotherAccount = false
        status = vault == nil ? .noVault : .locked
        logger.debug("vault locked on this device")
    }

    // MARK: - Fetching

    /// The caller's vault, or nil when they have never set one up.
    func fetchVault() async throws -> VaultResponse? {
        do {
            return try await api.getIfPresent("/api/v1/auth/keyvault", decoder: Self.decoder)
        } catch let error as APIError {
            if case .decoding = error { throw KeyVaultError.decoding }
            throw KeyVaultError.unreachable(error.localizedDescription)
        }
    }

    // MARK: - Unlocking

    /// Which methods this build can actually offer, in the order the unlock screen shows them.
    ///
    /// A passkey the OS cannot perform a PRF assertion with is filtered out rather than offered and
    /// then failed — iOS 16 and 17 have passkeys but no `prf` extension.
    var availableMethods: [VaultUnlockMethod] {
        (vault?.unlocks ?? []).filter { unlock in
            unlock.method != "passkey" || PasskeyPRFAuthenticator.isSupported
        }
    }

    /// Unlock with the encryption password set on the web.
    @discardableResult
    func unlock(password: String) async throws -> KeyBundle {
        try await unlock(secret: password, method: "password")
    }

    /// Unlock with the recovery code shown when the vault was created.
    @discardableResult
    func unlock(recoveryCode: String) async throws -> KeyBundle {
        try await unlock(secret: KeyVaultCrypto.normalizeRecoveryCode(recoveryCode),
                         method: "recovery")
    }

    /// Unlock by asking an enrolled passkey for its PRF value.
    ///
    /// - Parameter unlockID: which enrolled passkey to use, when more than one is. Defaults to the
    ///   first, which is the only case worth optimising for.
    @discardableResult
    func unlockWithPasskey(unlockID: String? = nil) async throws -> KeyBundle {
        let vault = try await requireVault()
        let candidates = vault.unlocks.filter { $0.method == "passkey" }
        guard let unlock = candidates.first(where: { $0.id == unlockID }) ?? candidates.first else {
            throw KeyVaultError.methodNotEnrolled("passkey")
        }
        guard let data = unlock.params.data(using: .utf8),
              let params = try? Self.decoder.decode(PasskeyParams.self, from: data) else {
            throw PasskeyPRFError.invalidParams
        }

        let prfOutput = try await passkeys.prfOutput(for: params)
        let masterKey = try KeyVaultCrypto.unwrapMasterKey(
            encryptedMasterKey: unlock.encryptedMasterKey, prfOutput: prfOutput)
        return try store(masterKey: masterKey, vault: vault, unlockID: unlock.id, method: "passkey")
    }

    private func unlock(secret: String, method: String) async throws -> KeyBundle {
        let vault = try await requireVault()
        guard let unlock = vault.unlocks.first(where: { $0.method == method }) else {
            throw KeyVaultError.methodNotEnrolled(method)
        }
        guard let data = unlock.params.data(using: .utf8),
              let params = try? Self.decoder.decode(Argon2Params.self, from: data) else {
            throw KeyVaultError.decoding
        }

        // Argon2id is deliberately slow. Off the main actor so a second of key stretching does not
        // freeze the unlock screen's own spinner.
        let encryptedMasterKey = unlock.encryptedMasterKey
        let masterKey = try await Task.detached(priority: .userInitiated) {
            try KeyVaultCrypto.unwrapMasterKey(encryptedMasterKey: encryptedMasterKey,
                                               secret: secret, params: params)
        }.value

        return try store(masterKey: masterKey, vault: vault, unlockID: unlock.id, method: method)
    }

    /// Unwraps the identity with `masterKey`, stores it, and updates the published state.
    private func store(masterKey: Bytes, vault: VaultResponse,
                       unlockID: String, method: String) throws -> KeyBundle {
        let identity = try KeyVaultCrypto.openVault(encryptedIdentity: vault.encryptedIdentity,
                                                    publicKeyB64URL: vault.publicKey,
                                                    masterKey: masterKey)
        // base64url, matching what the web client writes and what the key-file path already accepts.
        let bundle = KeyBundle(publicKey: KeyVaultCrypto.encodeBase64URL(identity.publicKey),
                               privateKey: KeyVaultCrypto.encodeBase64URL(identity.secretKey),
                               keyVersion: String(vault.version))
        KeyImportService.storeKeys(bundle)
        keyBelongsToAnotherAccount = false
        status = .unlocked
        logger.info("vault opened via \(method, privacy: .public)")

        // The vault holds one identity, the active one. Anything sealed to a version this account
        // has rotated away from needs the key file, and this is the moment the key that opens it
        // arrives. Detached, like `markUsed` below, because this method is the synchronous tail of
        // the unlock and the unlock has already succeeded — a network round trip must not hold it
        // open, and a failure here is retried on the next launch.
        Task { try? await KeyFileService.shared.restoreArchivedKeys() }

        // Bookkeeping only — a failure here must not fail an unlock that already worked.
        Task { await markUsed(unlockID) }
        return bundle
    }

    private func requireVault() async throws -> VaultResponse {
        if let vault { return vault }
        guard let fetched = try await fetchVault() else { throw KeyVaultError.noVault }
        vault = fetched
        return fetched
    }

    private func markUsed(_ unlockID: String) async {
        _ = try? await api.send(method: "POST",
                                path: "/api/v1/auth/keyvault/unlocks/\(unlockID)/used")
    }

    // MARK: - Helpers

    /// Compares two public keys across encodings: the vault serves base64url, while a key file
    /// exported from the web app uses standard base64, and the two spellings of the same key must
    /// not read as different accounts.
    private static func samePublicKey(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = KeyVaultCrypto.decodeBase64URL(lhs),
              let right = KeyVaultCrypto.decodeBase64URL(rhs) else { return false }
        return left == right
    }
}
