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

    func testAnAlbumsContentsAreNotAvailableYet() async throws {
        // Documents the gap rather than hiding it: there is no `GET /albums/{id}/items`, so the
        // Albums tab cannot open one. This test fails the day the endpoint lands, which is when
        // somebody should implement it.
        let photos = try await sut.photos(in: "a")
        XCTAssertTrue(photos.isEmpty)
    }
}
