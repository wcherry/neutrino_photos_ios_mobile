import Sodium
import XCTest
@testable import NeutrinoPhotos

// MARK: - KeyVaultCryptoTests

/// The vault envelope, asserted against the *other* implementation rather than against itself.
///
/// The fixtures in `WebVault` were produced by the web client's own `hash-wasm` and
/// `libsodium-wrappers`. A round trip through this file alone would pass with both halves wrong in
/// the same direction, and the failure that actually matters — an account that unlocks in the
/// browser and not on the phone — would sail through it.
final class KeyVaultCryptoTests: XCTestCase {

    // MARK: - Derivation

    func testArgon2MatchesTheWebImplementationExactly() throws {
        let kek = try KeyVaultCrypto.deriveKek(secret: WebVault.password,
                                               params: WebVault.argon2Params)

        XCTAssertEqual(kek.map { String(format: "%02x", $0) }.joined(), WebVault.kekHex,
                       "libsodium takes memLimit in bytes and the wire carries KiB; a factor of 1024 here is invisible until an account will not unlock")
    }

    func testAWrongPasswordDerivesADifferentKey() throws {
        let kek = try KeyVaultCrypto.deriveKek(secret: WebVault.password + "!",
                                               params: WebVault.argon2Params)
        XCTAssertNotEqual(kek.map { String(format: "%02x", $0) }.joined(), WebVault.kekHex)
    }

    func testAnUnknownKDFIsRefusedRatherThanGuessed() {
        let params = Argon2Params(kdf: "scrypt", salt: "AAECAwQFBgcICQoLDA0ODw",
                                  iterations: 3, memoryKiB: 65536, parallelism: 1)

        XCTAssertThrowsError(try KeyVaultCrypto.deriveKek(secret: "x", params: params)) { error in
            XCTAssertEqual(error as? KeyVaultCryptoError, .unsupportedKDF("scrypt"))
        }
    }

    func testMultiLaneArgon2IsRefusedRatherThanDerivedWrong() {
        // libsodium's crypto_pwhash is single-lane. Deriving anyway would produce a key that simply
        // never opens the blob, which reads to the user as "wrong password" forever.
        let params = Argon2Params(kdf: "argon2id", salt: "AAECAwQFBgcICQoLDA0ODw",
                                  iterations: 3, memoryKiB: 65536, parallelism: 4)

        XCTAssertThrowsError(try KeyVaultCrypto.deriveKek(secret: "x", params: params)) { error in
            XCTAssertEqual(error as? KeyVaultCryptoError, .unsupportedParallelism(4))
        }
    }

    // MARK: - Envelope

    func testUnwrapsAMasterKeyTheWebClientWrapped() throws {
        let masterKey = try KeyVaultCrypto.unwrapMasterKey(
            encryptedMasterKey: WebVault.encryptedMasterKey,
            secret: WebVault.password,
            params: WebVault.argon2Params)

        XCTAssertEqual(masterKey.count, KeyVaultCrypto.masterKeyBytes)
    }

    func testOpensAnIdentityTheWebClientWrapped() throws {
        let masterKey = try KeyVaultCrypto.unwrapMasterKey(
            encryptedMasterKey: WebVault.encryptedMasterKey,
            secret: WebVault.password,
            params: WebVault.argon2Params)

        let identity = try KeyVaultCrypto.openVault(encryptedIdentity: WebVault.encryptedIdentity,
                                                    publicKeyB64URL: WebVault.publicKey,
                                                    masterKey: masterKey)

        XCTAssertEqual(KeyVaultCrypto.encodeBase64URL(identity.secretKey), WebVault.privateKey)
        XCTAssertEqual(KeyVaultCrypto.encodeBase64URL(identity.publicKey), WebVault.publicKey)
    }

    func testAWrongPasswordReportsItselfAsOne() {
        XCTAssertThrowsError(try KeyVaultCrypto.unwrapMasterKey(
            encryptedMasterKey: WebVault.encryptedMasterKey,
            secret: "not the password",
            params: WebVault.argon2Params)) { error in
            XCTAssertEqual(error as? KeyVaultCryptoError, .decryptionFailed)
        }
    }

