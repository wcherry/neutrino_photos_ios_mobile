import XCTest
@testable import NeutrinoPhotos

// MARK: - Helpers

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2 // Monday
    return calendar
}()

private func date(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text)!
}

private func item(_ id: String,
                  fileName: String? = nil,
                  mimeType: String = "image/jpeg",
                  isStarred: Bool = false,
                  make: String? = nil,
                  model: String? = nil,
                  lens: String? = nil,
                  title: String? = nil,
                  caption: String? = nil,
                  subtypes: [String]? = nil,
                  taken: String = "2024-06-15T12:00:00Z") -> MediaItem {
    let exif = (make != nil || model != nil || lens != nil)
        ? MediaExif(make: make, model: model, lensModel: lens) : nil
    let device = subtypes.map { MediaDeviceFacts(subtypes: $0) }
    let hasMetadata = exif != nil || device != nil || title != nil || caption != nil
    return Fixture.item(id: id, fileID: "f-\(id)", fileName: fileName ?? "\(id).jpg",
                        mimeType: mimeType, isStarred: isStarred, captureDate: date(taken),
                        metadata: hasMetadata
                            ? MediaMetadata(exif: exif, device: device, title: title, caption: caption)
                            : nil)
}

// MARK: - SearchQueryTests

final class SearchQueryTests: XCTestCase {

    /// Wednesday 2 October 2026, midday UTC.
    private let now = date("2026-10-02T12:00:00Z")

    private func parse(_ text: String) -> SearchQuery {
        SearchQuery.parse(text, now: now, calendar: utc)
    }

    func testAMonthAndYearIsThatMonth() {
        let query = parse("June 2024")

        XCTAssertEqual(query.dateRange?.start, date("2024-06-01T00:00:00Z"))
        XCTAssertEqual(query.dateRange?.end, date("2024-07-01T00:00:00Z"))
        XCTAssertEqual(query.text, "")
    }

    func testTheYearMayComeFirstAndTheMonthBeAbbreviated() {
        XCTAssertEqual(parse("2024 jun").dateRange, parse("june 2024").dateRange)
        XCTAssertEqual(parse("Sept 2023").dateRange?.start, date("2023-09-01T00:00:00Z"))
    }

    func testAYearAloneIsTheWholeYear() {
        let query = parse("2023")

        XCTAssertEqual(query.dateRange?.start, date("2023-01-01T00:00:00Z"))
        XCTAssertEqual(query.dateRange?.end, date("2024-01-01T00:00:00Z"))
    }

    func testAMonthAloneIsThatMonthInEveryYear() {
        let query = parse("december")

        XCTAssertEqual(query.monthOfAnyYear, 12)
        XCTAssertNil(query.dateRange)
    }

    func testLastWeekIsThePreviousCalendarWeek() {
        let query = parse("last week")

        XCTAssertEqual(query.dateRange?.start, date("2026-09-21T00:00:00Z"), "the Monday before last")
        XCTAssertEqual(query.dateRange?.end, date("2026-09-28T00:00:00Z"))
    }

    func testTodayYesterdayAndThisMonth() {
        XCTAssertEqual(parse("today").dateRange?.start, date("2026-10-02T00:00:00Z"))
        XCTAssertEqual(parse("yesterday").dateRange?.start, date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(parse("this month").dateRange?.start, date("2026-10-01T00:00:00Z"))
    }

    func testAnISODateIsThatDay() {
        let query = parse("2024-06-01")

        XCTAssertEqual(query.dateRange?.start, date("2024-06-01T00:00:00Z"))
        XCTAssertEqual(query.dateRange?.end, date("2024-06-02T00:00:00Z"))
    }

    func testKindsAndFavoritesAreFiltersNotText() {
        let query = parse("favorite videos")

        XCTAssertEqual(query.kind, .video)
        XCTAssertTrue(query.favoritesOnly)
        XCTAssertEqual(query.text, "")
    }

    func testWhatIsNotAFilterIsKeptAsText() {
        let query = parse("  iPhone 15   Pro ")

        XCTAssertEqual(query.text, "iphone 15 pro")
        XCTAssertNil(query.dateRange, "15 is not a year")
    }

    func testFiltersAndTextCombine() {
        let query = parse("beach 2023")

        XCTAssertEqual(query.text, "beach")
        XCTAssertEqual(query.dateRange?.start, date("2023-01-01T00:00:00Z"))
    }

    func testAFileNumberIsNotMistakenForAYear() {
        XCTAssertNil(parse("4032").dateRange)
        XCTAssertEqual(parse("4032").text, "4032")
    }
}

// MARK: - SearchIndexTests

final class SearchIndexTests: XCTestCase {

