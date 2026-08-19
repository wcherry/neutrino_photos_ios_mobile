import XCTest
@testable import NeutrinoPhotos

// MARK: - PhotosDriveServiceTests

/// Drive as the photo library sees it: the `type=photo` listing, the renditions folder, and the
/// reconciliation between files and photo records.
///
/// Real HTTP through `MockURLProtocol` — the request URLs are half of what is under test here,
/// because a listing scoped to the wrong folder returns a perfectly well-formed empty array.
@MainActor
final class PhotosDriveServiceTests: XCTestCase {

    private var sut: PhotosDriveService!
    private var store: LocalStore!

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        store = try LocalStore(url: makeTemporaryDirectory().appendingPathComponent("t.sqlite"))
        sut = PhotosDriveService(api: APIClient(session: MockURLProtocol.makeSession()), store: store)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        sut = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Listing

    func testListsTheDriveRootScopedToPhotos() async throws {
        MockURLProtocol.respond(json: Self.folderJSON(files: [Self.fileJSON(id: "file-1")]))

        let files = try await sut.photoFiles()

        XCTAssertEqual(files.map(\.id), ["file-1"])
        let request = try XCTUnwrap(MockURLProtocol.request { _ in true })
        // The root folder has no id of its own: the route's documented sentinel is the caller's own
        // user id, which is why this reads the token's `sub` claim.
        XCTAssertEqual(request.url?.path, "/api/v1/drive/folders/\(TestTokens.userId)")
        let query = try XCTUnwrap(request.url?.query)
        XCTAssertTrue(query.contains("type=photo"), "an unscoped listing is every file in the drive")
    }

    func testListsVideosSeparatelyBecauseTheFilterTakesOneTypeAtATime() async throws {
        MockURLProtocol.respond(json: Self.folderJSON(files: []))

        _ = try await sut.videoFiles()

        let request = try XCTUnwrap(MockURLProtocol.request { _ in true })
        XCTAssertTrue(try XCTUnwrap(request.url?.query).contains("type=video"))
    }

    func testDecodesTheFieldsAStreamingDownloadNeeds() async throws {
        MockURLProtocol.respond(json: Self.fileJSON(id: "file-1", encryptedMetadata: "c2VhbGVk"))

        let file = try await sut.file(id: "file-1")

        XCTAssertEqual(file.id, "file-1")
        XCTAssertEqual(file.mimeType, "image/jpeg")
        XCTAssertEqual(file.encryptedMetadata, "c2VhbGVk",
                       "the chunk framing lives in here; without it a large file cannot be decrypted")
        let request = try XCTUnwrap(MockURLProtocol.request { _ in true })
        XCTAssertEqual(request.url?.path, "/api/v1/drive/files/file-1/metadata")
    }

    func testAMissingFileIsAFactRatherThanAFailure() async throws {
        MockURLProtocol.respond(json: "{}", statusCode: 404)

        let file = try await sut.fileIfPresent(id: "gone")

        XCTAssertNil(file)
    }

    // MARK: - Reconciliation

    func testFindsDriveImagesTheLibraryHasNoRecordOf() async throws {
        // An upload that stored its bytes and then lost the network before registering them. The
        // bytes are already paid for, which is what makes this worth finding rather than re-uploading.
        MockURLProtocol.respond(json: Self.folderJSON(files: [
            Self.fileJSON(id: "registered"),
            Self.fileJSON(id: "orphan"),
        ]))

        let unregistered = try await sut.unregisteredPhotoFiles(knownFileIDs: ["registered"])

        XCTAssertEqual(unregistered.map(\.id), ["orphan"])
    }

    // MARK: - Quota

    func testReadsTheAccountQuota() async {
        MockURLProtocol.respond(json: """
        {"used_bytes":1073741824,"daily_upload_bytes":0,"quota_bytes":16106127360,"daily_cap_bytes":null}
        """)

        await sut.loadQuota()

        XCTAssertEqual(sut.quota?.usedBytes, 1_073_741_824)
        XCTAssertEqual(sut.quota?.quotaBytes, 16_106_127_360)
        XCTAssertTrue(sut.quota?.formattedUsage.contains(" of ") == true)
    }

    func testAnUnlimitedAccountIsNotRenderedAsZero() {
        let quota = DriveQuota(usedBytes: 100, quotaBytes: nil, dailyUploadBytes: 0,
                               dailyCapBytes: nil)

        XCTAssertFalse(quota.formattedUsage.contains(" of "))
    }

