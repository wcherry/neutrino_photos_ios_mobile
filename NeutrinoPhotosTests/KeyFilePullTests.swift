import XCTest
import Sodium
import NeutrinoCrypto
@testable import NeutrinoPhotos

// MARK: - KeyFilePullTests

/// The pull end to end: fetch, unseal, archive, and resolve a version out the other side.
///
/// `KeyFileServiceTests` covers the decisions; this covers the wiring around them — the request
/// that goes out, and the Keychain state that comes back. Between them there is no untested step
/// from "the server has a key file" to "this photo opens".
@MainActor
final class KeyFilePullTests: XCTestCase {

    private let sodium = Sodium()
    private var sut: KeyFileService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestTokens.install()
        sut = KeyFileService.forTesting(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        KeyImportService.removeKeys()
        TestTokens.remove()
        sut = nil
        super.tearDown()
    }

    private func b64(_ bytes: Bytes) -> String {
        sodium.utils.bin2base64(bytes, variant: .URLSAFE_NO_PADDING)!
    }

    /// Stubs `GET /drive/key-file` with the given body and status.
    private func stubKeyFile(status: Int, body: Data) {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (response, body)
        }
    }

    /// The response the server sends after a rotation to v3 on an account that has held v1 and v2.
    private func keyFileJSON(retired: [(version: Int, pair: Box.KeyPair)],
                             sealedTo active: Box.KeyPair) -> Data {
        let entries = retired.map { entry in
            """
            {"keyVersion":\(entry.version),\
            "encryptedKey":"\(b64(sodium.box.seal(message: entry.pair.secretKey,
                                                  recipientPublicKey: active.publicKey)!))",\
            "publicKey":"\(b64(entry.pair.publicKey))"}
            """
        }
        return Data("""
        {"userId":"u1","keys":[\(entries.joined(separator: ","))],\
        "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-22T00:00:00Z"}
        """.utf8)
    }

    // MARK: - The whole path

    /// Scan the key code for v3, pull, and a photo sealed to v2 opens. This is the user-visible
    /// promise of the feature, start to finish.
    func testPullingAfterEnrolmentMakesAnOlderDocumentOpen() async throws {
        let v2 = sodium.box.keyPair()!
        let v3 = sodium.box.keyPair()!

        // The phone has just scanned the code, so it holds v3 and only v3.
        KeyImportService.storeKeys(KeyBundle(publicKey: b64(v3.publicKey),
                                             privateKey: b64(v3.secretKey),
                                             keyVersion: "3"))
        XCTAssertEqual(KeyImportService.keyPair(forVersion: 2), .missingVersion(2))

        stubKeyFile(status: 200, body: keyFileJSON(retired: [(2, v2)], sealedTo: v3))
        let outcome = try await sut.restoreArchivedKeys()

        XCTAssertEqual(outcome.recovered, 1)
        XCTAssertEqual(KeyImportService.keyPair(forVersion: 2),
                       .found(publicKey: b64(v2.publicKey), privateKey: b64(v2.secretKey)))

        // And the DEK of a photo written before the rotation now opens.
        let dek = MediaCrypto.newDEK()
        let sealed = b64(sodium.box.seal(message: dek, recipientPublicKey: v2.publicKey)!)
        let content = MediaContentService(api: APIClient(session: MockURLProtocol.makeSession()))
        XCTAssertEqual(try content.unsealDEK(sealed, keyVersion: 2), dek)
    }

    func testTheRequestGoesToTheKeyFileEndpointWithTheBearerToken() async throws {
        let v3 = sodium.box.keyPair()!
        KeyImportService.storeKeys(KeyBundle(publicKey: b64(v3.publicKey),
                                             privateKey: b64(v3.secretKey),
                                             keyVersion: "3"))
        stubKeyFile(status: 404, body: Data())
        _ = try await sut.restoreArchivedKeys()

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/drive/key-file")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(TestTokens.defaultAccessToken)")
    }

    // MARK: - What a failed pull must not do

    /// A rotated account with no key file is the state that cost a real debugging session: the
    /// phone holds v3, the server has nothing, and every earlier key sits in one browser profile
    /// the phone cannot reach. Reported as its own flag so the import screen can name the fix —
    /// the browser — instead of suggesting another scan, which cannot ever work.
    func testARotatedAccountWithNoKeyFileIsDistinguishable() async throws {
        let v3 = sodium.box.keyPair()!
        KeyImportService.storeKeys(KeyBundle(publicKey: b64(v3.publicKey),
                                             privateKey: b64(v3.secretKey),
                                             keyVersion: "3"))
        stubKeyFile(status: 404, body: Data())

        let outcome = try await sut.restoreArchivedKeys()

        XCTAssertTrue(outcome.serverHasNoKeyFile)
        XCTAssertTrue(outcome.isEmpty, "nothing was recovered, and nothing pretended to be")
    }

    /// An account that has never rotated has no key file. That is a state, not a failure, and it
    /// must not surface to the user as an error on an otherwise perfect enrolment.
    func testAMissingKeyFileIsNotAnError() async throws {
        let v1 = sodium.box.keyPair()!
        KeyImportService.storeKeys(KeyBundle(publicKey: b64(v1.publicKey),
                                             privateKey: b64(v1.secretKey),
                                             keyVersion: "1"))
        stubKeyFile(status: 404, body: Data())

        let outcome = try await sut.restoreArchivedKeys()

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertTrue(outcome.serverHasNoKeyFile)
        XCTAssertTrue(KeyArchive.load().isEmpty)
    }

    /// A server error is reported rather than swallowed. The enrolment stands — the active key is
    /// already stored — but the caller has to be able to tell the user their older photos are
    /// not readable yet, which is the difference between a retryable state and a silent one.
    func testAServerErrorIsReportedAndLeavesTheArchiveAlone() async throws {
        let v3 = sodium.box.keyPair()!
        let v2 = sodium.box.keyPair()!
        KeyImportService.storeKeys(KeyBundle(publicKey: b64(v3.publicKey),
                                             privateKey: b64(v3.secretKey),
                                             keyVersion: "3"))
        XCTAssertTrue(KeyArchive.store([StoredKeyPair(version: 2,
                                                      publicKey: b64(v2.publicKey),
                                                      privateKey: b64(v2.secretKey))]))

        stubKeyFile(status: 500, body: Data())

        do {
            _ = try await sut.restoreArchivedKeys()
            XCTFail("expected the server error to be reported")
        } catch {
            guard case KeyFileError.serverError(500) = error else {
                return XCTFail("expected serverError(500), got \(error)")
            }
        }
        XCTAssertEqual(KeyArchive.load().map(\.version), [2],
                       "a failed pull must not discard keys this device already had")
    }

    /// Without a key there is nothing to unseal with, and the pull says so rather than reporting
    /// an empty success that reads as "your account has no older keys".
    func testPullingWithNoKeyOnTheDeviceIsRefused() async {
        KeyImportService.removeKeys()

        do {
            _ = try await sut.restoreArchivedKeys()
            XCTFail("expected the missing key to be reported")
        } catch {
            guard case KeyFileError.noEncryptionKey = error else {
                return XCTFail("expected noEncryptionKey, got \(error)")
            }
        }
    }
}