    private func search(_ items: [MediaItem], _ text: String) -> [String] {
        SearchIndex(items: items)
            .search(SearchQuery.parse(text, now: date("2026-10-02T12:00:00Z"), calendar: utc),
                    calendar: utc)
            .map(\.id)
    }

    func testAKnownFileNameIsTheFirstResult() {
        let items = [
            item("older-similar", fileName: "IMG_4021_edit.jpg", taken: "2025-01-01T00:00:00Z"),
            item("exact", fileName: "IMG_4021.jpg", taken: "2020-01-01T00:00:00Z"),
        ]

        XCTAssertEqual(search(items, "IMG_4021.jpg").first, "exact")
        XCTAssertEqual(search(items, "img_4021").first, "exact",
                       "the name without its extension counts as exact too")
    }

    func testAMonthReturnsExactlyThatMonth() {
        let items = [
            item("may-31", taken: "2024-05-31T23:59:59Z"),
            item("june-1", taken: "2024-06-01T00:00:00Z"),
            item("june-30", taken: "2024-06-30T23:59:59Z"),
            item("july-1", taken: "2024-07-01T00:00:00Z"),
            item("june-2023", taken: "2023-06-10T00:00:00Z"),
        ]

        XCTAssertEqual(Set(search(items, "June 2024")), ["june-1", "june-30"])
    }

    func testACameraMatchesAsAPhraseNotAsScatteredWords() {
        let items = [
            item("15-pro", model: "iPhone 15 Pro"),
            item("12-pro", fileName: "IMG_1534.jpg", model: "iPhone 12 Pro"),
            item("canon", make: "Canon", model: "Canon EOS R5"),
        ]

        XCTAssertEqual(search(items, "iPhone 15 Pro"), ["15-pro"],
                       "\"15\" in a file name must not make an iPhone 12 Pro match")
    }

    func testVideoIsAKindNotAWordInAFileName() {
        let items = [
            item("clip", fileName: "clip.mov", mimeType: "video/quicktime"),
            item("still", fileName: "video-thumbnail.jpg"),
        ]

        XCTAssertEqual(search(items, "video"), ["clip"])
    }

    func testFavorites() {
        let items = [item("loved", isStarred: true), item("meh")]

        XCTAssertEqual(search(items, "favorites"), ["loved"])
    }

    func testTitlesCaptionsAndLensesAreSearchable() {
        let items = [
            item("titled", title: "Grandma's 90th"),
            item("captioned", caption: "Sunset over the harbour"),
            item("lensed", lens: "iPhone 15 Pro back triple camera 6.765mm f/1.78"),
            item("plain"),
        ]

        XCTAssertEqual(search(items, "grandma"), ["titled"])
        XCTAssertEqual(search(items, "harbour"), ["captioned"])
        XCTAssertEqual(search(items, "triple camera"), ["lensed"])
    }

    func testScreenshotsAreFoundByWhatTheyAre() {
        let items = [item("shot", subtypes: ["screenshot"]), item("photo")]

        XCTAssertEqual(search(items, "screenshot"), ["shot"])
    }

    func testWordsInDifferentFieldsMatchWhenNothingMatchesBetter() {
        let items = [item("trip", model: "iPhone 15 Pro", caption: "Lisbon")]

        XCTAssertEqual(search(items, "lisbon iphone"), ["trip"])
    }

    func testNoMatchesIsAnEmptyAnswer() {
        XCTAssertEqual(search([item("a"), item("b")], "zzqx"), [])
    }

    func testResultsWithinARankAreNewestFirst() {
        let items = [
            item("old", model: "Pixel 8", taken: "2022-01-01T00:00:00Z"),
            item("new", model: "Pixel 8", taken: "2024-01-01T00:00:00Z"),
        ]

        XCTAssertEqual(search(items, "pixel"), ["new", "old"])
    }

