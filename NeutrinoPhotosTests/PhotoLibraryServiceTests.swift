import XCTest
import NeutrinoAuth
@testable import NeutrinoPhotos

// MARK: - PhotoLibraryServiceTests

@MainActor
final class PhotoLibraryServiceTests: XCTestCase {

    private var sut: PhotoLibraryService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        sut = PhotoLibraryService(api: APIClient(session: MockURLProtocol.makeSession()))
    }

    override func tearDown() {
        // First, and before the stub goes: a test that only waited for the first page leaves the
        // rest of the library still arriving, and a walk that outlived its test would go on making
        // requests against the next one's stub.
        sut.cancelFill()
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    // MARK: - Loading

    func testLoadDecodesTheListing() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([
            Fixture.photoJSON(id: "a", fileID: "file-a",
                              thumbnailURL: "/api/v1/drive/files/file-a/thumbnail?v=1"),
            Fixture.photoJSON(id: "b", fileID: "file-b", isStarred: true),
        ]))

        await sut.load()

        XCTAssertEqual(sut.allItems.count, 2)
        XCTAssertEqual(sut.allItems.first?.fileID, "file-a")
        XCTAssertEqual(sut.allItems.first?.thumbnailURL,
                       "/api/v1/drive/files/file-a/thumbnail?v=1")
        XCTAssertEqual(sut.favorites.map(\.id), ["b"])
        XCTAssertNil(sut.error)
        XCTAssertNotNil(sut.lastLoadedAt)
    }

    func testLoadAsksForArchivedItemsToo() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([]))

        await sut.load()

        let query = MockURLProtocol.request { $0.url?.path.hasSuffix("/photos") == true }?.url?.query
        // The server's parameter is misnamed: it means "include archived", and fetching them
        // alongside everything else is what makes the Archive view and the Show Archived toggle
        // free.
        XCTAssertTrue(query?.contains("archivedOnly=true") == true, query ?? "nil")
        // Bounded, which is the whole of issue #3: this listing carries every photo's metadata
        // inline, so asking for a camera roll in one request is tens of megabytes.
        XCTAssertTrue(query?.contains("limit=") == true, query ?? "nil")
    }

    func testLoadSendsTheBearerToken() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([]))

        await sut.load()

        let request = MockURLProtocol.request { $0.url?.path.contains("/photos") == true }
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(TestTokens.defaultAccessToken)")
    }

    func testServerErrorSurfacesWithoutClearingTheLibrary() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON()]))
        await sut.load()
        XCTAssertEqual(sut.allItems.count, 1)

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        await sut.load()

        XCTAssertEqual(sut.allItems.count, 1, "a failed refresh must not empty a browsable library")
        XCTAssertNotNil(sut.error)
    }

    // MARK: - What a transport failure says

    /// Issue #3 arrived as a screenshot of a banner that read the same for every one of these, and
    /// picking the cause out of it was guesswork. Each now names itself and carries its code.
    func testTransportFailuresSayWhichOneHappened() async {
        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "offline"),
            (.timedOut, "too long"),
            (.networkConnectionLost, "dropped"),
            (.cannotFindHost, "Could not find"),
            (.secureConnectionFailed, "secure connection"),
        ]

        for (code, fragment) in cases {
            MockURLProtocol.fail(with: code)
            await sut.load()

            let message = try? XCTUnwrap(sut.error)
            XCTAssertTrue(message?.contains(fragment) == true,
                          "\(code.rawValue) should say \"\(fragment)\", said \(message ?? "nil")")
            XCTAssertTrue(message?.contains("\(code.rawValue)") == true,
                          "\(code.rawValue) should carry its code, said \(message ?? "nil")")
        }
    }

    /// The host is the actionable half of "could not be reached": this app lets the user point it
    /// at their own server, and a typo there is indistinguishable from an outage without it.
    func testAFailureToReachTheServerNamesIt() async {
        MockURLProtocol.fail(with: .cannotConnectToHost,
                             url: URL(string: "https://photos.example.com/api/v1/photos")!)

        await sut.load()

        XCTAssertEqual(sut.error, "Could not connect to photos.example.com. (-1004)")
    }

    func testAnUnrecognisedTransportFailureStillReadsAsEnglish() async {
        MockURLProtocol.fail(with: .cannotParseResponse)

        await sut.load()

        let message = try? XCTUnwrap(sut.error)
        XCTAssertTrue(message?.contains("network error") == true, message ?? "nil")
        XCTAssertTrue(message?.contains("\(URLError.Code.cannotParseResponse.rawValue)") == true,
                      "even the fallback has to be diagnosable")
    }

    // MARK: - Paging

    /// Issue #3. The listing carries every photo's metadata inline, so a camera roll asked for in
    /// one request is tens of megabytes and the phone times out waiting (-1001) on every refresh.
    func testALibraryLargerThanOnePageIsWalkedInFull() async {
        let photos = (0..<1250).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        MockURLProtocol.respondWithPagedListing(photos)

        await sut.loadEverything()

        XCTAssertEqual(sut.allItems.count, 1250)
        XCTAssertEqual(Set(sut.allItems.map(\.id)).count, 1250, "paging must not repeat a photo")
        XCTAssertNil(sut.error)
        XCTAssertGreaterThan(MockURLProtocol.requestCount, 1, "it should have taken several pages")
    }

    func testTheOrderTheServerSentIsPreservedAcrossPageBoundaries() async {
        let photos = (0..<1100).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        MockURLProtocol.respondWithPagedListing(photos)

        await sut.loadEverything()

        XCTAssertEqual(sut.allItems.map(\.id), (0..<1100).map { "p\($0)" })
    }

    // MARK: - First page, then the rest

    /// The point of the change. A 25,000 photo library used to cost 125 requests before the grid
    /// had anything in it; the reader now waits for one.
    func testLoadPaintsTheTimelineAfterASinglePage() async {
        let photos = (0..<25_000).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        MockURLProtocol.respondWithPagedListing(photos)

        await sut.load()

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "the reader waited on more than one request")
        XCTAssertEqual(sut.allItems.count, 200, "a page should be on screen")
        XCTAssertFalse(sut.isLoading, "the grid is usable, so nothing should still read as loading")
        XCTAssertEqual(sut.libraryTotal, 25_000, "the whole library's count, not the page's")
    }

    /// Nothing is given up by showing the first page early: the walk still runs to the end, so the
    /// collections, the counts and the scrubber end up working from the whole library as before.
    func testTheRestOfTheLibraryArrivesBehindTheFirstPage() async {
        let photos = (0..<1000).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        MockURLProtocol.respondWithPagedListing(photos)

        await sut.load()
        XCTAssertEqual(sut.allItems.count, 200)

        await sut.loadEverything()

        XCTAssertEqual(sut.allItems.map(\.id), (0..<1000).map { "p\($0)" })
        XCTAssertFalse(sut.isFillingIn, "the fill should have finished")
        XCTAssertNil(sut.error)
    }

    /// Paging and sorting are one decision: `LIMIT`/`OFFSET` cuts along whatever the server sorted
    /// by, so a client that displays photos by capture date has to page by it too. Asking in
    /// arrival order would make each page an arbitrary slice of the timeline, and the fill would
    /// keep inserting rows above where the reader is looking.
    func testThePagesAreAskedForInTheOrderTheTimelineDisplays() async {
        MockURLProtocol.respondWithPagedListing([Fixture.photoJSON(id: "only")])

        await sut.load()

        let query = MockURLProtocol.request { $0.url?.path.hasSuffix("/photos") == true }?.url?.query
        XCTAssertTrue(query?.contains("orderBy=captureDate") == true, query ?? "nil")
    }

    /// Offset paging over a library somebody is still adding to can hand back a photo twice: an
    /// insert above the frontier shifts every later row down one. The grid must not show it twice.
    func testAPhotoHandedBackOnTwoPagesLandsInTheTimelineOnce() async {
        // The server repeats `p199` as the first row of the second page, which is what an insert
        // during the walk looks like from here.
        var pages = (0..<200).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        pages += [Fixture.photoJSON(id: "p199", fileID: "f199")]
        pages += (200..<260).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        MockURLProtocol.respondWithPagedListing(pages)

        await sut.loadEverything()

        XCTAssertEqual(Set(sut.allItems.map(\.id)).count, sut.allItems.count,
                       "a repeated photo reached the timeline twice")
        XCTAssertEqual(sut.allItems.filter { $0.id == "p199" }.count, 1)
    }

    /// A fill that dies partway leaves a usable timeline rather than an empty grid — that part of
    /// issue #3 stays fixed — but it must still say so, because every count in the app is a
    /// fraction until the walk finishes and there is no way for the reader to spot that alone.
    func testAFailedFillKeepsTheFirstPageAndReportsIt() async {
        let photos = (0..<1000).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        let paged = MockURLProtocol.handlerForPagedListing(photos)
        MockURLProtocol.handler = { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
            if offset > 0 { throw URLError(.timedOut) }
            return try paged(request)
        }

        await sut.loadEverything()

        XCTAssertEqual(sut.allItems.count, 200, "the first page should still be on screen")
        XCTAssertNotNil(sut.error, "an incomplete library has to be reported")
        XCTAssertFalse(sut.isFillingIn)
    }

    /// A refresh over a timeline that is already on screen assembles off-screen and swaps in at the
    /// end. Truncating a full timeline to two hundred rows to refill it would be a visible collapse
    /// under the reader's thumb.
    func testARefreshNeverShrinksTheTimelineOnItsWayBackUp() async {
        let photos = (0..<1000).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") }
        MockURLProtocol.respondWithPagedListing(photos)
        await sut.loadEverything()
        XCTAssertEqual(sut.allItems.count, 1000)

        await sut.load()

        XCTAssertEqual(sut.allItems.count, 1000,
                       "the refresh's first page must not replace the library with itself")
    }

    /// A walk that finishes is authoritative, and that is what takes a photo deleted on another
    /// device off this one.
    func testACompletedRefreshDropsWhatTheServerNoLongerLists() async {
        MockURLProtocol.respondWithPagedListing(
            (0..<300).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") })
        await sut.loadEverything()
        XCTAssertEqual(sut.allItems.count, 300)

        MockURLProtocol.respondWithPagedListing(
            (0..<250).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") })
        await sut.loadEverything()

        XCTAssertEqual(sut.allItems.count, 250)
        XCTAssertNil(sut.item(id: "p299"), "a photo the server dropped should be gone")
    }

    /// A library that fits in one page must not cost a second request to discover that.
    func testASmallLibraryTakesOneRequest() async {
        MockURLProtocol.respondWithPagedListing([Fixture.photoJSON(id: "only")])

        await sut.load()

        XCTAssertEqual(sut.allItems.map(\.id), ["only"])
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testAnEmptyLibraryTakesOneRequestAndReportsNoError() async {
        MockURLProtocol.respondWithPagedListing([])

        await sut.load()

        XCTAssertTrue(sut.allItems.isEmpty)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertNil(sut.error)
    }

    /// A page that fails leaves the timeline as it was rather than half a library — the same
    /// promise a failed single-request refresh made.
    func testAFailedPageDoesNotLeaveAPartialLibraryOnScreen() async {
        MockURLProtocol.respondWithPagedListing(
            (0..<800).map { Fixture.photoJSON(id: "p\($0)", fileID: "f\($0)") })
        await sut.loadEverything()
        XCTAssertEqual(sut.allItems.count, 800)

        MockURLProtocol.fail(with: .timedOut)
        await sut.loadEverything()

        XCTAssertEqual(sut.allItems.count, 800, "a failed refresh must not truncate the timeline")
        XCTAssertNotNil(sut.error)
    }

    // MARK: - Coalescing

    /// A launch fires this twice — `ContentView` on the import flag, `LibraryView` on appearance —
    /// and both want the same listing. Fetching a whole camera roll's worth of JSON twice is what
    /// that used to cost.
    func testConcurrentLoadsShareOneRequest() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))

        async let first: Void = sut.load()
        async let second: Void = sut.load()
        _ = await (first, second)

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "the second caller should wait, not refetch")
        XCTAssertEqual(sut.allItems.map(\.id), ["a"])
    }

    func testASecondLoadAfterTheFirstFinishesStillFetches() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()
        await sut.load()

        XCTAssertEqual(MockURLProtocol.requestCount, 2,
                       "coalescing is for requests in flight, not a refresh the user asked for")
    }

    // MARK: - Filtering

    func testArchivedItemsAreHiddenFromTheTimelineUnlessAskedFor() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([
            Fixture.photoJSON(id: "live"),
            Fixture.photoJSON(id: "filed", isArchived: true),
        ]))

        await sut.load()

        XCTAssertEqual(sut.timeline(showingArchived: false).map(\.id), ["live"])
        XCTAssertEqual(Set(sut.timeline(showingArchived: true).map(\.id)), ["live", "filed"])
        XCTAssertEqual(sut.archived.map(\.id), ["filed"])
    }

    func testTimelineIsNewestFirst() async {
        let older = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        MockURLProtocol.respond(data: Fixture.listingJSON([
            Fixture.photoJSON(id: "older", captureDate: older),
            Fixture.photoJSON(id: "newer", captureDate: newer),
        ]))

        await sut.load()

        XCTAssertEqual(sut.timeline(showingArchived: false).map(\.id), ["newer", "older"])
    }

    // MARK: - Registration

    func testRegisterSendsTheCaptureDateInTheServersFormat() async throws {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        MockURLProtocol.respond(json: Fixture.photoJSON(id: "new", fileID: "file-new"), statusCode: 201)

        let item = try await sut.register(fileID: "file-new", captureDate: taken)

        XCTAssertEqual(item.id, "new")
        XCTAssertEqual(sut.allItems.first?.id, "new")

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/photos"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fileId"] as? String, "file-new")
        // `chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S")` accepts exactly this and
        // nothing with a zone or a fraction — an ISO 8601 string would be dropped on the floor.
        XCTAssertEqual(json["captureDate"] as? String, "2023-11-14T22:13:20")
    }

    func testRegisterWithoutACaptureDateOmitsTheField() async throws {
        MockURLProtocol.respond(json: Fixture.photoJSON(), statusCode: 201)

        _ = try await sut.register(fileID: "file-1", captureDate: nil)

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/photos"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["fileId"] as? String, "file-1")
        // `JSONEncoder` drops a nil optional rather than writing null, and serde reads a missing
        // `Option<String>` as `None` — so an item with no EXIF date registers cleanly and the
        // server files it under its upload time, which is what `timelineDate` falls back to.
        XCTAssertNil(json["captureDate"])
    }

    // MARK: - Duplicate detection

    func testContainsFileMatchesOnTheDriveFileID() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(fileID: "file-a")]))
        await sut.load()

        XCTAssertTrue(sut.containsFile(id: "file-a"))
        XCTAssertFalse(sut.containsFile(id: "file-b"))
    }

    // MARK: - Revision

    func testEveryChangeToTheLibraryBumpsTheRevision() async {
        // What ``TimelineCache`` keys its grouping on. A change that failed to bump it would leave
        // the timeline showing a library that is no longer there — a deleted photograph still in
        // the grid — and no amount of scrolling would correct it.
        let start = sut.revision

        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()
        let afterLoad = sut.revision
        XCTAssertGreaterThan(afterLoad, start)

        MockURLProtocol.respond(json: Fixture.photoJSON(id: "a", isStarred: true))
        sut.setStarred(id: "a", isStarred: true)
        XCTAssertGreaterThan(sut.revision, afterLoad, "an optimistic edit is a change too")
        let afterStar = sut.revision

        await settle()

        MockURLProtocol.respond(json: "", statusCode: 204)
        sut.trash(id: "a")
        XCTAssertGreaterThan(sut.revision, afterStar)
    }

    func testTheRevisionDoesNotMoveWhenTheLibraryDoesNot() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()
        let quiet = sut.revision

        // Reading is not changing — if it were, the memoization would never hit.
        _ = sut.timeline(showingArchived: false)
        _ = sut.item(id: "a")
        _ = sut.favorites

        XCTAssertEqual(sut.revision, quiet)
    }

    // MARK: - Mutations

    func testStarringIsOptimisticAndRollsBackOnFailure() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        sut.setStarred(id: "a", isStarred: true)
        XCTAssertTrue(sut.allItems[0].isStarred, "the flag should flip before the round trip")

        await settle()
        XCTAssertFalse(sut.allItems[0].isStarred, "a refused change must not stay on screen")
        XCTAssertNotNil(sut.error)
    }

    func testTrashMovesTheItemAndRestorePutsItBack() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()

        MockURLProtocol.respond(json: "", statusCode: 204)
        sut.trash(id: "a")
        XCTAssertTrue(sut.allItems.isEmpty)
        XCTAssertEqual(sut.trashItems.map(\.id), ["a"])
        await settle()

        MockURLProtocol.respond(json: Fixture.photoJSON(id: "a"))
        sut.restore(id: "a")
        await settle()
        XCTAssertEqual(sut.allItems.map(\.id), ["a"])
        XCTAssertTrue(sut.trashItems.isEmpty)
    }

    func testEmptyTrashRestoresTheListWhenTheServerRefuses() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "gone")]))
        await sut.loadTrash()
        XCTAssertEqual(sut.trashItems.count, 1)

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        sut.emptyTrash()
        await settle()

        XCTAssertEqual(sut.trashItems.count, 1)
        XCTAssertNotNil(sut.error)
    }

    func testTrashingStampsDeletedAtAndRestoringClearsIt() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()
        XCTAssertNil(sut.allItems.first?.deletedAt)

        MockURLProtocol.respond(json: "", statusCode: 204)
        let before = Date()
        sut.trash(id: "a")
        await settle()

        // `DELETE /photos/{id}` answers 204 with no body, so there is no server timestamp to read
        // back — without stamping it here the countdown would show nothing until a `loadTrash()`.
        let deletedAt = sut.trashItems.first?.deletedAt
        XCTAssertNotNil(deletedAt)
        XCTAssertGreaterThanOrEqual(deletedAt ?? .distantPast, before)
        XCTAssertEqual(TrashRetention.daysRemaining(for: sut.trashItems[0]), TrashRetention.days)

        MockURLProtocol.respond(json: Fixture.photoJSON(id: "a"))
        sut.restore(id: "a")
        await settle()

        XCTAssertNil(sut.allItems.first?.deletedAt,
                     "a restored photo still claiming a deletion date would be counted as trashed")
    }

    func testAFailedTrashPutsTheItemBackWithoutADeletionDate() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        sut.trash(id: "a")
        await settle()

        XCTAssertEqual(sut.allItems.map(\.id), ["a"])
        XCTAssertTrue(sut.trashItems.isEmpty)
        XCTAssertNil(sut.allItems.first?.deletedAt,
                     "the rollback has to undo the stamp too, or the item is live and 'deleted'")
    }

    // MARK: - Permanent delete

    func testDeletePermanentlyRemovesTheItemAndHitsThePermanentPath() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([
            Fixture.photoJSON(id: "gone", deletedAt: Date()),
        ]))
        await sut.loadTrash()

        MockURLProtocol.respond(json: "", statusCode: 204)
        sut.deletePermanently(id: "gone")
        XCTAssertTrue(sut.trashItems.isEmpty)
        await settle()

        let request = MockURLProtocol.request { ($0.url?.path ?? "").hasSuffix("/permanent") }
        XCTAssertEqual(request?.url?.path, "/api/v1/photos/gone/permanent")
        XCTAssertEqual(request?.httpMethod, "DELETE")
    }

    func testDeletePermanentlyPutsTheItemBackWhenTheServerRefuses() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([
            Fixture.photoJSON(id: "gone", deletedAt: Date()),
        ]))
        await sut.loadTrash()

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        sut.deletePermanently(id: "gone")
        await settle()

        XCTAssertEqual(sut.trashItems.map(\.id), ["gone"])
        XCTAssertNotNil(sut.error)
    }

    func testDeletePermanentlyIgnoresAnItemThatIsNotInTheTrash() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "live")]))
        await sut.load()
        let before = MockURLProtocol.requestCount

        sut.deletePermanently(id: "live")
        await settle()

        // The two-step path through Recently Deleted is the whole point of having one; the app
        // refuses to short-circuit it even though the server would refuse too.
        XCTAssertEqual(sut.allItems.map(\.id), ["live"])
        XCTAssertEqual(MockURLProtocol.requestCount, before, "no request should have gone out")
    }

    // MARK: - Recently Added

    func testRecentlyAddedIsOrderedByArrivalNotByCaptureDate() async {
        // The distinction the view exists for: a scanned photograph from 1998 imported today is
        // *recently added* and is nowhere near the top of the timeline.
        let now = Date()
        MockURLProtocol.respond(data: Fixture.listingJSON([
            Fixture.photoJSON(id: "scanned",
                              captureDate: Date(timeIntervalSince1970: 900_000_000),
                              createdAt: now),
            Fixture.photoJSON(id: "older-import",
                              captureDate: now,
                              createdAt: now.addingTimeInterval(-2 * 86_400)),
        ]))
        await sut.load()

        XCTAssertEqual(sut.recentlyAdded(now: now).map(\.id), ["scanned", "older-import"])
        XCTAssertEqual(sut.timeline(showingArchived: false).map(\.id), ["older-import", "scanned"],
                       "the timeline still sorts by capture date — the two views disagree on purpose")
    }

    func testRecentlyAddedExcludesOldArrivalsAndArchivedItems() async {
        let now = Date()
        MockURLProtocol.respond(data: Fixture.listingJSON([
            Fixture.photoJSON(id: "fresh", createdAt: now.addingTimeInterval(-86_400)),
            Fixture.photoJSON(id: "ancient", createdAt: now.addingTimeInterval(-60 * 86_400)),
            Fixture.photoJSON(id: "archived", isArchived: true,
                              createdAt: now.addingTimeInterval(-86_400)),
        ]))
        await sut.load()

        // Archiving is the user saying "keep this out of the way"; a second view that shows it
        // anyway would undo that for a month.
        XCTAssertEqual(sut.recentlyAdded(now: now).map(\.id), ["fresh"])
    }

    // MARK: - Metadata

    func testMetadataIsAttachedLocallyAndPublishedToTheWorkerEndpoint() async throws {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()

        MockURLProtocol.respond(json: "", statusCode: 204)
        await sut.setMetadata(
            MediaMetadata(width: 4032, height: 3024,
                          exif: MediaExif(make: "Apple", gpsLatitude: 51.5, gpsLongitude: 0.12)),
            forPhoto: "a", publishingLocation: true)

        XCTAssertEqual(sut.item(id: "a")?.metadata?.width, 4032)

        let request = try XCTUnwrap(MockURLProtocol.request { $0.httpMethod == "PUT" })
        // A worker endpoint, and the only way an end-to-end encrypted photograph's EXIF can ever
        // reach the server: what it receives is ciphertext and the key never leaves the device.
        XCTAssertEqual(request.url?.path, "/api/v1/photos/a/metadata")

        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/metadata"))
        let sent = try JSONDecoder().decode(MediaMetadata.self, from: body)
        XCTAssertEqual(sent.exif?.gpsLatitude ?? 0, 51.5, accuracy: 0.001)
    }

    func testLocationIsHeldBackFromTheServerButKeptOnTheDevice() async throws {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()

        MockURLProtocol.respond(json: "", statusCode: 204)
        await sut.setMetadata(
            MediaMetadata(width: 4032,
                          exif: MediaExif(make: "Apple", gpsLatitude: 51.5, gpsLongitude: 0.12)),
            forPhoto: "a", publishingLocation: false)

        // Locally complete — the info panel shows a location the moment the import finishes.
        XCTAssertEqual(sut.item(id: "a")?.metadata?.exif?.gpsLatitude ?? 0, 51.5, accuracy: 0.001)

        // And nothing that says where anybody was left the device.
        let body = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/metadata"))
        let sent = try JSONDecoder().decode(MediaMetadata.self, from: body)
        XCTAssertNil(sent.exif?.gpsLatitude)
        XCTAssertNil(sent.exif?.gpsLongitude)
        XCTAssertEqual(sent.exif?.make, "Apple", "only the coordinates are withheld")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("51.5"),
                       "the number must not survive anywhere in the payload")
    }

    func testARefreshDoesNotBlankALocationTheServerWasNeverGiven() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()
        MockURLProtocol.respond(json: "", statusCode: 204)
        await sut.setMetadata(MediaMetadata(exif: MediaExif(gpsLatitude: 51.5, gpsLongitude: 0.12)),
                              forPhoto: "a", publishingLocation: false)

        // The listing comes back exactly as it went out: metadata null, because the coordinates
        // were never published. Without the merge, a pull to refresh silently empties the info
        // panel of every photograph the user chose to keep private.
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()

        XCTAssertEqual(sut.item(id: "a")?.metadata?.exif?.gpsLatitude ?? 0, 51.5, accuracy: 0.001)
    }

    func testAnEmptyRecordIsNeitherStoredNorSent() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()
        let before = MockURLProtocol.requestCount

        await sut.setMetadata(MediaMetadata(), forPhoto: "a", publishingLocation: true)

        XCTAssertEqual(MockURLProtocol.requestCount, before)
        XCTAssertNil(sut.item(id: "a")?.metadata)
    }

    func testFavouritingAnItemDoesNotBlankTheMetadataJustAttachedToIt() async {
        // Importing a favourited photograph fires two writes at once: a PATCH setting the star and
        // a PUT attaching the metadata. The PATCH response carries `metadata: null` — the server
        // has not been told yet — so assigning it wholesale means whichever lands second wins, and
        // half the time that is the one that erases the record the other just wrote.
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()
        MockURLProtocol.respond(json: "", statusCode: 204)
        await sut.setMetadata(MediaMetadata(width: 4032,
                                            device: MediaDeviceFacts(isLivePhoto: true)),
                              forPhoto: "a", publishingLocation: true)

        MockURLProtocol.respond(json: Fixture.photoJSON(id: "a", isStarred: true))
        sut.setStarred(id: "a", isStarred: true)
        await settle()

        XCTAssertEqual(sut.item(id: "a")?.isStarred, true)
        XCTAssertEqual(sut.item(id: "a")?.metadata?.width, 4032)
        XCTAssertTrue(sut.item(id: "a")?.isLivePhoto ?? false)
    }

    func testAFailedPublishDoesNotUndoTheLocalRecord() async {
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a")]))
        await sut.load()

        MockURLProtocol.respond(json: "{}", statusCode: 500)
        await sut.setMetadata(MediaMetadata(width: 4032), forPhoto: "a", publishingLocation: true)

        // The photograph is uploaded and registered by the time this runs. Failing it over its
        // index entry — or worse, rolling the local copy back — trades the thing that matters for
        // the thing that does not.
        XCTAssertEqual(sut.item(id: "a")?.metadata?.width, 4032)
        XCTAssertNil(sut.error, "an index write is not worth an error banner over the timeline")
    }

    // MARK: - Helpers

    /// Lets the detached `Task` inside an optimistic mutation finish.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}
