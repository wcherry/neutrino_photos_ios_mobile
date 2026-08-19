import CryptoKit
import Sodium
import XCTest
@testable import NeutrinoPhotos

// MARK: - MediaContentServiceTests

/// The encryption round trip, and the flows built on it: opening an original, opening a preview,
/// uploading one of each, and the cache underneath all four.
///
/// Real libsodium and a real X25519 key pair throughout — see `TestKeys`. A mocked crypto layer
/// would assert nothing about the one part of this app that has to interoperate byte-for-byte with
/// the web client. The caches are real too, in a temporary directory of the test's own, because a
/// cache that is stubbed out cannot be shown to serve a second read.
@MainActor
final class MediaContentServiceTests: XCTestCase {

    private var sut: MediaContentService!
    private var store: LocalStore!
    /// Held strongly: `MediaContentService` keeps only a weak reference, so a service left to the
    /// autorelease pool would silently stop uploading renditions half way through a test.
    private var drive: PhotosDriveService!
    private var originals: DiskCache!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.install()

        let directory = makeTemporaryDirectory()
        let api = APIClient(session: MockURLProtocol.makeSession())
        store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        drive = PhotosDriveService(api: api, store: store)
        originals = DiskCache(directory: directory.appendingPathComponent("originals"),
                              capacityBytes: 8 << 20)
        sut = MediaContentService(
            api: api, store: store, drive: drive, originals: originals,
            thumbnails: ThumbnailCache(disk: DiskCache(
                directory: directory.appendingPathComponent("thumbnails"), capacityBytes: 1 << 20)))
    }

    override func tearDown() {
        sut.clearCache()
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        store = nil
        drive = nil
        originals = nil
        super.tearDown()
    }

    /// A service with the streaming thresholds lowered, so the large-file paths can be exercised
    /// against a few kilobytes rather than by allocating sixty-four megabytes.
    private func makeStreamingService(streamingThreshold: Int64 = 1024,
                                      chunkingThreshold: Int64 = 1024) -> MediaContentService {
        MediaContentService(api: APIClient(session: MockURLProtocol.makeSession()),
                            store: store, drive: nil, originals: originals,
                            thumbnails: ThumbnailCache(disk: originals),
                            streamingThreshold: streamingThreshold,
                            chunkingThreshold: chunkingThreshold)
    }

    // MARK: - Crypto
    //
    // The primitives themselves are `MediaCryptoTests`' business. What is asserted here is the part
    // this service owns: which key pair a DEK is sealed to, and what happens when there isn't one.

    func testSealedKeyRoundTripsThroughTheStoredKeyPair() throws {
        let dek = MediaCrypto.newDEK()

        let sealed = try sut.sealDEK(dek)
        XCTAssertEqual(try sut.unsealDEK(sealed), dek)
    }

    func testSealingWithoutAKeyIsRefused() {
        TestKeys.remove()

        XCTAssertThrowsError(try sut.sealDEK(MediaCrypto.newDEK())) { error in
            XCTAssertEqual((error as? MediaContentError)?.errorDescription,
                           MediaContentError.noEncryptionKey.errorDescription)
        }
    }

    // MARK: - Reading

    func testOriginalDataDownloadsUnsealsAndDecrypts() async throws {
        let dek = MediaCrypto.newDEK()
        let original = Data("a photograph, more or less".utf8)
        let ciphertext = try MediaCrypto.encrypt(Bytes(original), dek: dek)
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
        let sealed = try sut.sealDEK(MediaCrypto.newDEK())
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

    // MARK: - Exit criteria

    /// **The epic's exit criterion.** SHA-256 of a downloaded original equals the SHA-256 of what
    /// was uploaded.
    ///
    /// Asserted through both real paths rather than by round-tripping the crypto on its own: the
    /// bytes go out through the multipart upload, are pulled back out of the captured request body
    /// exactly as the server would store them, are served back through the download path, and are
    /// hashed at the far end. A test that encrypted and decrypted in place would pass with a
    /// mangled multipart body, which is the failure this is for.
    func testAnUploadedOriginalComesBackByteIdentical() async throws {
        let original = TestImages.jpeg(size: 1200)
        MockURLProtocol.route([
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-x").utf8)),
            ("/key", 204, Data()),
        ])

        let fileID = try await sut.upload(data: original, fileName: "IMG_1.jpg",
                                          mimeType: "image/jpeg", thumbnailBase64: nil)

        // What the server would have stored, and the key it was told to store beside it.
        let storedCiphertext = try Self.filePart(fromUploadOf: "/files/upload")
        let sealedKey = try Self.sealedFileKeyFromKeyRequest()

        // A second service, so nothing can be served out of the first one's cache.
        let reader = makeStreamingService(streamingThreshold: .max)
        MockURLProtocol.reset()
        MockURLProtocol.route([
            ("/key", 200, Data(#"{"encrypted_file_key":"\#(sealedKey)"}"#.utf8)),
            ("/drive/files/", 200, storedCiphertext),
        ])

        let item = Fixture.item(fileID: fileID, sizeBytes: Int64(original.count))
        let downloaded = try await reader.originalData(for: item)

        XCTAssertEqual(SHA256.hash(data: downloaded), SHA256.hash(data: original))
        XCTAssertEqual(downloaded.count, original.count)
    }

    // MARK: - Cache

    func testAPhotographJustUploadedOpensWithoutBeingDownloadedAgain() async throws {
        // The bytes are already on the device; fetching them back from the server to look at the
        // picture that was just imported would be the most avoidable download in the app.
        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-fresh").utf8)),
        ])
        let original = TestImages.jpeg(size: 300)

        let fileID = try await sut.upload(data: original, fileName: "IMG_9.jpg",
                                          mimeType: "image/jpeg", thumbnailBase64: nil)
        MockURLProtocol.reset()

        // No routes at all: any request now fails the test rather than quietly succeeding.
        let opened = try await sut.originalData(for: Fixture.item(fileID: fileID,
                                                                  fileName: "IMG_9.jpg"))

        XCTAssertEqual(opened, original)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testASecondReadIsServedFromDiskWithoutTouchingTheNetwork() async throws {
        let plaintext = Data("cached photograph".utf8)
        MockURLProtocol.route([
            ("/key", 404, Data()),
            ("/drive/files/", 200, plaintext),
        ])
        let item = Fixture.item(fileID: "file-cached")

        _ = try await sut.originalData(for: item)
        let afterFirstRead = MockURLProtocol.requestCount
        let second = try await sut.originalData(for: item)

        XCTAssertEqual(second, plaintext)
        XCTAssertEqual(MockURLProtocol.requestCount, afterFirstRead,
                       "the second open of a photograph should cost nothing")
    }

    func testClearCacheRemovesDecryptedMedia() async throws {
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

    func testTheStorageBreakdownCountsEachCacheSeparately() async throws {
        MockURLProtocol.route([
            ("/key", 404, Data()),
            ("/drive/files/", 200, Data(repeating: 9, count: 4096)),
        ])
        _ = try await sut.originalData(for: Fixture.item(fileID: "file-s"))
        try await store.replaceLibrary(with: [Fixture.item()])

        let breakdown = await sut.storageBreakdown()

        XCTAssertGreaterThanOrEqual(breakdown.originals, 4096)
        XCTAssertGreaterThan(breakdown.database, 0)
        XCTAssertEqual(breakdown.total,
                       breakdown.originals + breakdown.thumbnails + breakdown.database)
    }

    // MARK: - Previews

    func testThePreviewRenditionIsUsedWhenTheDeviceKnowsOfOne() async throws {
        // The point of the whole ladder: opening a photograph should fetch about a tenth of it.
        let previewBytes = TestImages.jpeg(size: 256)
        let dek = MediaCrypto.newDEK()
        let sealed = try sut.sealDEK(dek)
        try await store.setRenditionFileID("rendition-1", forFile: "file-p", rendition: .preview)

        MockURLProtocol.route([
            ("/rendition-1/key", 200, Data(#"{"encrypted_file_key":"\#(sealed)"}"#.utf8)),
            ("/drive/files/rendition-1", 200, try MediaCrypto.encrypt(Bytes(previewBytes), dek: dek)),
        ])

        let data = try await sut.previewData(for: Fixture.item(fileID: "file-p"))

        XCTAssertEqual(data, previewBytes)
        XCTAssertNil(MockURLProtocol.request { $0.url?.path.hasSuffix("/drive/files/file-p") == true },
                     "the original must not be downloaded when a preview rendition exists")
    }

    func testThePreviewFallsBackToTheOriginalWhenThereIsNoRendition() async throws {
        // Every photograph uploaded before renditions existed lands here, so the fallback is the
        // normal case rather than an error path.
        let original = TestImages.jpeg(size: 4000)
        MockURLProtocol.route([
            ("/key", 404, Data()),
            ("/drive/files/", 200, original),
        ])

        let preview = try await sut.previewData(for: Fixture.item(fileID: "file-no-rendition"))

        XCTAssertLessThan(preview.count, original.count)
        XCTAssertGreaterThan(preview.count, 0)
    }

    func testAPictureAlreadySmallerThanAPreviewIsServedAsItIs() async throws {
        // Re-encoding it would spend disk and quality to save nothing.
        let original = TestImages.jpeg(size: 300)
        MockURLProtocol.route([
            ("/key", 404, Data()),
            ("/drive/files/", 200, original),
        ])

        let preview = try await sut.previewData(for: Fixture.item(fileID: "file-small"))

        XCTAssertEqual(preview, original)
    }

    func testAnUnreadableRenditionFallsBackRatherThanFailing() async throws {
        // A rendition is derived data. One that has been deleted in Drive, or whose key is gone,
        // must not be the reason a photograph cannot be opened.
        try await store.setRenditionFileID("missing", forFile: "file-q", rendition: .preview)
        let original = TestImages.jpeg(size: 800)
        MockURLProtocol.route([
            ("/drive/files/missing", 404, Data()),
            ("/key", 404, Data()),
            ("/drive/files/", 200, original),
        ])

        let preview = try await sut.previewData(for: Fixture.item(fileID: "file-q"))

        XCTAssertGreaterThan(preview.count, 0)
    }

    // MARK: - Writing

    func testUploadSendsEncryptedBytesAndThenStoresTheKey() async throws {
        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-new").utf8)),
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

    func testAPhotographIsFiledInTheDriveRootAndARenditionIsNot() async throws {
        // The web app's library listing is root-scoped, so a photograph in a tidy subfolder is a
        // photograph the web app cannot see — and a rendition in the root is one it shows as a
        // duplicate. The `folder_id` field is what separates them.
        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-new").utf8)),
        ])

        _ = try await sut.upload(data: Data("bytes".utf8), fileName: "a.jpg",
                                  mimeType: "image/jpeg", thumbnailBase64: nil)
        let rootBody = String(decoding: try XCTUnwrap(
            MockURLProtocol.body(forPathContaining: "/files/upload")), as: UTF8.self)
        XCTAssertFalse(rootBody.contains("name=\"folder_id\""))

        MockURLProtocol.reset()
        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "rendition").utf8)),
        ])
        _ = try await sut.upload(data: Data("bytes".utf8), fileName: "a.preview.jpg",
                                  mimeType: "image/jpeg", thumbnailBase64: nil,
                                  folderID: "renditions")
        let filedBody = String(decoding: try XCTUnwrap(
            MockURLProtocol.body(forPathContaining: "/files/upload")), as: UTF8.self)
        XCTAssertTrue(filedBody.contains("name=\"folder_id\""))
        XCTAssertTrue(filedBody.contains("renditions"))
    }

    // MARK: - Renditions on upload

    func testUploadingAPictureAlsoUploadsItsPreviewRendition() async throws {
        MockURLProtocol.route([
            ("/drive/folders", 200, Data(#"{"folder":null,"folders":[],"files":[]}"#.utf8)),
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-orig").utf8)),
        ])
        // The folder listing above is empty, so the folder is created — and the create response is
        // routed by the same fragment, which is why the rendition upload needs its own routing.
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let body: Data
            switch (request.httpMethod, path) {
            case ("POST", "/api/v1/drive/folders"):
                body = Data(#"{"id":"renditions-folder","name":"Photo Previews","parentId":null}"#.utf8)
            case ("GET", _) where path.hasPrefix("/api/v1/drive/folders"):
                body = Data(#"{"folder":null,"folders":[],"files":[]}"#.utf8)
            case ("POST", "/api/v1/drive/files/upload"):
                // Two uploads land here: the original first, then its rendition.
                let already = MockURLProtocol.requests.filter {
                    $0.url?.path == "/api/v1/drive/files/upload"
                }.count
                body = Data(Self.uploadResponseJSON(
                    id: already > 1 ? "file-rendition" : "file-orig").utf8)
            default:
                body = Data("{}".utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!, body)
        }

        let fileID = try await sut.upload(data: TestImages.jpeg(size: 4000),
                                           fileName: "IMG_1.jpg", mimeType: "image/jpeg",
                                           thumbnailBase64: nil)

        let mapped = await store.renditionFileID(forFile: "file-orig", rendition: .preview)
        XCTAssertEqual(fileID, "file-orig")
        XCTAssertEqual(mapped, "file-rendition",
                       "the uploading device knows the mapping immediately; every other one has to "
                       + "read it out of the folder listing")
        let uploads = MockURLProtocol.requests.filter { $0.url?.path == "/api/v1/drive/files/upload" }
        XCTAssertEqual(uploads.count, 2)
    }

    func testNoRenditionIsUploadedForAVideo() async throws {
        // There is no frame to render until Epic 8 can decode one.
        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-v").utf8)),
        ])

        _ = try await sut.upload(data: Data("MOOV atom, honestly".utf8), fileName: "clip.mov",
                                  mimeType: "video/quicktime", thumbnailBase64: nil)

        let uploads = MockURLProtocol.requests.filter { $0.url?.path == "/api/v1/drive/files/upload" }
        XCTAssertEqual(uploads.count, 1)
    }

    func testAFailedRenditionUploadDoesNotFailTheImport() async throws {
        // The original is safe by the time the rendition runs. Refusing an import because a
        // *preview* would not upload trades the thing that matters for the thing that does not.
        var uploadCount = 0
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/v1/drive/files/upload" {
                uploadCount += 1
                if uploadCount > 1 {
                    return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil,
                                            headerFields: nil)!, Data())
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                        headerFields: nil)!,
                        Data(Self.uploadResponseJSON(id: "file-orig").utf8))
            }
            if request.httpMethod == "POST", path == "/api/v1/drive/folders" {
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                        headerFields: nil)!,
                        Data(#"{"id":"f","name":"Photo Previews","parentId":null}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: nil)!,
                    Data(#"{"folder":null,"folders":[],"files":[]}"#.utf8))
        }

        let fileID = try await sut.upload(data: TestImages.jpeg(size: 4000), fileName: "IMG_1.jpg",
                                           mimeType: "image/jpeg", thumbnailBase64: nil)

        let mapped = await store.renditionFileID(forFile: "file-orig", rendition: .preview)
        XCTAssertEqual(fileID, "file-orig")
        XCTAssertNil(mapped)
    }

    // MARK: - Streaming

    func testALargeUploadIsChunkedAndSaysSoInItsMetadata() async throws {
        // The framing cannot be inferred from the ciphertext, so a chunked file whose metadata
        // forgot to say `chunkSize` is a file nothing can ever read back.
        let streaming = makeStreamingService()
        let source = makeTemporaryDirectory().appendingPathComponent("clip.mov")
        let plaintext = Data(repeating: 0xAB, count: 5000)
        try plaintext.write(to: source)

        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-big").utf8)),
        ])

        _ = try await streaming.upload(fileURL: source, fileName: "clip.mov",
                                        mimeType: "video/quicktime", thumbnailBase64: nil)

        let sealedKey = try Self.sealedFileKeyFromKeyRequest()
        let dek = try sut.unsealDEK(sealedKey)
        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/files/upload"))
        let encodedMetadata = try Self.field("encrypted_metadata", in: body)
        let metadata = try MediaCrypto.decryptMetadata(encodedMetadata, dek: dek)

        XCTAssertEqual(metadata.name, "clip.mov")
        XCTAssertEqual(metadata.mimeType, "video/quicktime")
        XCTAssertEqual(metadata.chunkSize, MediaCrypto.defaultChunkSize)
    }

    func testALargeOriginalIsDownloadedStreamedAndDecryptedByteForByte() async throws {
        let streaming = makeStreamingService()
        let source = makeTemporaryDirectory().appendingPathComponent("clip.mov")
        // Several chunks' worth, at a chunk size a test can afford.
        let plaintext = Data((0..<40_000).map { UInt8($0 % 251) })
        try plaintext.write(to: source)

        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-big").utf8)),
        ])
        _ = try await streaming.upload(fileURL: source, fileName: "clip.mov",
                                        mimeType: "video/quicktime", thumbnailBase64: nil,
                                        onProgress: nil)

        let ciphertext = try Self.filePart(fromUploadOf: "/files/upload")
        let sealedKey = try Self.sealedFileKeyFromKeyRequest()
        let encryptedMetadata = try Self.field("encrypted_metadata",
                                               in: try XCTUnwrap(MockURLProtocol.body(
                                                   forPathContaining: "/files/upload")))

        MockURLProtocol.reset()
        MockURLProtocol.route([
            ("/metadata", 200, Data("""
             {"id":"file-big","name":"clip.mov","sizeBytes":\(plaintext.count),
              "mimeType":"video/quicktime","folderId":null,"isStarred":false,
              "createdAt":"2026-08-01T10:00:00","updatedAt":"2026-08-01T10:00:00",
              "coverThumbnail":null,"coverThumbnailMimeType":null,
              "encryptedMetadata":"\(encryptedMetadata)","contentVersion":1}
             """.utf8)),
            ("/key", 200, Data(#"{"encrypted_file_key":"\#(sealedKey)"}"#.utf8)),
            ("/drive/files/", 200, ciphertext),
        ])

        let reader = makeStreamingService()
        let item = Fixture.item(fileID: "file-big", fileName: "clip.mov",
                                mimeType: "video/quicktime", sizeBytes: Int64(plaintext.count))
        let url = try await reader.localURL(for: item)

        XCTAssertEqual(try Data(contentsOf: url), plaintext)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)),
                       SHA256.hash(data: plaintext))
    }

    func testASmallFileUploadedFromDiskStaysInTheFormatTheWebClientReads() async throws {
        // Below the chunking threshold there is no `chunkSize` at all — which is what keeps the
        // metadata blob exactly the shape the web client writes and reads.
        let streaming = makeStreamingService(streamingThreshold: 1024, chunkingThreshold: 1 << 30)
        let source = makeTemporaryDirectory().appendingPathComponent("small.jpg")
        try TestImages.jpeg(size: 200).write(to: source)

        MockURLProtocol.route([
            ("/key", 204, Data()),
            ("/files/upload", 201, Data(Self.uploadResponseJSON(id: "file-s").utf8)),
        ])
        _ = try await streaming.upload(fileURL: source, fileName: "small.jpg",
                                        mimeType: "image/jpeg", thumbnailBase64: nil)

        let sealedKey = try Self.sealedFileKeyFromKeyRequest()
        let dek = try sut.unsealDEK(sealedKey)
        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/files/upload"))
        let metadata = try MediaCrypto.decryptMetadata(try Self.field("encrypted_metadata", in: body),
                                                       dek: dek)

        XCTAssertNil(metadata.chunkSize)
        // And the ciphertext really is single-push: the one-shot decryptor reads it.
        let ciphertext = try Self.filePart(fromUploadOf: "/files/upload")
        XCTAssertEqual(Data(try MediaCrypto.decrypt(ciphertext, dek: dek)),
                       try Data(contentsOf: source))
    }

    // MARK: - Multipart inspection
    //
    // Pulling the parts back out of a captured request body, so a test can assert on what the
    // *server* would have stored rather than on what the client believed it sent.

    private static func uploadResponseJSON(id: String) -> String {
        #"{"id":"\#(id)","name":"IMG_1.jpg","sizeBytes":12,"mimeType":"image/jpeg"}"#
    }

    /// The bytes of the `file` part of the captured upload — the ciphertext, exactly as stored.
    private static func filePart(fromUploadOf fragment: String) throws -> Data {
        let request = try XCTUnwrap(MockURLProtocol.request {
            ($0.url?.path ?? "").contains(fragment)
        })
        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: fragment))
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)

        let filenameMarker = try XCTUnwrap(body.range(of: Data("filename=\"".utf8)))
        let headerEnd = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8),
                                                 in: filenameMarker.upperBound..<body.endIndex))
        let closing = try XCTUnwrap(body.range(of: Data("\r\n--\(boundary)--".utf8),
                                               options: .backwards))
        return body[headerEnd.upperBound..<closing.lowerBound]
    }

    /// The value of a scalar multipart field.
    private static func field(_ name: String, in body: Data) throws -> String {
        let text = String(decoding: body, as: UTF8.self)
        let marker = "name=\"\(name)\"\r\n\r\n"
        let start = try XCTUnwrap(text.range(of: marker)).upperBound
        let end = try XCTUnwrap(text.range(of: "\r\n", range: start..<text.endIndex)).lowerBound
        return String(text[start..<end])
    }

    /// The sealed file key the client sent in its `PUT …/key` request.
    private static func sealedFileKeyFromKeyRequest() throws -> String {
        let index = try XCTUnwrap(MockURLProtocol.requests.firstIndex {
            $0.httpMethod == "PUT" && ($0.url?.path ?? "").hasSuffix("/key")
        })
        let body = MockURLProtocol.bodies[index]
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        return try XCTUnwrap(json["encryptedFileKey"])
    }
}
