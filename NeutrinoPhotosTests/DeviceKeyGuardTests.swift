import CryptoKit
import XCTest
import NeutrinoCore
import NeutrinoCrypto
@testable import NeutrinoPhotos

// MARK: - Helpers

/// A fresh X25519 pair, base64url, the way the directory and the Keychain both spell keys.
private func makeKeyPair() -> (publicKey: String, privateKey: String) {
    let priv = Curve25519.KeyAgreement.PrivateKey()
    return (TestKeys.base64URL(priv.publicKey.rawRepresentation), TestKeys.base64URL(priv.rawRepresentation))
}

private func publishedKeyJSON(_ publicKey: String, version: Int) -> Data {
    try! JSONSerialization.data(withJSONObject: ["userId": TestTokens.userId,
                                                 "publicKey": publicKey,
                                                 "version": version])
}

private func uploadResponseJSON(id: String) -> Data {
    Data(#"{"id":"\#(id)","name":"a.jpg","sizeBytes":1,"mimeType":"image/jpeg","updatedAt":"2026-01-01T00:00:00"}"#.utf8)
}

// MARK: - DeviceKeyStatusTests

final class DeviceKeyStatusTests: XCTestCase {

    func testCurrentWhenTheStoredKeyIsThePublishedOne() {
        let key = makeKeyPair().publicKey
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: key,
                                          published: PublishedKey(publicKey: key, version: 2)),
                       .current(version: 2))
    }

    func testCurrentWhenOnlyThePaddingDiffers() {
        let key = makeKeyPair().publicKey
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: key + "=",
                                          published: PublishedKey(publicKey: key, version: 1)),
                       .current(version: 1))
    }

    func testStaleWhenTheAccountPublishesAnotherKey() {
        let published = PublishedKey(publicKey: makeKeyPair().publicKey, version: 1)
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: makeKeyPair().publicKey, published: published),
                       .stale(published: published))
    }

    func testUnpublishedWhenTheAccountPublishesNothing() {
        XCTAssertEqual(DeviceKeyStatus.of(storedPublicKey: makeKeyPair().publicKey, published: nil),
                       .unpublished)
    }
}

// MARK: - DeviceKeyRewrapTests

final class DeviceKeyRewrapTests: XCTestCase {

    /// The incident: a device sealed to its own stale key. After the rewrap the ref must open with
    /// the account's key — the one the web holds — and carry the same DEK.
    func testMovesADEKSealedToTheDeviceKeyOntoTheAccountsKey() throws {
        let device = makeKeyPair(), account = makeKeyPair()
        let dek = MediaCrypto.newDEK()
        let sealed = try MediaCrypto.seal(dek: dek, toPublicKey: KeyVaultCrypto.decodeBase64URL(device.publicKey)!)

        let rewrapped = try XCTUnwrap(DeviceKeyRewrap.rewrap(
            SealedFileKey(sealed: sealed, keyVersion: 1),
            deviceKey: KeyBundle(publicKey: device.publicKey, privateKey: device.privateKey, keyVersion: "1"),
            to: PublishedKey(publicKey: account.publicKey, version: 4)))

        XCTAssertEqual(rewrapped.keyVersion, 4)
        XCTAssertEqual(try MediaCrypto.openDEK(rewrapped.sealed,
                                               publicKey: KeyVaultCrypto.decodeBase64URL(account.publicKey)!,
                                               secretKey: KeyVaultCrypto.decodeBase64URL(account.privateKey)!),
                       dek, "Same DEK, new recipient — the ciphertext is untouched")
    }

    func testLeavesARefTheDeviceKeyDoesNotOpenAlone() throws {
        let device = makeKeyPair(), account = makeKeyPair()
        let sealed = try MediaCrypto.seal(dek: MediaCrypto.newDEK(),
                                          toPublicKey: KeyVaultCrypto.decodeBase64URL(account.publicKey)!)
        XCTAssertNil(DeviceKeyRewrap.rewrap(
            SealedFileKey(sealed: sealed, keyVersion: 1),
            deviceKey: KeyBundle(publicKey: device.publicKey, privateKey: device.privateKey, keyVersion: "1"),
            to: PublishedKey(publicKey: account.publicKey, version: 1)))
    }
}

// MARK: - DeviceKeyGuardTests

@MainActor
final class DeviceKeyGuardTests: XCTestCase {

    private var api: APIClient!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        api = APIClient(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        api = nil
        super.tearDown()
    }

