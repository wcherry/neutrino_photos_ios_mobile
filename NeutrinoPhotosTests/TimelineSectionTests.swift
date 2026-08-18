import XCTest
@testable import NeutrinoPhotos

// MARK: - TimelineSectionTests

/// Grouping is where a photo library quietly gets dates wrong, so it is asserted against a pinned
/// calendar rather than eyeballed in a screenshot.
final class TimelineSectionTests: XCTestCase {

    /// Fixed zone and locale: a section boundary that depends on where the test machine is would
    /// pass in one office and fail in another.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    // MARK: - Grouping

    func testItemsAreGroupedByDayNewestFirst() {
        let items = [
            item("a", "2026-08-18T09:00:00"),
            item("b", "2026-08-18T21:30:00"),
            item("c", "2026-08-17T12:00:00"),
        ]

        let sections = TimelineSection.sections(from: items, grouping: .day, calendar: calendar,
                                                now: date("2026-08-20T12:00:00"))

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].items.map(\.id), ["b", "a"], "newest first inside a section too")
        XCTAssertEqual(sections[1].items.map(\.id), ["c"])
    }

    func testMonthAndYearCollapseTheSameItems() {
        let items = [
            item("a", "2026-08-18T09:00:00"),
            item("b", "2026-07-02T09:00:00"),
            item("c", "2025-12-31T09:00:00"),
        ]

        XCTAssertEqual(TimelineSection.sections(from: items, grouping: .day, calendar: calendar).count, 3)
        XCTAssertEqual(TimelineSection.sections(from: items, grouping: .month, calendar: calendar).count, 3)
        XCTAssertEqual(TimelineSection.sections(from: items, grouping: .year, calendar: calendar).count, 2)
    }

    func testAnEveningPhotographStaysOnItsOwnEvening() {
        // 23:30 local on 18 August is 22:30 UTC — still the 18th. The failure this guards against
        // is grouping in UTC, which files a late-evening photograph under the following day for
        // anyone east of Greenwich in summer.
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        paris.locale = Locale(identifier: "en_GB")

        let sections = TimelineSection.sections(
            from: [item("late", "2026-08-18T23:30:00", in: paris)],
            grouping: .day, calendar: paris, now: date("2026-08-25T12:00:00"))

        XCTAssertEqual(paris.component(.day, from: sections[0].start), 18)
    }

    func testCaptureDateWinsOverUploadDate() {
        // A photograph taken in 2019 and uploaded today belongs in 2019.
        let taken = date("2019-06-01T10:00:00")
        let uploaded = date("2026-08-18T10:00:00")
        let media = Fixture.item(id: "old", captureDate: taken, createdAt: uploaded)

        let sections = TimelineSection.sections(from: [media], grouping: .year, calendar: calendar)

        XCTAssertEqual(calendar.component(.year, from: sections[0].start), 2019)
    }

    func testItemsWithNoCaptureDateFallBackToTheUploadDate() {
        let uploaded = date("2026-08-18T10:00:00")
        let media = Fixture.item(id: "no-exif", captureDate: nil, createdAt: uploaded)

        let sections = TimelineSection.sections(from: [media], grouping: .day, calendar: calendar,
                                                now: date("2026-08-20T12:00:00"))

        XCTAssertEqual(calendar.component(.day, from: sections[0].start), 18)
    }

    func testEmptyInputProducesNoSections() {
        XCTAssertTrue(TimelineSection.sections(from: [], grouping: .day, calendar: calendar).isEmpty)
    }

    // MARK: - Titles

    func testTodayAndYesterdayAreNamed() {
        let now = date("2026-08-18T12:00:00")
        let sections = TimelineSection.sections(
            from: [item("today", "2026-08-18T09:00:00"), item("yesterday", "2026-08-17T09:00:00")],
            grouping: .day, calendar: calendar, now: now)

        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[1].title, "Yesterday")
    }

    func testAnOlderDayIsNamedWithItsDate() {
        let sections = TimelineSection.sections(from: [item("a", "2024-03-04T09:00:00")],
                                                grouping: .day, calendar: calendar,
                                                now: date("2026-08-18T12:00:00"))

        XCTAssertTrue(sections[0].title.contains("2024"), "an older year has to be in the heading")
        XCTAssertTrue(sections[0].title.contains("March"))
    }

    func testYearGroupingIsTitledWithTheYearAlone() {
        let sections = TimelineSection.sections(from: [item("a", "2024-03-04T09:00:00")],
                                                grouping: .year, calendar: calendar)
        XCTAssertEqual(sections[0].title, "2024")
    }

    // MARK: - Identity

    func testSectionIDsAreStableAcrossReloads() {
        let items = [item("a", "2026-08-18T09:00:00")]
        let first = TimelineSection.sections(from: items, grouping: .day, calendar: calendar)
        let second = TimelineSection.sections(from: items, grouping: .day, calendar: calendar)

        XCTAssertEqual(first[0].id, second[0].id, "an unstable id resets the scroll on every refresh")
    }

    // MARK: - Helpers

    private func item(_ id: String, _ timestamp: String,
                      in calendar: Calendar? = nil) -> MediaItem {
        Fixture.item(id: id, captureDate: date(timestamp, in: calendar ?? self.calendar))
    }

    private func date(_ timestamp: String, in calendar: Calendar? = nil) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = (calendar ?? self.calendar).timeZone
        return formatter.date(from: timestamp)!
    }
}
