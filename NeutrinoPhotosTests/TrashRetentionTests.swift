import XCTest
@testable import NeutrinoPhotos

// MARK: - TrashRetentionTests

/// The countdown shown on a trashed item.
///
/// Worth testing rather than eyeballing because every bug here is off-by-one and invisible: a
/// countdown that says "30 days left" forever, or "-3 days left", or one that loses a day because
/// the photograph was deleted in the evening.
final class TrashRetentionTests: XCTestCase {

    /// A fixed calendar in UTC, so a test does not pass in London and fail in Auckland.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: iso)!
    }

    // MARK: - Not in the trash

    func testALiveItemHasNoCountdown() {
        let item = Fixture.item(deletedAt: nil)
        XCTAssertNil(TrashRetention.daysRemaining(for: item, calendar: calendar))
        XCTAssertNil(TrashRetention.caption(for: item, calendar: calendar))
    }

    // MARK: - The arithmetic

    func testAFreshlyDeletedItemHasTheFullWindow() {
        let item = Fixture.item(deletedAt: date("2026-08-01T09:00:00"))
        let remaining = TrashRetention.daysRemaining(for: item,
                                                     now: date("2026-08-01T09:00:01"),
                                                     calendar: calendar)
        XCTAssertEqual(remaining, TrashRetention.days)
    }

    func testTheCountdownDoesNotLoseADayToAnEveningDeletion() {
        // The bug this exists for: counting between two *instants* makes an item deleted at 23:00
        // report one day fewer than the same item deleted that morning, because 30 days later minus
        // "now" is 29 days and 1 hour, which truncates to 29.
        let morning = Fixture.item(deletedAt: date("2026-08-01T08:00:00"))
        let evening = Fixture.item(deletedAt: date("2026-08-01T23:00:00"))
        let now = date("2026-08-02T12:00:00")

        XCTAssertEqual(TrashRetention.daysRemaining(for: morning, now: now, calendar: calendar),
                       TrashRetention.daysRemaining(for: evening, now: now, calendar: calendar))
    }

    func testTheCountdownFallsByOneEachDay() {
        let item = Fixture.item(deletedAt: date("2026-08-01T09:00:00"))

        XCTAssertEqual(TrashRetention.daysRemaining(for: item, now: date("2026-08-02T09:00:00"),
                                                    calendar: calendar), 29)
        XCTAssertEqual(TrashRetention.daysRemaining(for: item, now: date("2026-08-10T09:00:00"),
                                                    calendar: calendar), 21)
    }

    func testAnExpiredItemClampsAtZeroRatherThanGoingNegative() {
        let item = Fixture.item(deletedAt: date("2026-06-01T09:00:00"))
        let remaining = TrashRetention.daysRemaining(for: item,
                                                     now: date("2026-08-19T09:00:00"),
                                                     calendar: calendar)
        XCTAssertEqual(remaining, 0, "\"-79 days left\" is a bug report, not a caption")
    }

    // MARK: - The caption

    func testTheCaptionReadsNaturallyAtEachBoundary() {
        let deletedAt = date("2026-08-01T09:00:00")
        let item = Fixture.item(deletedAt: deletedAt)

        func caption(on day: String) -> String? {
            TrashRetention.caption(for: item, now: date(day), calendar: calendar)
        }

        XCTAssertEqual(caption(on: "2026-08-02T09:00:00"), "29 days left")
        XCTAssertEqual(caption(on: "2026-08-30T09:00:00"), "1 day left")
        XCTAssertEqual(caption(on: "2026-08-31T09:00:00"), "Deleting soon")
        XCTAssertEqual(caption(on: "2026-09-15T09:00:00"), "Deleting soon")
    }

    // MARK: - The wire

    func testDeletedAtIsDecodedFromATrashListing() throws {
        let json = """
        {"photos":[\(Fixture.photoJSON(id: "gone",
                                       deletedAt: Date(timeIntervalSince1970: 1_700_200_000)))],
         "total":1}
        """
        struct Response: Decodable { let photos: [MediaItem] }
        let response = try PhotoLibraryService.decoder.decode(Response.self, from: Data(json.utf8))

        let deletedAt = try XCTUnwrap(response.photos.first?.deletedAt)
        XCTAssertEqual(deletedAt.timeIntervalSince1970, 1_700_200_000, accuracy: 1)
    }

    func testAnItemFromAServerThatDoesNotSendDeletedAtSimplyHasNoCountdown() throws {
        // The field is new. A build of this app talking to an older server, or a row cached before
        // the local schema gained the column, must show no countdown rather than a wrong one.
        let json = """
        {"id":"p","fileId":"f","fileName":"a.jpg","mimeType":"image/jpeg","sizeBytes":1,
         "contentUrl":"/x","thumbnail":null,"thumbnailMimeType":null,"isStarred":false,
         "isArchived":false,"captureDate":null,"createdAt":"2026-08-01T00:00:00.000000000+00:00",
         "updatedAt":"2026-08-01T00:00:00.000000000+00:00","metadata":null}
        """
        let item = try PhotoLibraryService.decoder.decode(MediaItem.self, from: Data(json.utf8))

        XCTAssertNil(item.deletedAt)
        XCTAssertNil(TrashRetention.caption(for: item, calendar: calendar))
    }
}
