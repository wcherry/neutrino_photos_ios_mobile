import Sodium
import XCTest
@testable import NeutrinoPhotos

// MARK: - MediaContentServiceTests

/// The encryption round trip, and the two flows built on it: opening an original and uploading one.
///
/// Real libsodium and a real X25519 key pair throughout — see `TestKeys`. A mocked crypto layer
/// would assert nothing about the one part of this app that has to interoperate byte-for-byte with
/// the web client.
@MainActor
final class MediaContentServiceTests: XCTestCase {

    private var sut: MediaContentService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()
        sut = MediaContentService(api: APIClient(session: MockURLProtocol.makeSession()))
    }

    override func tearDown() {
        sut.clearCache()
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    // MARK: - Crypto

    func testEncryptDecryptRoundTrip() throws {
        let sodium = Sodium()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()
        let original = Data((0..<4096).map { UInt8($0 % 251) })

        let ciphertext = try sut.encrypt(bytes: Array(original), dek: dek, xcss: xcss)
        let plaintext = Data(try sut.decryptToBytes(data: ciphertext, dek: dek))

        XCTAssertEqual(plaintext, original)
        XCTAssertEqual(ciphertext.count, original.count + 24 + 17,
                       "24-byte secretstream header plus the 17-byte tag+MAC the push adds")
    }

    func testDecryptWithTheWrongKeyFails() throws {
        let sodium = Sodium()
        let xcss = sodium.secretStream.xchacha20poly1305
        let ciphertext = try sut.encrypt(bytes: Array("hello".utf8), dek: xcss.key(), xcss: xcss)

        XCTAssertThrowsError(try sut.decryptToBytes(data: ciphertext, dek: xcss.key()))
    }

    func testSealedKeyRoundTripsThroughTheStoredKeyPair() throws {
        let sodium = Sodium()
        let dek = sodium.secretStream.xchacha20poly1305.key()

        let sealed = try sut.sealDEK(dek)
        XCTAssertEqual(try sut.unsealDEK(sealed), dek)
    }

    func testSealingWithoutAKeyIsRefused() {
        TestKeys.remove()
        let dek = Sodium().secretStream.xchacha20poly1305.key()

        XCTAssertThrowsError(try sut.sealDEK(dek)) { error in
            XCTAssertEqual((error as? MediaContentError)?.errorDescription,
                           MediaContentError.noEncryptionKey.errorDescription)
        }
    }

    // MARK: - Reading

    func testOriginalDataDownloadsUnsealsAndDecrypts() async throws {
        let sodium = Sodium()
        let xcss = sodium.secretStream.xchacha20poly1305
        let dek = xcss.key()
        let original = Data("a photograph, more or less".utf8)
        let ciphertext = try sut.encrypt(bytes: Array(original), dek: dek, xcss: xcss)
        let sealed = try sut.sealDEK(dek)

        MockURLProtocol.route([
            ("/key", 200, Data(#"{"encrypted_file_key":"\#(sealed)"}"#.utf8)),
            ("/drive/files/", 200, ciphertext),
        ])

        let item = Fixture.item(fileID: "file-a")
        let downloaded = try await sut.originalData(for: item)
        XCTAssertEqual(downloaded, original)
    }

    func testAFileWithNoKeyRefIsReturnedAsItStands() async throws {
        // A picture uploaded before E2EE, or by something that never sealed a key: the download
        // already *is* the image, and the web app's resolver makes the same allowance.
        let plaintext = Data("not encrypted".utf8)
        MockURLProtocol.route([
            ("/key", 404, Data()),
            ("/drive/files/", 200, plaintext),
        ])

        let downloaded = try await sut.originalData(for: Fixture.item())
        XCTAssertEqual(downloaded, plaintext)
    }

    func testOpeningAnOriginalWithoutTheKeyPairFails() async throws {
        let sealed = try sut.sealDEK(Sodium().secretStream.xchacha20poly1305.key())
        TestKeys.remove()
        MockURLProtocol.route([
            ("/key", 200, Data(#"{"encrypted_file_key":"\#(sealed)"}"#.utf8)),
            ("/drive/files/", 200, Data(repeating: 7, count: 128)),
        ])

        do {
            _ = try await sut.originalData(for: Fixture.item())
            XCTFail("expected the missing key pair to be reported")
        } catch {
            XCTAssertEqual((error as? MediaContentError)?.errorDescription,
                           MediaContentError.noEncryptionKey.errorDescription)
        }
    }

    // MARK: - Writing

    func testUploadSendsEncryptedBytesAndThenStoresTheKey() async throws {
        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data("""
            {"id":"file-new","name":"IMG_1.jpg","sizeBytes":12,"mimeType":"image/jpeg"}
            """.utf8)),
        ])

        let original = Data("pretend JPEG".utf8)
        let fileID = try await sut.upload(data: original, fileName: "IMG_1.jpg",
                                          mimeType: "image/jpeg", thumbnailBase64: "dGh1bWI=")

        XCTAssertEqual(fileID, "file-new")

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/files/upload"))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"encrypted_metadata\""))
        XCTAssertTrue(text.contains("name=\"thumbnail_b64\""))
        XCTAssertTrue(text.contains("filename=\"IMG_1.jpg\""))
        // The server reads the multipart stream in order and stops at the file part, so a field
        // written after the bytes is one it never sees.
        let thumbnailIndex = try XCTUnwrap(text.range(of: "name=\"thumbnail_b64\"")).lowerBound
        let fileIndex = try XCTUnwrap(text.range(of: "name=\"file\"")).lowerBound
        XCTAssertLessThan(thumbnailIndex, fileIndex)

        XCTAssertFalse(body.range(of: original) != nil,
                       "the plaintext must never appear in the request body")

        let keyRequest = MockURLProtocol.request { $0.url?.path.hasSuffix("/key") == true }
        XCTAssertEqual(keyRequest?.httpMethod, "PUT")
    }

    func testUploadWithoutAKeyPairNeverSendsAnything() async {
        TestKeys.remove()

        do {
            _ = try await sut.upload(data: Data("x".utf8), fileName: "a.jpg",
                                      mimeType: "image/jpeg", thumbnailBase64: nil)
            XCTFail("expected the upload to be refused")
        } catch {
            // Bytes that cannot be sealed to anybody are bytes nobody could ever decrypt; not
            // uploading them is the only correct outcome.
            XCTAssertEqual(MockURLProtocol.requestCount, 0)
        }
    }

    // MARK: - Cache

    func testClearCacheRemovesDecryptedVideos() async throws {
        let plaintext = Data("a video, allegedly".utf8)
        MockURLProtocol.route([
            ("/key", 404, Data()),
            ("/drive/files/", 200, plaintext),
        ])
        let item = Fixture.item(fileID: "file-v", fileName: "clip.mov", mimeType: "video/quicktime")

        let url = try await sut.localURL(for: item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "mov", "AVPlayer picks its demuxer from the extension")
        XCTAssertGreaterThan(sut.cacheSizeOnDisk(), 0)

        sut.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(sut.cacheSizeOnDisk(), 0)
    }
}
