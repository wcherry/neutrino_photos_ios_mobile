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

    // MARK: - Density

    func testPinchingStepsThroughTheDensitiesAndStopsAtTheEnds() {
        XCTAssertEqual(TimelineGrouping.year.zoomedIn, .month)
        XCTAssertEqual(TimelineGrouping.month.zoomedIn, .day)
        XCTAssertNil(TimelineGrouping.day.zoomedIn, "Days is the innermost step")

        XCTAssertEqual(TimelineGrouping.day.zoomedOut, .month)
        XCTAssertEqual(TimelineGrouping.month.zoomedOut, .year)
        XCTAssertNil(TimelineGrouping.year.zoomedOut, "Years is the outermost step")
    }

    func testZoomingInAndBackOutReturnsToTheSameDensity() {
        for grouping in TimelineGrouping.allCases {
            guard let out = grouping.zoomedOut else { continue }
            XCTAssertEqual(out.zoomedIn, grouping, "\(grouping) does not survive a round trip")
        }
    }

    // MARK: - Columns

    func testAPhoneWidthKeepsTheDesignedColumnCounts() {
        // 393 points — the iPhone 17 Pro the run script defaults to.
        XCTAssertEqual(TimelineGrouping.day.columnCount(forWidth: 393), 3)
        XCTAssertEqual(TimelineGrouping.month.columnCount(forWidth: 393), 4)
        XCTAssertEqual(TimelineGrouping.year.columnCount(forWidth: 393), 5)
    }

    func testAWiderWindowGetsMoreColumnsRatherThanBiggerPictures() {
        // The iPad check in verification step 8: a Split View pane at full width must not be a
        // phone layout stretched to three enormous cells.
        XCTAssertGreaterThan(TimelineGrouping.day.columnCount(forWidth: 1024),
                             TimelineGrouping.day.columnCount(forWidth: 393))
    }

    func testANarrowPaneNeverFallsBelowThePhoneLayout() {
        // 1/3 Split View on an iPad is about 320 points, and one picture per row there would be
        // a worse timeline than three small ones.
        for grouping in TimelineGrouping.allCases {
            XCTAssertGreaterThanOrEqual(grouping.columnCount(forWidth: 320), grouping.columnCount)
            XCTAssertGreaterThanOrEqual(grouping.columnCount(forWidth: 1), grouping.columnCount)
        }
    }

    func testColumnCountNeverRunsAwayOnAVeryWideWindow() {
        for grouping in TimelineGrouping.allCases {
            XCTAssertLessThanOrEqual(grouping.columnCount(forWidth: 10_000), grouping.columnCount * 4)
        }
    }

    func testAnUnmeasuredWidthFallsBackToThePhoneLayout() {
        // The first body pass runs before the GeometryReader has reported anything.
        XCTAssertEqual(TimelineGrouping.day.columnCount(forWidth: 0), 3)
        XCTAssertEqual(TimelineGrouping.day.columnCount(forWidth: .nan), 3)
    }

    // MARK: - Anchoring a density change

    func testTheSectionHoldingADateIsFound() {
        let sections = TimelineSection.sections(
            from: [item("a", "2026-08-18T09:00:00"),
                   item("b", "2026-07-02T09:00:00"),
                   item("c", "2025-12-31T09:00:00")],
            grouping: .month, calendar: calendar)

        let index = TimelineSection.index(containing: date("2026-07-15T00:00:00"), in: sections)

        XCTAssertEqual(index, 1, "15 July belongs to the July section, not to August")
    }

    func testAPinchFromDaysToYearsLandsOnTheSameYear() {
        // Verification step 2: zooming out must not jump to the top of the library.
        let items = [item("a", "2026-08-18T09:00:00"),
                     item("b", "2024-03-04T09:00:00"),
                     item("c", "2021-01-09T09:00:00")]
        let days = TimelineSection.sections(from: items, grouping: .day, calendar: calendar)
        let years = TimelineSection.sections(from: items, grouping: .year, calendar: calendar)

        // Standing on the middle day, then regrouping.
        let anchor = days[1].start
        let index = TimelineSection.index(containing: anchor, in: years)

        XCTAssertEqual(calendar.component(.year, from: years[index!].start), 2024)
    }

    func testADateOlderThanTheLibraryAnchorsToItsEnd() {
        let sections = TimelineSection.sections(from: [item("a", "2026-08-18T09:00:00")],
                                                grouping: .day, calendar: calendar)

        XCTAssertEqual(TimelineSection.index(containing: date("1999-01-01T00:00:00"), in: sections), 0,
                       "there is only one section, so it is the only place to go")
        XCTAssertEqual(TimelineSection.index(containing: date("2030-01-01T00:00:00"), in: sections), 0)
    }

    func testAnchoringAnEmptyTimelineAnswersWithNothing() {
        XCTAssertNil(TimelineSection.index(containing: Date(), in: []))
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
