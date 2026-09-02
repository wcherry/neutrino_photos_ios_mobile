import CryptoKit
import Foundation
import Sodium
import NeutrinoCrypto

// MARK: - KeyVaultCryptoError

enum KeyVaultCryptoError: LocalizedError, Equatable {
    case unsupportedKDF(String)
    case unsupportedParallelism(Int)
    case invalidBase64
    case malformedBlob
    case derivationFailed
    case decryptionFailed
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedKDF(let kdf):
            return "This vault uses an unsupported key derivation function ('\(kdf)'). Update the app and try again."
        case .unsupportedParallelism(let lanes):
            return "This vault needs Argon2 parallelism \(lanes), which this device cannot compute."
        case .invalidBase64:
            return "The vault contains malformed data."
        case .malformedBlob:
            return "The vault contains a malformed encrypted value."
        case .derivationFailed:
            return "Could not derive the key from your password on this device."
        case .decryptionFailed:
            return "Wrong password or recovery code."
        case .identityMismatch:
            return "This vault is inconsistent — the unwrapped key does not match its public key."
        }
    }
}

// MARK: - Argon2Params

/// The password/recovery derivation parameters, exactly as the web client writes them into
/// `user_key_unlocks.params`.
///
/// Decoded with a *plain* `JSONDecoder`. The app's snake-case-converting decoder would rewrite
/// `memoryKiB` to `memory_ki_b` and the derivation would silently use a different memory cost —
/// which produces a different key and a wrong-password error the user cannot act on.
struct Argon2Params: Codable, Equatable {
    let kdf: String
    /// base64url, 16 bytes.
    let salt: String
    /// Argon2 time cost.
    let iterations: Int
    /// Argon2 memory cost, in **KiB** — libsodium wants bytes, so this is multiplied at use.
    let memoryKiB: Int
    let parallelism: Int
}

// MARK: - PasskeyParams

/// The passkey derivation parameters the web client writes for a `passkey` unlock method.
///
/// There is no salt-and-cost here because there is no derivation: the authenticator holds a
/// per-credential secret and returns HMAC(secret, `prfSalt`), and those 32 bytes *are* the key that
/// wraps the master key. See `web/packages/e2e-crypto/src/prf.ts`.
struct PasskeyParams: Codable, Equatable {
    let kdf: String
    /// base64url credential ID, used to ask for this exact passkey at unlock.
    let credentialId: String
    /// base64url, 32 bytes — the PRF input.
    let prfSalt: String
}

// MARK: - KeyVaultCrypto

/// Client half of the account key vault: the envelope that recovers the Curve25519 identity key
/// from a password, a recovery code, or a passkey, instead of having one pasted in by hand.
///
/// ```
/// identity secret key  ──secretbox──▶  master key (MK, 32 random bytes)
/// MK                   ──secretbox──▶  one wrapped copy per unlock method
/// ```
///
/// The server stores the wrapped forms and nothing that opens them. The other implementation is
/// `web/packages/e2e-crypto/src/vault.ts`, and `KeyVaultCryptoTests` unlocks a vault that
/// implementation actually produced — the two have to agree byte for byte or an account unlocked on
/// the web cannot be unlocked here.
///
/// Wire-compatibility notes, which are the things that break cross-platform unlock if they drift:
///
///   * Argon2id parameters travel with each blob. libsodium's `crypto_pwhash` takes `memLimit` in
///     **bytes**, while the web side (hash-wasm) takes **KiB**, so `memoryKiB` is multiplied here.
///   * libsodium fixes Argon2 parallelism at 1, and the web side sends 1 for that reason. A blob
///     asking for anything else is rejected rather than derived wrong.
///   * All binary fields are base64url with no padding.
///   * `secretBox.seal` emits `nonce || ciphertext`, which is the layout the web client writes.
enum KeyVaultCrypto {

    private static let sodium = Sodium()

    /// A secretbox key, and the master key, are both 32 bytes.
    static let masterKeyBytes = 32

    /// Curve25519 keys are 32 bytes in both halves.
    static let curve25519KeyBytes = 32

    // MARK: - Derivation

    /// Derives the 32-byte key-encryption key for a password or recovery code.
    ///
    /// Deliberately slow — around a second on an older phone at the web client's default cost — so
    /// callers should say so on screen rather than showing a bare spinner.
    static func deriveKek(secret: String, params: Argon2Params) throws -> Bytes {
        guard params.kdf == "argon2id" else {
            throw KeyVaultCryptoError.unsupportedKDF(params.kdf)
        }
        // `crypto_pwhash` is single-lane by construction. Failing loudly beats deriving a key that
        // would simply never open the blob.
        guard params.parallelism == 1 else {
            throw KeyVaultCryptoError.unsupportedParallelism(params.parallelism)
        }
        guard let salt = decodeBase64URL(params.salt) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        guard let kek = sodium.pwHash.hash(
            outputLength: masterKeyBytes,
            passwd: Array(secret.utf8),
            salt: salt,
            opsLimit: params.iterations,
            memLimit: params.memoryKiB * 1024,   // KiB on the wire, bytes here
            alg: .Argon2ID13
        ) else {
            throw KeyVaultCryptoError.derivationFailed
        }
        return kek
    }

