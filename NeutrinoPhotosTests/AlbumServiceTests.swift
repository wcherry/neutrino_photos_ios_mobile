import XCTest
@testable import NeutrinoPhotos

// MARK: - AlbumServiceTests

@MainActor
final class AlbumServiceTests: XCTestCase {

    private var sut: AlbumService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        sut = AlbumService(api: APIClient(session: MockURLProtocol.makeSession()))
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    func testLoadPutsUserAlbumsBeforeGeneratedOnes() async {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "auto", title: "Alice", isAuto: true)),
                   \(Fixture.albumJSON(id: "mine", title: "Zermatt"))]}
        """)

        await sut.load()

        XCTAssertEqual(sut.albums.map(\.id), ["mine", "auto"])
        XCTAssertTrue(sut.albums[1].isAuto)
    }

    func testCreateInsertsTheServersAlbum() async throws {
        MockURLProtocol.respond(json: Fixture.albumJSON(id: "new", title: "Trip"), statusCode: 201)

        let album = try await sut.create(title: "Trip")

        XCTAssertEqual(album.id, "new")
        XCTAssertEqual(sut.albums.map(\.id), ["new"])

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/albums"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["title"] as? String, "Trip")
    }

    func testAddingAPhotoBumpsTheCountOnlyOnSuccess() async throws {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a", photoCount: 2))]}
        """)
        await sut.load()

        MockURLProtocol.respond(json: "", statusCode: 204)
        try await sut.add(photoID: "photo-1", to: "a")
        XCTAssertEqual(sut.albums[0].photoCount, 3)

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        do {
            try await sut.add(photoID: "photo-2", to: "a")
            XCTFail("expected the server error to propagate")
        } catch {
            XCTAssertEqual(sut.albums[0].photoCount, 3,
                           "the count on the card must not climb for an add the server refused")
        }
    }

    func testDeleteIsUndoneWhenTheServerRefuses() async {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a"))]}
        """)
        await sut.load()

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        sut.delete(id: "a")
        XCTAssertTrue(sut.albums.isEmpty)

        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sut.albums.map(\.id), ["a"])
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Contents

    func testAnAlbumsContentsComeBackAsFullPhotoRecords() async throws {
        // The endpoint this exercises did not exist before Epic 9 — the album's contents were the
        // one thing the API could not answer. It returns a photo *listing*, not a membership
        // listing, so an album's grid draws the same `MediaItem` the timeline does with no second
        // round trip to resolve ids.
        MockURLProtocol.respond(json: """
        {"photos":[\(Fixture.photoJSON(id: "p1", fileID: "f1")),
                   \(Fixture.photoJSON(id: "p2", fileID: "f2"))],"total":2}
        """)

        let photos = try await sut.photos(in: "album-1")

        XCTAssertEqual(photos.map(\.id), ["p1", "p2"])
        XCTAssertEqual(photos.first?.fileID, "f1",
                       "the Drive file has to survive the trip, or the grid can draw but not open")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/api/v1/albums/album-1/items")
    }

    func testAnAlbumsContentsAreNotCachedOnTheService() async throws {
        // Two reads, two requests. The contents belong to the screen showing them — caching every
        // album ever opened would hold its thumbnails for the rest of the launch.
        MockURLProtocol.respond(json: """
        {"photos":[\(Fixture.photoJSON(id: "p1"))],"total":1}
        """)
        _ = try await sut.photos(in: "a")
        let after = MockURLProtocol.requestCount

        MockURLProtocol.respond(json: """
        {"photos":[\(Fixture.photoJSON(id: "p1"))],"total":1}
        """)
        _ = try await sut.photos(in: "a")

        XCTAssertGreaterThan(MockURLProtocol.requestCount, after)
    }

    // MARK: - Covers

    func testTheCoverIsDecodedAndSurvivesAnAdd() async throws {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a", photoCount: 2, coverPhotoID: "cover"))]}
        """)
        await sut.load()
        XCTAssertEqual(sut.albums[0].coverPhotoID, "cover")

        MockURLProtocol.respond(json: "", statusCode: 204)
        try await sut.add(photoID: "newer", to: "a")

        XCTAssertEqual(sut.albums[0].coverPhotoID, "cover",
                       "adding to an album must not reshuffle the tab under the user's thumb")
    }

    func testAnEmptyAlbumTakesItsFirstPhotoAsItsCover() async throws {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a", photoCount: 0))]}
        """)
        await sut.load()
        XCTAssertNil(sut.albums[0].coverPhotoID)

        MockURLProtocol.respond(json: "", statusCode: 204)
        try await sut.add(photoID: "first", to: "a")

        XCTAssertEqual(sut.albums[0].coverPhotoID, "first")
        XCTAssertEqual(sut.albums[0].photoCount, 1)
    }

    func testRemovingTheCoverClearsItRatherThanGuessingTheNextOne() async throws {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a", photoCount: 3, coverPhotoID: "cover"))]}
        """)
        await sut.load()

        MockURLProtocol.respond(json: "", statusCode: 204)
        try await sut.remove(photoID: "cover", from: "a")

        // The app knows which photograph was taken most recently but not which was *added* most
        // recently, and the cover is the second. Blanking it until the next listing says is the
        // only honest answer.
        XCTAssertNil(sut.albums[0].coverPhotoID)
        XCTAssertEqual(sut.albums[0].photoCount, 2)
    }

    func testRemovingANonCoverPhotoLeavesTheCoverAlone() async throws {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a", photoCount: 3, coverPhotoID: "cover"))]}
        """)
        await sut.load()

        MockURLProtocol.respond(json: "", statusCode: 204)
        try await sut.remove(photoID: "someone-else", from: "a")

        XCTAssertEqual(sut.albums[0].coverPhotoID, "cover")
    }

    // MARK: - Bulk add

    func testBulkAddCountsOnlyWhatActuallyLanded() async throws {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a", photoCount: 0))]}
        """)
        await sut.load()

        // Second of the three refused. The other two must still land — one poison item in a bulk
        // add cannot take the other 499 with it.
        MockURLProtocol.respondInSequence([
            (json: "", statusCode: 204),
            (json: "{}", statusCode: 500),
            (json: "", statusCode: 204),
        ])

        let result = await sut.add(photoIDs: ["p1", "p2", "p3"], to: "a")

        XCTAssertEqual(result.added, ["p1", "p3"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertNotNil(result.failures["p2"])
        XCTAssertFalse(result.isCompleteSuccess)
        XCTAssertEqual(sut.albums[0].photoCount, 2,
                       "the card must show what landed, not what was asked for")
        XCTAssertNotNil(sut.error)
    }

    func testACompleteBulkAddReportsSuccessAndSetsNoError() async {
        MockURLProtocol.respond(json: """
        {"albums":[\(Fixture.albumJSON(id: "a", photoCount: 0))]}
        """)
        await sut.load()

        MockURLProtocol.respondInSequence([
            (json: "", statusCode: 204),
            (json: "", statusCode: 204),
        ])

        let result = await sut.add(photoIDs: ["p1", "p2"], to: "a")

        XCTAssertTrue(result.isCompleteSuccess)
        XCTAssertEqual(sut.albums[0].photoCount, 2)
        XCTAssertEqual(sut.albums[0].coverPhotoID, "p1",
                       "the first of a timeline-ordered selection is the newest, so it is the cover")
        XCTAssertNil(sut.error)
    }

    func testBulkAddToAnAlbumTheServiceDoesNotKnowDoesNotCrash() async {
        // The album was created on another device and this app has not listed it yet. The adds
        // still go out; there is simply no local card to bump.
        MockURLProtocol.respondInSequence([(json: "", statusCode: 204)])

        let result = await sut.add(photoIDs: ["p1"], to: "unknown-album")

        XCTAssertEqual(result.added, ["p1"])
        XCTAssertTrue(sut.albums.isEmpty)
    }
}
