import XCTest
@testable import NeutrinoPhotos

// MARK: - TimelineCacheTests

/// The memoization the timeline's smoothness rests on.
///
/// Verification step 1 asks for no stutter below 55fps while scrolling the whole library, and step 9
/// for memory that plateaus. Both are settled on a device with Instruments — but the specific bug
/// they would catch is a body pass that regroups two thousand photographs, and that *is* checkable
/// here: the assertion is simply that the work does not happen twice for the same inputs.
final class TimelineCacheTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    // MARK: - Recomputing

    func testTheFirstPassGroupsTheLibrary() {
        let cache = TimelineCache()
        let items = library(count: 30)

        let didWork = cache.refresh(inputs(revision: 1)) { items }

        XCTAssertTrue(didWork)
        XCTAssertEqual(cache.recomputeCount, 1)
        XCTAssertEqual(cache.items.count, 30)
        XCTAssertFalse(cache.sections.isEmpty)
    }

    func testRepeatedPassesWithTheSameInputsAreFree() {
        // This is the whole point of the type: `body` now runs on scroll frames, because the
        // scrubber and the pinch both read scroll geometry.
        let cache = TimelineCache()
        var sourceCalls = 0

        for _ in 0..<60 {
            cache.refresh(inputs(revision: 1)) {
                sourceCalls += 1
                return self.library(count: 2_000)
            }
        }

        XCTAssertEqual(cache.recomputeCount, 1)
        XCTAssertEqual(sourceCalls, 1, "the filter and sort behind the closure must not run either")
    }

    func testANewRevisionRegroups() {
        let cache = TimelineCache()
        cache.refresh(inputs(revision: 1)) { self.library(count: 3) }

        cache.refresh(inputs(revision: 2)) { self.library(count: 4) }

        XCTAssertEqual(cache.recomputeCount, 2)
        XCTAssertEqual(cache.items.count, 4)
    }

    func testChangingTheDensityRegroups() {
        let cache = TimelineCache()
        let items = library(count: 40)
        cache.refresh(inputs(revision: 1, grouping: .day)) { items }
        let days = cache.sections.count

        cache.refresh(inputs(revision: 1, grouping: .year)) { items }

        XCTAssertEqual(cache.recomputeCount, 2)
        XCTAssertLessThan(cache.sections.count, days, "years collapse days")
    }

    func testTogglingShowArchivedRegroups() {
        // Same revision and same density — only the filter changed, and missing that would leave
        // archived photographs on screen after the switch was turned off.
        let cache = TimelineCache()
        cache.refresh(inputs(revision: 1, showsArchived: false)) { self.library(count: 5) }

        cache.refresh(inputs(revision: 1, showsArchived: true)) { self.library(count: 8) }

        XCTAssertEqual(cache.recomputeCount, 2)
        XCTAssertEqual(cache.items.count, 8)
    }

    func testTheOutputSurvivesPassesThatDidNothing() {
        let cache = TimelineCache()
        cache.refresh(inputs(revision: 1)) { self.library(count: 12) }

        cache.refresh(inputs(revision: 1)) { [] }

        XCTAssertEqual(cache.items.count, 12, "a no-op pass must not empty the timeline")
    }

    // MARK: - Grouping is the same as doing it directly

    func testTheCachedGroupingMatchesAnUncachedOne() {
        let cache = TimelineCache()
        let items = library(count: 50)

        cache.refresh(inputs(revision: 1, grouping: .month)) { items }

        let direct = TimelineSection.sections(from: items, grouping: .month)
        XCTAssertEqual(cache.sections.map(\.id), direct.map(\.id))
        XCTAssertEqual(cache.sections.map { $0.items.count }, direct.map { $0.items.count })
    }

    // MARK: - Helpers

    private func inputs(revision: Int,
                        grouping: TimelineGrouping = .day,
                        showsArchived: Bool = false) -> TimelineCache.Inputs {
        TimelineCache.Inputs(revision: revision, grouping: grouping, showsArchived: showsArchived)
    }

    /// A library spread over consecutive days, newest first — what the timeline actually receives.
    private func library(count: Int) -> [MediaItem] {
        let base = Date(timeIntervalSince1970: 1_755_000_000)
        return (0..<count).map { index in
            Fixture.item(id: "photo-\(index)",
                         captureDate: calendar.date(byAdding: .hour, value: -index * 5, to: base)!)
        }
    }
}
