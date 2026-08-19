import XCTest
@testable import NeutrinoPhotos

// MARK: - TimelineScrubberTests

/// The scrubber's arithmetic, which is the half of fast-scroll that cannot be checked by looking at
/// it: "the thumb is a section out two years back" is invisible in a screenshot.
final class TimelineScrubberTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    // MARK: - Track shape

    func testTheTrackStartsAtTheTopAndEndsBeforeTheBottom() {
        let scrubber = TimelineScrubber(sections: sections(perDay: [1, 1, 1, 1]), columns: 3)

        XCTAssertEqual(scrubber.stops.count, 4)
        XCTAssertEqual(scrubber.stops[0].position, 0, accuracy: 0.0001,
                       "the newest section is the top of the track")
        XCTAssertLessThan(scrubber.stops[3].position, 1,
                          "the last section's *top* is not the bottom of the track — it has height")
    }

    func testStopsAscendDownTheTrack() {
        let scrubber = TimelineScrubber(sections: sections(perDay: [40, 3, 12, 1, 7]), columns: 3)

        for (earlier, later) in zip(scrubber.stops, scrubber.stops.dropFirst()) {
            XCTAssertLessThan(earlier.position, later.position,
                              "a section cannot start above the one before it")
        }
    }

    // MARK: - Weighting

    func testALongSectionTakesMoreOfTheTrackThanAShortOne() {
        // The bug this exists to prevent: splitting the track evenly between sections, so a holiday
        // weekend of 400 pictures and the Tuesday either side of it each get a third. The thumb
        // then crawls through thirty screens and leaps a year in a millimetre.
        let scrubber = TimelineScrubber(sections: sections(perDay: [300, 1, 1]), columns: 3)

        let firstShare = scrubber.stops[1].position - scrubber.stops[0].position
        let secondShare = scrubber.stops[2].position - scrubber.stops[1].position

        XCTAssertGreaterThan(firstShare, 0.9, "300 pictures should be nearly the whole track")
        XCTAssertLessThan(secondShare, 0.05)
    }

    func testFewerColumnsMakeTheSameSectionTaller() {
        let wide = TimelineScrubber(sections: sections(perDay: [60, 1]), columns: 6)
        let narrow = TimelineScrubber(sections: sections(perDay: [60, 1]), columns: 2)

        XCTAssertGreaterThan(narrow.stops[1].position, wide.stops[1].position,
                             "the same 60 pictures occupy more rows, so more of the track")
    }

    // MARK: - Reading the track

    func testEveryPointOnTheTrackResolvesToTheSectionItIsInside() {
        let scrubber = TimelineScrubber(sections: sections(perDay: [9, 4, 30, 2, 15, 6]), columns: 3)

        for stop in scrubber.stops {
            // Just inside the top of each section has to answer with that section, which is the
            // property a binary search gets wrong at the boundary if it is written slightly wrong.
            XCTAssertEqual(scrubber.stop(atPosition: stop.position)?.sectionID, stop.sectionID)
            XCTAssertEqual(scrubber.stop(atPosition: stop.position + 0.0001)?.sectionID, stop.sectionID)
        }
    }

    func testAPositionRoundTripsThroughItsSection() {
        let scrubber = TimelineScrubber(sections: sections(perDay: [5, 20, 3, 40, 1]), columns: 4)

        for probe in stride(from: 0.0, through: 1.0, by: 0.02) {
            guard let stop = scrubber.stop(atPosition: probe),
                  let position = scrubber.position(ofSectionID: stop.sectionID) else {
                return XCTFail("every point on the track is inside some section")
            }
            XCTAssertLessThanOrEqual(position, probe + 0.0001,
                                     "a section cannot begin below the point that selected it")
        }
    }

    func testADragOffTheEndsOfTheTrackPinsRatherThanFails() {
        let scrubber = TimelineScrubber(sections: sections(perDay: [1, 1, 1]), columns: 3)

        XCTAssertEqual(scrubber.stop(atPosition: -5)?.sectionID, scrubber.stops.first?.sectionID)
        XCTAssertEqual(scrubber.stop(atPosition: 9)?.sectionID, scrubber.stops.last?.sectionID)
    }

    func testAnUnknownSectionHasNoPosition() {
        let scrubber = TimelineScrubber(sections: sections(perDay: [1, 1]), columns: 3)
        XCTAssertNil(scrubber.position(ofSectionID: "day-not-in-this-timeline"))
    }

    // MARK: - Whether to draw it at all

    func testAShortTimelineDoesNotEarnAScrubber() {
        // A library that fits in a screen or two is faster to flick than to aim at.
        XCTAssertFalse(TimelineScrubber(sections: sections(perDay: [3, 3]), columns: 3).isUseful)
        XCTAssertFalse(TimelineScrubber(sections: [], columns: 3).isUseful)
    }

    func testALongTimelineDoesEarnOne() {
        XCTAssertTrue(TimelineScrubber(sections: sections(perDay: Array(repeating: 4, count: 40)),
                                       columns: 3).isUseful)
    }

    func testAnEmptyTimelineHasNoStopsAndNoDivisionByZero() {
        let scrubber = TimelineScrubber(sections: [], columns: 3)

        XCTAssertTrue(scrubber.stops.isEmpty)
        XCTAssertNil(scrubber.stop(atPosition: 0.5))
    }

    func testZeroColumnsIsTreatedAsOneRatherThanCrashing() {
        // Nothing should pass 0, but the first body pass measures a width of zero and the column
        // count is derived from it — a divide-by-zero here would be a launch crash.
        let scrubber = TimelineScrubber(sections: sections(perDay: [5, 5, 5]), columns: 0)

        XCTAssertEqual(scrubber.stops.count, 3)
    }

    // MARK: - Helpers

    /// Sections on consecutive days, newest first, with the given item counts.
    private func sections(perDay counts: [Int]) -> [TimelineSection] {
        var items: [MediaItem] = []
        let base = date("2026-08-18T12:00:00")

        for (dayOffset, count) in counts.enumerated() {
            let day = calendar.date(byAdding: .day, value: -dayOffset, to: base)!
            for index in 0..<count {
                items.append(Fixture.item(id: "d\(dayOffset)-i\(index)",
                                          captureDate: calendar.date(byAdding: .minute,
                                                                     value: -index, to: day)!))
            }
        }
        return TimelineSection.sections(from: items, grouping: .day, calendar: calendar, now: base)
    }

    private func date(_ timestamp: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: timestamp)!
    }
}