    func testAnUploadIsRefusedBeforeAnythingIsSent_whenTheDeviceKeyIsNotTheAccountsKey() async {
        TestKeys.install()
        MockURLProtocol.answersPublishedKeyWithStoredKey = false
        MockURLProtocol.route([("/public-key", 200, publishedKeyJSON(makeKeyPair().publicKey, version: 1))])
        let sut = MediaContentService(api: api)

        do {
            _ = try await sut.upload(data: Data("x".utf8), fileName: "a.jpg",
                                     mimeType: "image/jpeg", thumbnailBase64: nil)
            XCTFail("expected staleEncryptionKey")
        } catch MediaContentError.staleEncryptionKey {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(MockURLProtocol.request { $0.url?.path.hasSuffix("/upload") == true },
                     "A photo sealed to a key the account does not publish opens on this device only")
    }

    func testAnUploadIsRefused_whenTheAccountPublishesNoKey() async {
        TestKeys.install()
        MockURLProtocol.answersPublishedKeyWithStoredKey = false
        MockURLProtocol.route([("/public-key", 404, Data())])

        do {
            _ = try await MediaContentService(api: api).upload(data: Data("x".utf8), fileName: "a.jpg",
                                                                mimeType: "image/jpeg", thumbnailBase64: nil)
            XCTFail("expected staleEncryptionKey")
        } catch MediaContentError.staleEncryptionKey {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The Keychain says v1 — what the vault-unlock bug stored — and the account calls the same key
    /// v3. The ref must say 3.
    func testAnUploadFilesItsKeyUnderThePublishedVersion() async throws {
        let stored = TestKeys.install()
        MockURLProtocol.answersPublishedKeyWithStoredKey = false
        MockURLProtocol.route([
            ("/public-key", 200, publishedKeyJSON(stored.publicKey, version: 3)),
            ("/files/upload", 201, uploadResponseJSON(id: "file-3")),
            ("/file-3/key", 204, Data()),
        ])

        _ = try await MediaContentService(api: api).upload(data: Data("x".utf8), fileName: "a.jpg",
                                                            mimeType: "image/jpeg", thumbnailBase64: nil,
                                                            folderID: "renditions")

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/file-3/key", method: "PUT"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["keyVersion"] as? Int, 3)
    }

    /// End to end against a stale device: the photo it sealed to its own key is re-sealed to the
    /// account's key and filed under the account's version; the photo already sealed to the
    /// account's key is not written at all.
    func testRepairReSealsOnlyThePhotosTheDeviceKeyOpens() async throws {
        let device = TestKeys.install()
        let account = makeKeyPair()
        let dek = MediaCrypto.newDEK()
        let mine = try MediaCrypto.seal(dek: dek, toPublicKey: KeyVaultCrypto.decodeBase64URL(device.publicKey)!)
        let theirs = try MediaCrypto.seal(dek: MediaCrypto.newDEK(),
                                          toPublicKey: KeyVaultCrypto.decodeBase64URL(account.publicKey)!)
        func keyJSON(_ sealed: String) -> Data {
            Data(#"{"fileId":"x","userId":"\#(TestTokens.userId)","encryptedFileKey":"\#(sealed)","keyVersion":1}"#.utf8)
        }

        MockURLProtocol.answersPublishedKeyWithStoredKey = false
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let ok = { (status: Int, body: Data) in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
            }
            if path.hasSuffix("/public-key") { return ok(200, publishedKeyJSON(account.publicKey, version: 2)) }
            if path == "/api/v1/drive/files" {
                let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "offset" }?.value ?? "0"
                return ok(200, Data((offset == "0" ? #"{"files":[{"id":"mine"},{"id":"theirs"}]}"# : #"{"files":[]}"#).utf8))
            }
            if path.hasSuffix("/mine/key") { return request.httpMethod == "PUT" ? ok(204, Data()) : ok(200, keyJSON(mine)) }
            if path.hasSuffix("/theirs/key") { return request.httpMethod == "PUT" ? ok(204, Data()) : ok(200, keyJSON(theirs)) }
            return ok(404, Data())
        }

        let sut = DeviceKeyGuard(api: api)
        await sut.checkAndRepair()

        guard case .repaired(let report) = sut.state else { return XCTFail("state is \(sut.state)") }
        XCTAssertEqual(report.rewrapped, 1)
        XCTAssertEqual(report.alreadyCorrect, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertNil(MockURLProtocol.body(forPathContaining: "/theirs/key", method: "PUT"))

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/mine/key", method: "PUT"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["keyVersion"] as? Int, 2)
        let resealed = try XCTUnwrap(json["encryptedFileKey"] as? String)
        XCTAssertEqual(try MediaCrypto.openDEK(resealed,
                                               publicKey: KeyVaultCrypto.decodeBase64URL(account.publicKey)!,
                                               secretKey: KeyVaultCrypto.decodeBase64URL(account.privateKey)!),
                       dek)
        XCTAssertTrue(sut.state.keyMustBeKept == false)
    }

    func testCurrentDeviceKeyRepairsNothing() async {
        TestKeys.install()
        MockURLProtocol.handler = { request in
            XCTFail("a current key needs no other request: \(request.url?.path ?? "")")
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let sut = DeviceKeyGuard(api: api)
        await sut.checkAndRepair()
        XCTAssertEqual(sut.state, .current)
    }
}
