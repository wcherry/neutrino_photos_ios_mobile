import XCTest
@testable import NeutrinoPhotos

/// The platform's Live Photo convention (`neutrino/agent_docs/live-photos.md`, issue #27): the clip
/// is registered with `motionPhoto`, the still carries `motionPhoto` beside `liveVideoFileID`, a
/// claimed clip never shows on its own, and metadata is merged, never written whole.
@MainActor
final class LivePhotoConventionTests: XCTestCase {

    // MARK: - Fixtures

    private static func still(id: String = "still", fileID: String = "file-still",
                              clipFile: String? = "file-clip", contentIdentifier: String? = nil,
                              motion: Bool = false) -> MediaItem {
        Fixture.item(id: id, fileID: fileID, fileName: "IMG_0001.HEIC", mimeType: "image/heic",
                     metadata: MediaMetadata(
                        device: MediaDeviceFacts(isLivePhoto: true, liveVideoFileID: clipFile),
                        motionPhoto: motion || contentIdentifier != nil
                            ? .livePhoto(contentIdentifier: contentIdentifier) : nil))
    }

    private static func clip(id: String = "clip", fileID: String = "file-clip",
                             contentIdentifier: String? = nil) -> MediaItem {
        Fixture.item(id: id, fileID: fileID, fileName: "\(fileID).live.mov",
                     mimeType: "video/quicktime",
                     metadata: contentIdentifier.map {
                         MediaMetadata(motionPhoto: .livePhoto(contentIdentifier: $0))
                     })
    }