    func testAVaultWhosePublicKeyDoesNotMatchIsRejected() throws {
        let masterKey = try KeyVaultCrypto.unwrapMasterKey(
            encryptedMasterKey: WebVault.encryptedMasterKey,
            secret: WebVault.password,
            params: WebVault.argon2Params)

        // A tampered `publicKey` otherwise yields a key that decrypts nothing, surfacing much later
        // as unexplained failures on individual photographs instead of once, here.
        let otherKey = KeyVaultCrypto.encodeBase64URL(Bytes(repeating: 9, count: 32))
        XCTAssertThrowsError(try KeyVaultCrypto.openVault(encryptedIdentity: WebVault.encryptedIdentity,
                                                          publicKeyB64URL: otherKey,
                                                          masterKey: masterKey)) { error in
            XCTAssertEqual(error as? KeyVaultCryptoError, .identityMismatch)
        }
    }

    func testAMalformedBlobIsNotMistakenForAWrongPassword() throws {
        let kek = try KeyVaultCrypto.deriveKek(secret: WebVault.password, params: WebVault.argon2Params)

        // Shorter than a nonce: there is no ciphertext at all, so there is nothing a password
        // could have been wrong about.
        XCTAssertThrowsError(try KeyVaultCrypto.open("AAEC", key: kek)) { error in
            XCTAssertEqual(error as? KeyVaultCryptoError, .malformedBlob)
        }
    }

    func testSealAndOpenRoundTrip() throws {
        let key = Bytes(repeating: 3, count: 32)
        let secret = Bytes("something worth wrapping".utf8)

        let sealed = try KeyVaultCrypto.seal(secret, key: key)
        XCTAssertEqual(try KeyVaultCrypto.open(sealed, key: key), secret)
        // Nonce is random, so the same input never produces the same blob twice.
        XCTAssertNotEqual(try KeyVaultCrypto.seal(secret, key: key), sealed)
    }

    // MARK: - Passkey wrapping

    func testAPasskeyPRFOutputUnwrapsTheSameMasterKey() throws {
        // The PRF output *is* the wrapping key on both sides — no second derivation — so a blob
        // wrapped under 32 arbitrary bytes must open with exactly those bytes.
        let prfOutput = Bytes((0..<32).map { UInt8($0) })
        let masterKey = Bytes(repeating: 7, count: 32)
        let wrapped = try KeyVaultCrypto.seal(masterKey, key: prfOutput)

        XCTAssertEqual(try KeyVaultCrypto.unwrapMasterKey(encryptedMasterKey: wrapped,
                                                          prfOutput: prfOutput),
                       masterKey)
    }

    func testAPRFOutputOfTheWrongLengthIsRefused() throws {
        let wrapped = try KeyVaultCrypto.seal(Bytes(repeating: 7, count: 32),
                                              key: Bytes(repeating: 1, count: 32))

        XCTAssertThrowsError(try KeyVaultCrypto.unwrapMasterKey(encryptedMasterKey: wrapped,
                                                                prfOutput: Bytes(repeating: 1, count: 16)))
    }

    // MARK: - Recovery codes

    func testRecoveryCodesAreNormalizedTheWayTheWebClientDoes() {
        // Crockford base32 excludes I, L, O and U, so a code read off paper folds onto lookalikes.
        XCTAssertEqual(KeyVaultCrypto.normalizeRecoveryCode("iloU-8k2n 4d"), "110V8K2N4D")
        XCTAssertEqual(KeyVaultCrypto.normalizeRecoveryCode("ABCD-EFGH"), "ABCDEFGH")
    }

    // MARK: - Base64

    func testBase64URLDecodesBothSpellings() {
        let bytes = Bytes([251, 255, 190, 0, 17])
        let urlSafe = KeyVaultCrypto.encodeBase64URL(bytes)
        let standard = Data(bytes).base64EncodedString()

        XCTAssertFalse(urlSafe.contains("="), "the wire format is unpadded")
        XCTAssertEqual(KeyVaultCrypto.decodeBase64URL(urlSafe), bytes)
        // A key file exported from the web app uses standard base64; both must read as the same key.
        XCTAssertEqual(KeyVaultCrypto.decodeBase64URL(standard), bytes)
    }
}
