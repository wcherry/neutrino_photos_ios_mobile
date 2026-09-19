import UIKit
import XCTest
import NeutrinoAuth
@testable import NeutrinoPhotos

// MARK: - ThumbnailCacheTests

/// What the grid's pictures cost, which since issue #12 is a question about the network.
///
/// The cache used to be an optimisation over bytes it already had: the listing carried the
/// thumbnail inline, and getting it wrong meant a slow grid. Now it is the only thing that
/// dereferences ``MediaItem/thumbnailURL``, and getting it wrong means a grid of placeholders —
/// which is exactly what shipped. So these tests are about the fetch: that it happens, that it
/// happens once, and that the tiers keep it from happening again.
final class ThumbnailCacheTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
    }

    private func makeCache(fetcher: ThumbnailFetching?) -> ThumbnailCache {
        ThumbnailCache(disk: DiskCache(directory: directory, capacityBytes: 1 << 20),
                       fetcher: fetcher)
    }

    private func item(fileID: String = "file-1", thumbnailURL: String? = "/thumb/file-1?v=1")
        -> MediaItem {
        Fixture.item(fileID: fileID, thumbnailURL: thumbnailURL)
    }

    // MARK: - Fetching

    func testFetchesTheThumbnailTheListingPointsAt() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg())
        let sut = makeCache(fetcher: fetcher)

        let image = await sut.image(for: item())

        XCTAssertNotNil(image, "issue #12: a cell whose picture is a URL away drew its placeholder")
        XCTAssertEqual(fetcher.paths, ["/thumb/file-1?v=1"])
    }

    func testAnItemWithNoThumbnailAsksForNothing() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg())
        let sut = makeCache(fetcher: fetcher)

        let image = await sut.image(for: item(thumbnailURL: nil))

        XCTAssertNil(image)
        XCTAssertTrue(fetcher.paths.isEmpty,
                      "a video has no thumbnail to fetch; asking for one is a 404 per cell")
    }

    func testAFailedFetchIsAPlaceholderRatherThanACrash() async {
        let fetcher = SpyFetcher(error: URLError(.notConnectedToInternet))
        let sut = makeCache(fetcher: fetcher)

        let image = await sut.image(for: item())

        XCTAssertNil(image)
    }

    /// The server answers 404 for a file whose thumbnail was swept or replaced between the listing
    /// and the fetch. `nil` bytes, not an error — and still a placeholder rather than a hang.
    func testAMissingThumbnailIsNotAnError() async {
        let fetcher = SpyFetcher(bytes: nil)
        let sut = makeCache(fetcher: fetcher)

        let image = await sut.image(for: item())

        XCTAssertNil(image)
        XCTAssertEqual(fetcher.paths.count, 1)
    }

    // MARK: - The tiers

    func testTheSecondReadDoesNotAskTheServerAgain() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg())
        let sut = makeCache(fetcher: fetcher)

        _ = await sut.image(for: item())
        _ = await sut.image(for: item())

        XCTAssertEqual(fetcher.paths.count, 1,
                       "a cell scrolled back into view must redraw from memory, not from the network")
    }

    func testAFetchedThumbnailSurvivesIntoTheNextLaunch() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg())
        _ = await makeCache(fetcher: fetcher).image(for: item())

        // A second cache over the same directory is what a relaunch looks like: no memory tier,
        // the disk one intact.
        let relaunched = makeCache(fetcher: fetcher)
        let image = await relaunched.image(for: item())

        XCTAssertNotNil(image)
        XCTAssertEqual(fetcher.paths.count, 1, "the JPEG was on disk; fetching it again is a waste")
    }

    func testThumbnailsTheDeviceGeneratedAreNeverFetched() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg())
        let sut = makeCache(fetcher: fetcher)
        // What an upload leaves behind, so a photograph just imported has a picture before the
        // server has been asked for one.
        sut.store(TestImages.jpeg(), forFileID: "file-1")

        let image = await sut.image(for: item())

        XCTAssertNotNil(image)
        XCTAssertTrue(fetcher.paths.isEmpty)
    }

    /// A screenful of cells appearing at once asks for the same picture more than once — the same
    /// photograph is in the timeline and in an open album, and a cell's `task` restarts every time
    /// it re-enters the view. One request, not one per asker.
    func testConcurrentAskersShareOneRequest() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg(), delay: 50_000_000)
        let sut = makeCache(fetcher: fetcher)

        async let first = sut.image(for: item())
        async let second = sut.image(for: item())
        async let third = sut.image(for: item())
        let images = await [first, second, third]

        XCTAssertEqual(images.compactMap { $0 }.count, 3)
        XCTAssertEqual(fetcher.paths.count, 1)
    }

    func testDifferentFilesAreDifferentEntries() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg())
        let sut = makeCache(fetcher: fetcher)

        _ = await sut.image(for: item(fileID: "file-1", thumbnailURL: "/thumb/file-1?v=1"))
        _ = await sut.image(for: item(fileID: "file-2", thumbnailURL: "/thumb/file-2?v=1"))

        XCTAssertEqual(fetcher.paths, ["/thumb/file-1?v=1", "/thumb/file-2?v=1"])
    }

    // MARK: - Through the real client

    /// The whole path, with nothing stubbed but the transport: a listing decoded into a
    /// ``MediaItem``, its ``MediaItem/thumbnailURL`` dereferenced by the cache, and the request
    /// that comes out the other end. Every step of this was in place for issue #12 except the one
    /// joining them, so a test of the steps would have passed while the grid stayed empty.
    @MainActor
    func testTheURLFromAListingBecomesAnAuthorizedRequestForTheBytes() async throws {
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        defer {
            MockURLProtocol.reset()
            TestTokens.remove()
            TestServer.reset()
        }

        let jpeg = TestImages.jpeg()
        MockURLProtocol.route([
            (fragment: "/thumbnail", statusCode: 200, body: jpeg),
            (fragment: "/api/v1/photos", statusCode: 200,
             body: Fixture.listingJSON([
                Fixture.photoJSON(id: "p", fileID: "file-a",
                                  thumbnailURL: "/api/v1/drive/files/file-a/thumbnail?v=9")
             ])),
        ])

        let api = APIClient(session: MockURLProtocol.makeSession())
        let library = PhotoLibraryService(api: api)
        await library.loadEverything()
        let item = try XCTUnwrap(library.allItems.first)

        let sut = makeCache(fetcher: api)
        let image = await sut.image(for: item)

        XCTAssertNotNil(image)
        let request = MockURLProtocol.request { ($0.url?.path ?? "").hasSuffix("/thumbnail") }
        XCTAssertEqual(request?.url?.absoluteString,
                       TestServer.host + "/api/v1/drive/files/file-a/thumbnail?v=9")
        XCTAssertNotNil(request?.value(forHTTPHeaderField: "Authorization"),
                        "the thumbnail endpoint is behind the account's bearer token")
    }

    func testClearingSendsTheNextReadBackToTheServer() async {
        let fetcher = SpyFetcher(bytes: TestImages.jpeg())
        let sut = makeCache(fetcher: fetcher)
        _ = await sut.image(for: item())

        sut.clear()
        _ = await sut.image(for: item())

        XCTAssertEqual(fetcher.paths.count, 2)
    }
}

// MARK: - SpyFetcher

/// Counts what was asked for, and answers with whatever the test set up.
///
/// `@unchecked Sendable` over a lock rather than an actor: the cache calls this from a detached
/// task, and the concurrency test needs several of those calls in flight at once.
private final class SpyFetcher: ThumbnailFetching, @unchecked Sendable {

    private let bytes: Data?
    private let error: Error?
    /// Nanoseconds to hold the answer for, so a test can have two callers overlap.
    private let delay: UInt64

    private let lock = NSLock()
    private var requested: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    init(bytes: Data? = nil, error: Error? = nil, delay: UInt64 = 0) {
        self.bytes = bytes
        self.error = error
        self.delay = delay
    }

    func thumbnailData(at path: String) async throws -> Data? {
        lock.lock()
        requested.append(path)
        lock.unlock()

        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return bytes
    }
}