    // MARK: - Secretbox envelope

    /// Encrypts `plaintext` under `key`, returning base64url(nonce || ciphertext).
    static func seal(_ plaintext: Bytes, key: Bytes) throws -> String {
        guard let sealed: Bytes = sodium.secretBox.seal(message: plaintext, secretKey: key) else {
            throw KeyVaultCryptoError.derivationFailed
        }
        return encodeBase64URL(sealed)
    }

    /// Inverse of ``seal(_:key:)``. Reports `.decryptionFailed` for a wrong key — the overwhelmingly
    /// likely cause is a mistyped password, and the distinction between that and a corrupted blob is
    /// not one the user can act on differently.
    static func open(_ blob: String, key: Bytes) throws -> Bytes {
        guard let raw = decodeBase64URL(blob) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        guard raw.count > sodium.secretBox.NonceBytes else {
            throw KeyVaultCryptoError.malformedBlob
        }
        guard let plaintext = sodium.secretBox.open(nonceAndAuthenticatedCipherText: raw,
                                                    secretKey: key) else {
            throw KeyVaultCryptoError.decryptionFailed
        }
        return plaintext
    }

    // MARK: - Vault

    /// Recovers the master key from a password or recovery-code unlock blob.
    static func unwrapMasterKey(encryptedMasterKey: String, secret: String,
                                params: Argon2Params) throws -> Bytes {
        try open(encryptedMasterKey, key: deriveKek(secret: secret, params: params))
    }

    /// Recovers the master key from a passkey unlock blob, given the authenticator's PRF output.
    ///
    /// The PRF output is the wrapping key directly — there is no second derivation on either side.
    static func unwrapMasterKey(encryptedMasterKey: String, prfOutput: Bytes) throws -> Bytes {
        guard prfOutput.count == masterKeyBytes else {
            throw KeyVaultCryptoError.decryptionFailed
        }
        return try open(encryptedMasterKey, key: prfOutput)
    }

    /// Unwraps the identity key and confirms it matches the vault's advertised public key.
    ///
    /// Without the check, a tampered `encryptedIdentity` yields a key that decrypts nothing and
    /// surfaces much later as unexplained "cannot decrypt" errors on individual photographs, rather
    /// than as one clear failure here.
    static func openVault(encryptedIdentity: String, publicKeyB64URL: String,
                          masterKey: Bytes) throws -> (publicKey: Bytes, secretKey: Bytes) {
        let secretKey = try open(encryptedIdentity, key: masterKey)
        guard secretKey.count == curve25519KeyBytes else {
            throw KeyVaultCryptoError.identityMismatch
        }
        guard let publicKey = decodeBase64URL(publicKeyB64URL) else {
            throw KeyVaultCryptoError.invalidBase64
        }
        guard let derived = derivePublicKey(from: secretKey), derived == publicKey else {
            throw KeyVaultCryptoError.identityMismatch
        }
        return (publicKey, secretKey)
    }

    /// Derives the Curve25519 public key from a secret key.
    ///
    /// swift-sodium exposes no `scalarmult_base` wrapper and this target depends on the `Sodium`
    /// product rather than `Clibsodium`. CryptoKit's X25519 performs the same multiplication — and
    /// is already what `KeyImportService` uses to check a pasted key pair.
    static func derivePublicKey(from secretKey: Bytes) -> Bytes? {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(secretKey)) else {
            return nil
        }
        return Bytes(priv.publicKey.rawRepresentation)
    }

    // MARK: - Recovery codes

    /// Canonicalises a typed recovery code exactly as the web client does, so a code generated there
    /// unlocks here.
    ///
    /// Crockford base32 excludes I, L, O and U; folding them onto their lookalikes means a code
    /// transcribed off paper still works.
    static func normalizeRecoveryCode(_ input: String) -> String {
        var code = input.uppercased()
        code = code.filter { !$0.isWhitespace && $0 != "-" }
        code = code.replacingOccurrences(of: "I", with: "1")
        code = code.replacingOccurrences(of: "L", with: "1")
        code = code.replacingOccurrences(of: "O", with: "0")
        code = code.replacingOccurrences(of: "U", with: "V")
        return code
    }

    // MARK: - Base64URL

    static func encodeBase64URL(_ bytes: Bytes) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Accepts base64url and standard base64, padded or not: the vault endpoints write base64url,
    /// while an exported key file uses standard base64.
    static func decodeBase64URL(_ string: String) -> Bytes? {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return Bytes(data)
    }
}