    func testAFailedQuotaReadLeavesTheLastKnownNumberAlone() async {
        MockURLProtocol.respond(json: """
        {"used_bytes":10,"daily_upload_bytes":0,"quota_bytes":null,"daily_cap_bytes":null}
        """)
        await sut.loadQuota()

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        await sut.loadQuota()

        XCTAssertEqual(sut.quota?.usedBytes, 10, "a stale number beats a blank one")
    }

    // MARK: - Renditions folder

    func testFindsAnExistingRenditionsFolderByName() async throws {
        MockURLProtocol.respond(json: Self.folderJSON(folders: [
            Self.folderEntryJSON(id: "other", name: "Holiday"),
            Self.folderEntryJSON(id: "renditions",
                                 name: PhotosDriveService.renditionsFolderName),
        ]))

        let folderID = try await sut.renditionsFolderID()

        XCTAssertEqual(folderID, "renditions")
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "found, not created")
    }

    func testCreatesTheRenditionsFolderWhenThereIsNone() async throws {
        MockURLProtocol.route([
            ("/drive/folders/\(TestTokens.userId)", 200, Data(Self.folderJSON().utf8)),
            ("/drive/folders", 201, Data(Self.folderEntryJSON(id: "made",
                                                              name: PhotosDriveService.renditionsFolderName).utf8)),
        ])

        let folderID = try await sut.renditionsFolderID()

        XCTAssertEqual(folderID, "made")
        let create = MockURLProtocol.request { $0.httpMethod == "POST" }
        XCTAssertEqual(create?.url?.path, "/api/v1/drive/folders")
    }

    func testDoesNotCreateAFolderWhenTheCallerOnlyWantedToLook() async throws {
        MockURLProtocol.respond(json: Self.folderJSON())

        let folderID = try await sut.renditionsFolderID(creatingIfNeeded: false)

        XCTAssertNil(folderID)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testTheFolderIDIsRememberedSoAnUploadDoesNotPayForTheListing() async throws {
        MockURLProtocol.respond(json: Self.folderJSON(folders: [
            Self.folderEntryJSON(id: "renditions", name: PhotosDriveService.renditionsFolderName),
        ]))
        _ = try await sut.renditionsFolderID()
        let afterFirst = MockURLProtocol.requestCount

        _ = try await sut.renditionsFolderID()

        let remembered = await store.string(forKey: LocalStore.MetaKey.renditionsFolderID)
        XCTAssertEqual(MockURLProtocol.requestCount, afterFirst)
        XCTAssertEqual(remembered, "renditions",
                       "and remembered across launches, not just within one")
    }

    // MARK: - Live Photos folder

    func testTheLivePhotosFolderIsResolvedAndRememberedSeparately() async throws {
        MockURLProtocol.respond(json: Self.folderJSON(folders: [
            Self.folderEntryJSON(id: "renditions", name: PhotosDriveService.renditionsFolderName),
            Self.folderEntryJSON(id: "live", name: PhotosDriveService.livePhotosFolderName),
        ]))

        let renditions = try await sut.renditionsFolderID()
        let livePhotos = try await sut.livePhotosFolderID()

        // Two folders, cached under two keys. Sharing one cache slot would hand a preview upload
        // the Live Photos folder — and file every rendition where nothing ever looks for one.
        XCTAssertEqual(renditions, "renditions")
        XCTAssertEqual(livePhotos, "live")
        let remembered = await store.string(forKey: LocalStore.MetaKey.livePhotosFolderID)
        XCTAssertEqual(remembered, "live")
    }

    func testCreatesTheLivePhotosFolderWhenThereIsNone() async throws {
        MockURLProtocol.route([
            ("/drive/folders/\(TestTokens.userId)", 200, Data(Self.folderJSON().utf8)),
            ("/drive/folders", 201, Data(Self.folderEntryJSON(
                id: "made", name: PhotosDriveService.livePhotosFolderName).utf8)),
        ])

        let folderID = try await sut.livePhotosFolderID()

        XCTAssertEqual(folderID, "made")
        // By method rather than by path: the listing that found nothing and the create that
        // followed it are the same path, and the first one has no body at all.
        let create = try XCTUnwrap(MockURLProtocol.requests.firstIndex { $0.httpMethod == "POST" })
        XCTAssertTrue(String(decoding: MockURLProtocol.bodies[create], as: UTF8.self)
            .contains(PhotosDriveService.livePhotosFolderName))
    }

    // MARK: - Rendition index

    func testBuildsTheRenditionIndexFromTheFileNames() async throws {
        // Nothing on a photo record can point at a rendition, so the *name* is the index. A device
        // that did not perform the upload learns the mapping here and nowhere else.
        MockURLProtocol.route([
            ("/drive/folders/\(TestTokens.userId)", 200, Data(Self.folderJSON(folders: [
                Self.folderEntryJSON(id: "renditions",
                                     name: PhotosDriveService.renditionsFolderName),
            ]).utf8)),
            ("/drive/folders/renditions", 200, Data(Self.folderJSON(files: [
                Self.fileJSON(id: "r1", name: "file-1.preview.jpg"),
                Self.fileJSON(id: "r2", name: "file-2.preview.jpg"),
                Self.fileJSON(id: "x", name: "somebody-elses-picture.jpg"),
            ]).utf8)),
        ])

        let index = await sut.refreshRenditionIndex()

        let stored = await store.renditionFileID(forFile: "file-1", rendition: .preview)
        let notARendition = await store.renditionFileID(forFile: "x", rendition: .preview)
        XCTAssertEqual(index, ["file-1": "r1", "file-2": "r2"])
        XCTAssertEqual(stored, "r1")
        XCTAssertNil(notARendition)
    }

    func testAnAccountWithNoRenditionsFolderIndexesNothingAndCreatesNothing() async {
        MockURLProtocol.respond(json: Self.folderJSON())

        let index = await sut.refreshRenditionIndex()

        XCTAssertTrue(index.isEmpty)
        XCTAssertNil(MockURLProtocol.request { $0.httpMethod == "POST" },
                     "reading an index must not have the side effect of making a folder")
    }

    func testAFailedIndexRefreshIsSurvivable() async {
        // The index is an accelerator: every read falls back to the original, so losing it costs
        // bandwidth rather than photographs.
        MockURLProtocol.respond(json: "{}", statusCode: 500)

        let index = await sut.refreshRenditionIndex()

        XCTAssertTrue(index.isEmpty)
    }

    // MARK: - Mutation

    func testRenamesAFile() async throws {
        MockURLProtocol.respond(json: Self.fileJSON(id: "file-1", name: "Renamed.jpg"))

        let file = try await sut.rename(fileID: "file-1", to: "Renamed.jpg")

        XCTAssertEqual(file.name, "Renamed.jpg")
        let request = try XCTUnwrap(MockURLProtocol.request { $0.httpMethod == "PATCH" })
        XCTAssertEqual(request.url?.path, "/api/v1/drive/files/file-1")
    }

    func testDeletesAFile() async throws {
        MockURLProtocol.respond(json: "{}", statusCode: 204)

        try await sut.delete(fileID: "orphan")

        let request = try XCTUnwrap(MockURLProtocol.request { $0.httpMethod == "DELETE" })
        XCTAssertEqual(request.url?.path, "/api/v1/drive/files/orphan")
    }

    // MARK: - Fixtures

    private static func fileJSON(id: String, name: String = "IMG_0001.jpg",
                                 encryptedMetadata: String? = nil) -> String {
        let metadata = encryptedMetadata.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","name":"\(name)","sizeBytes":1234,"mimeType":"image/jpeg","folderId":null,
         "isStarred":false,"createdAt":"2026-08-01T10:00:00","updatedAt":"2026-08-01T10:00:00",
         "coverThumbnail":null,"coverThumbnailMimeType":null,"encryptedMetadata":\(metadata),
         "contentVersion":1}
        """
    }

    private static func folderEntryJSON(id: String, name: String) -> String {
        """
        {"id":"\(id)","name":"\(name)","parentId":null,"color":null,"isStarred":false,
         "createdAt":"2026-08-01T10:00:00","updatedAt":"2026-08-01T10:00:00"}
        """
    }

    private static func folderJSON(folders: [String] = [], files: [String] = []) -> String {
        """
        {"folder":null,"folders":[\(folders.joined(separator: ","))],
         "files":[\(files.joined(separator: ","))]}
        """
    }
}