    func testCameraNamesDoNotRepeatTheMaker() {
        XCTAssertEqual(SearchIndex.cameraName(make: "Apple", model: "iPhone 15 Pro"), "Apple iPhone 15 Pro")
        XCTAssertEqual(SearchIndex.cameraName(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5")
        XCTAssertNil(SearchIndex.cameraName(make: nil, model: nil))
    }

    func testSuggestionsComeFromTheLibrary() {
        let index = SearchIndex(items: [
            item("a", make: "Apple", model: "iPhone 15 Pro", taken: "2024-01-01T00:00:00Z"),
            item("b", make: "Apple", model: "iPhone 15 Pro", taken: "2023-01-01T00:00:00Z"),
            item("c", make: "Sony", model: "ILCE-7M4", taken: "2023-05-01T00:00:00Z"),
        ])

        XCTAssertEqual(index.cameras(), ["Apple iPhone 15 Pro", "Sony ILCE-7M4"], "most used first")
        XCTAssertEqual(index.years(calendar: utc), [2024, 2023])
        XCTAssertEqual(index.completions(for: "iph", calendar: utc), ["Apple iPhone 15 Pro"])
    }

    /// Epic 11's step 6: under 500 ms on a 50,000-item library. Timed, not estimated — and on a
    /// simulator debug build, which is slower than the release build on a phone.
    func testFiftyThousandItemsAnswerInsideTheBudget() {
        let models = ["iPhone 15 Pro", "iPhone 12", "Pixel 8", "Canon EOS R5", "ILCE-7M4"]
        let base = date("2015-01-01T00:00:00Z")
        let items = (0..<50_000).map { n in
            Fixture.item(id: "p\(n)", fileID: "f\(n)", fileName: "IMG_\(n).HEIC",
                         captureDate: base.addingTimeInterval(Double(n) * 3_600),
                         metadata: MediaMetadata(exif: MediaExif(make: "Make",
                                                                 model: models[n % models.count])))
        }
        let index = SearchIndex(items: items)

        for text in ["iPhone 15 Pro", "June 2018", "IMG_49999.HEIC", "video", "nothing matches"] {
            let query = SearchQuery.parse(text, calendar: utc)
            let start = Date()
            _ = index.search(query, calendar: utc)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 0.5, "“\(text)” took \(Int(elapsed * 1000)) ms")
        }
    }
}

// MARK: - RecentSearchTests

@MainActor
final class RecentSearchTests: XCTestCase {

    func testRecentSearchesAreNewestFirstWithoutRepeats() {
        let sut = AppSettings(defaults: makeTemporaryDefaults())

        sut.recordSearch("june 2024")
        sut.recordSearch("videos")
        sut.recordSearch("June 2024")

        XCTAssertEqual(sut.recentSearches, ["June 2024", "videos"])
    }

    func testTheListIsCappedAndRemembered() {
        let defaults = makeTemporaryDefaults()
        let sut = AppSettings(defaults: defaults)

        for n in 0..<15 { sut.recordSearch("query \(n)") }

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.recentSearches.count, AppSettings.recentSearchLimit)
        XCTAssertEqual(reloaded.recentSearches.first, "query 14")
    }

    func testBlankSearchesAreNotRecordedAndClearEmptiesTheList() {
        let sut = AppSettings(defaults: makeTemporaryDefaults())

        sut.recordSearch("   ")
        XCTAssertTrue(sut.recentSearches.isEmpty)

        sut.recordSearch("beach")
        sut.clearRecentSearches()
        XCTAssertTrue(sut.recentSearches.isEmpty)
    }
}

// MARK: - DetailsEditTests

@MainActor
final class DetailsEditTests: XCTestCase {

    private var sut: PhotoLibraryService!

    override func setUp() async throws {
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        sut = PhotoLibraryService(api: APIClient(session: MockURLProtocol.makeSession()))
        MockURLProtocol.respond(data: Fixture.listingJSON([Fixture.photoJSON(id: "a", fileID: "file-a")]))
        await sut.load()
    }