    nonisolated private static func ok(_ request: URLRequest, _ status: Int, _ body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
         Data(body.utf8))
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        super.tearDown()
    }

    private func library(_ items: [MediaItem]) -> PhotoLibraryService {
        PhotoLibraryService(api: APIClient(session: MockURLProtocol.makeSession()), items: items)
    }

    // MARK: - Pairing

    func testAStillClaimsTheClipItsLinkNames() {
        let claimed = LivePhotoPairing.claimedClipIDs(in: [Self.still(), Self.clip(),
                                                          Self.clip(id: "other", fileID: "file-other")])
        XCTAssertEqual(claimed, ["clip"], "only the named clip; an unrelated video is a video")
    }

    func testAContentIdentifierClaimsAClipWithoutALink() {
        let claimed = LivePhotoPairing.claimedClipIDs(in: [
            Self.still(clipFile: nil, contentIdentifier: "6A1F"),
            Self.clip(fileID: "file-elsewhere", contentIdentifier: "6A1F"),
        ])
        XCTAssertEqual(claimed, ["clip"])
    }

    func testNothingIsClaimedWithoutALinkOrAnIdentifier() {
        XCTAssertTrue(LivePhotoPairing.claimedClipIDs(in: [Self.still(clipFile: nil), Self.clip()]).isEmpty)
    }

    func testAPhotoIsNeverClaimed() {
        // A still whose file id happens to be another still's link is not a clip.
        let claimed = LivePhotoPairing.claimedClipIDs(in: [
            Self.still(), Self.still(id: "second", fileID: "file-clip", clipFile: nil),
        ])
        XCTAssertTrue(claimed.isEmpty)
    }

    // MARK: - The library

    func testAClaimedClipIsSetAsideFromTheLibrary() {
        let sut = library([Self.still(), Self.clip(), Self.clip(id: "video", fileID: "file-video")])

        XCTAssertEqual(Set(sut.allItems.map(\.id)), ["still", "video"],
                       "one tile for one Live Photo; an ordinary video still shows")
        XCTAssertEqual(sut.timeline(showingArchived: true).count, 2)
        XCTAssertEqual(sut.livePhotoClips.keys.sorted(), ["clip"])
        XCTAssertTrue(sut.containsFile(id: "file-clip"),
                      "a set-aside clip is still registered — an import must not register it again")
    }

    func testRegisteringAClipKeepsItOutOfTheTimelineAndMarksIt() async throws {
        let sut = library([Self.still()])
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return Self.ok(request, 201, Fixture.photoJSON(id: "clip", fileID: "file-clip",
                                                          fileName: "file-still.live.mov",
                                                          mimeType: "video/quicktime"))
            }
            return Self.ok(request, 200, "{}")
        }

        try await sut.registerLivePhotoClip(
            fileID: "file-clip", motion: .livePhoto(contentIdentifier: "6A1F", stillImageTime: 1.5),
            captureDate: nil)

        XCTAssertEqual(sut.allItems.map(\.id), ["still"])
        XCTAssertEqual(sut.livePhotoClips["clip"]?.metadata?.motionPhoto?.contentIdentifier, "6A1F")

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/photos/clip/metadata",
                                                      method: "PATCH"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Array(json.keys), ["motionPhoto"], "a merge of one key, nothing else")
        let motion = try XCTUnwrap(json["motionPhoto"] as? [String: Any])
        XCTAssertEqual(motion["subtype"] as? String, "live_photo_apple")
        XCTAssertEqual(motion["signal"] as? String, "PHAssetMediaSubtype.photoLive")
        XCTAssertEqual(motion["contentIdentifier"] as? String, "6A1F")
        XCTAssertEqual(motion["stillImageTime"] as? Double, 1.5)
    }

    func testRegisteringAnAlreadyRegisteredFileDoesNotListItTwice() async throws {
        let sut = library([Fixture.item(id: "a", fileID: "file-a")])
        MockURLProtocol.respond(json: Fixture.photoJSON(id: "a", fileID: "file-a"), statusCode: 200)

        try await sut.register(fileID: "file-a", captureDate: nil)

        XCTAssertEqual(sut.allItems.map(\.id), ["a"])
    }

    // MARK: - Merging

    func testAPatchNullsTheLocationItIsNotPublishing() throws {
        let metadata = MediaMetadata(width: 4032, exif: MediaExif(make: "Apple"),
                                     motionPhoto: .livePhoto())
        let patch = try metadata.mergePatch(removing: MediaMetadata.locationPaths)

        XCTAssertEqual(patch["width"], .number(4032))
        XCTAssertEqual(patch["exif"]?["make"], .string("Apple"))
        XCTAssertEqual(patch["exif"]?["gpsLatitude"], .null,
                       "a merge keeps what it doesn't name, so withheld coordinates are removed")
        XCTAssertEqual(patch["motionPhoto"]?["subtype"], .string("live_photo_apple"))
        XCTAssertNil(patch["title"], "an absent key is left alone, not cleared")
    }

    func testBooleansStayBooleans() throws {
        let patch = try MediaMetadata(device: MediaDeviceFacts(isLivePhoto: true)).mergePatch()
        XCTAssertEqual(patch["device"]?["isLivePhoto"], .bool(true))
        let encoded = String(decoding: try JSONEncoder().encode(patch), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"isLivePhoto\":true"), encoded)
    }

    func testAServerWithoutTheMergeEndpointGetsTheWholeDocument() async throws {
        let sut = library([Fixture.item(id: "a")])
        MockURLProtocol.handler = { request in
            Self.ok(request, request.httpMethod == "PATCH" ? 405 : 204, "")
        }

        await sut.setMetadata(MediaMetadata(width: 4032), forPhoto: "a", publishingLocation: true)

        let put = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/photos/a/metadata",
                                                     method: "PUT"))
        XCTAssertEqual(try JSONDecoder().decode(MediaMetadata.self, from: put).width, 4032)
    }

    // MARK: - Backfill

    func testTheBackfillRegistersTheClipAndMarksTheStill() async throws {
        let sut = library([Self.still()])
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return Self.ok(request, 201, Fixture.photoJSON(id: "clip", fileID: "file-clip",
                                                          mimeType: "video/quicktime"))
            }
            return Self.ok(request, 200, "{}")
        }

        let done = await sut.backfillLivePhotoConvention()

        XCTAssertEqual(done, 1)
        let register = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/api/v1/photos",
                                                          method: "POST"))
        XCTAssertTrue(String(decoding: register, as: UTF8.self).contains("file-clip"))
        let still = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/photos/still/metadata",
                                                       method: "PATCH"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: still) as? [String: Any])
        XCTAssertEqual(Array(json.keys), ["motionPhoto"])
        XCTAssertNotNil(sut.item(id: "still")?.metadata?.motionPhoto)
        XCTAssertEqual(sut.allItems.map(\.id), ["still"], "the clip it registered is set aside")
    }

    func testTheBackfillLeavesACurrentLibraryAlone() async {
        let sut = library([Self.still(motion: true), Self.clip()])
        MockURLProtocol.respond(json: "{}")

        let done = await sut.backfillLivePhotoConvention()

        XCTAssertEqual(done, 0)
        XCTAssertNil(MockURLProtocol.request { _ in true }, "nothing to do costs no request")
    }

    func testTheBackfillNeverFallsBackToAWholeDocumentWrite() async {
        let sut = library([Self.still(), Self.clip()])
        MockURLProtocol.handler = { request in
            Self.ok(request, request.httpMethod == "PATCH" ? 405 : 204, "")
        }

        let done = await sut.backfillLivePhotoConvention()

        XCTAssertEqual(done, 0)
        XCTAssertNil(MockURLProtocol.request { $0.httpMethod == "PUT" },
                     "a repair that can't merge must not erase instead")
        // And it isn't retried this launch.
        MockURLProtocol.reset()
        TestTokens.install()
        _ = await sut.backfillLivePhotoConvention()
        XCTAssertNil(MockURLProtocol.request { _ in true })
    }

    func testTheBackfillIsCapped() async {
        let stills = (0..<5).map { Self.still(id: "s\($0)", fileID: "f\($0)", clipFile: "clip-\($0)") }
        let sut = library(stills)
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return Self.ok(request, 201, Fixture.photoJSON(id: UUID().uuidString, fileID: "x",
                                                          mimeType: "video/quicktime"))
            }
            return Self.ok(request, 200, "{}")
        }

        let done = await sut.backfillLivePhotoConvention(limit: 2)
        XCTAssertEqual(done, 2)
    }

    // MARK: - Reading a clip

    func testAnUnreadableClipIsStillALivePhoto() async throws {
        let url = makeTemporaryDirectory().appendingPathComponent("not-a.mov")
        try Data("nope".utf8).write(to: url)

        let motion = await LivePhotoClipReader.motionPhoto(ofClipAt: url)

        XCTAssertEqual(motion, .livePhoto())
    }
}