    override func tearDown() async throws {
        sut.cancelFill()
        MockURLProtocol.reset()
        TestTokens.remove()
        TestServer.reset()
        sut = nil
    }

    private let newDate = date("1998-07-04T15:30:00Z")

    func testAnEditSendsTheDateAndTheTextAndKeepsThem() async throws {
        MockURLProtocol.route([
            (fragment: "/photos/a/metadata", statusCode: 204, body: Data()),
            (fragment: "/photos/a", statusCode: 200,
             body: Data(Fixture.photoJSON(id: "a", fileID: "file-a", captureDate: newDate).utf8)),
        ])

        try await sut.editDetails(id: "a", captureDate: newDate, title: "  Fourth of July ",
                                  caption: "Fireworks", publishingLocation: false)

        let patch = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/photos/a", method: "PATCH"))
        let patchJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
        XCTAssertEqual(patchJSON["captureDate"] as? String, "1998-07-04T15:30:00Z")
        XCTAssertNil(patchJSON["isStarred"], "an edit must not touch the favourite flag")

        let put = try XCTUnwrap(MockURLProtocol.body(forPathContaining: "/metadata", method: "PUT"))
        let putJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: put) as? [String: Any])
        XCTAssertEqual(putJSON["title"] as? String, "Fourth of July", "trimmed")
        XCTAssertEqual(putJSON["caption"] as? String, "Fireworks")

        let edited = try XCTUnwrap(sut.item(id: "a"))
        XCTAssertEqual(edited.captureDate, newDate)
        XCTAssertEqual(edited.metadata?.title, "Fourth of July")
    }

    func testOnlyWhatChangedIsSent() async throws {
        MockURLProtocol.route([(fragment: "/photos/a/metadata", statusCode: 204, body: Data())])
        let unchangedDate = try XCTUnwrap(sut.item(id: "a")?.captureDate)

        try await sut.editDetails(id: "a", captureDate: unchangedDate, title: "Only a title",
                                  caption: nil, publishingLocation: false)

        XCTAssertNil(MockURLProtocol.request { $0.httpMethod == "PATCH" },
                     "the date did not change, so it is not sent")
        XCTAssertNotNil(MockURLProtocol.request { $0.httpMethod == "PUT" })
    }

    func testAServerThatIgnoresTheDateIsReportedAndTheEditUndone() async throws {
        // An older server accepts the PATCH and answers with the photo unchanged.
        MockURLProtocol.route([
            (fragment: "/photos/a", statusCode: 200,
             body: Data(Fixture.photoJSON(id: "a", fileID: "file-a").utf8)),
        ])
        let original = try XCTUnwrap(sut.item(id: "a")?.captureDate)

        do {
            try await sut.editDetails(id: "a", captureDate: newDate, title: nil, caption: nil,
                                      publishingLocation: false)
            XCTFail("expected the edit to be refused")
        } catch PhotoLibraryService.DetailsEditError.dateNotSupported {
            // expected
        }

        XCTAssertEqual(sut.item(id: "a")?.captureDate, original,
                       "the timeline must not keep a date the server did not store")
    }

    func testAFailedWriteRestoresTheItem() async throws {
        MockURLProtocol.route([(fragment: "/photos/a/metadata", statusCode: 500, body: Data())])
        let original = try XCTUnwrap(sut.item(id: "a"))

        do {
            try await sut.editDetails(id: "a", captureDate: try XCTUnwrap(original.captureDate),
                                      title: "Lost", caption: nil, publishingLocation: false)
            XCTFail("expected the edit to fail")
        } catch {}

        XCTAssertNil(sut.item(id: "a")?.metadata?.title)
    }

    func testTitleAndCaptionSurviveTheWireFormat() throws {
        let metadata = MediaMetadata(width: 10, title: "Title", caption: "Caption")

        let decoded = try JSONDecoder().decode(MediaMetadata.self,
                                               from: JSONEncoder().encode(metadata))

        XCTAssertEqual(decoded.title, "Title")
        XCTAssertEqual(decoded.caption, "Caption")
        XCTAssertEqual(decoded.withoutLocation.title, "Title", "redacting location keeps the text")
    }
}
