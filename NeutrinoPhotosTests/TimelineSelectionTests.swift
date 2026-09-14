import XCTest
@testable import NeutrinoPhotos

// MARK: - TimelineSelectionTests

/// Multi-select, asserted where the epic's verification step 7 can actually be checked: "50 items →
/// count is correct, Select All works, Deselect clears" is a statement about this type, and a
/// screenshot of a grid with fifty ticks in it proves considerably less.
final class TimelineSelectionTests: XCTestCase {

    // MARK: - Entering and leaving

    func testATimelineStartsOutOfSelectionMode() {
        let selection = TimelineSelection()

        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.count, 0)
    }

    func testALongPressEntersTheModeWithThatItemAlreadySelected() {
        // Entering with nothing selected would need a second tap before anything could be done.
        var selection = TimelineSelection()

        selection.begin(with: "photo-7")

        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.contains("photo-7"))
        XCTAssertEqual(selection.count, 1)
    }

    func testTheMenuEntersTheModeWithNothingSelected() {
        var selection = TimelineSelection()

        selection.begin()

        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.isEmpty)
    }

    func testDoneLeavesTheModeAndForgetsWhatWasSelected() {
        var selection = TimelineSelection()
        selection.begin(with: "a")
        selection.toggle("b")

        selection.end()

        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.count, 0)
    }

    // MARK: - Selecting

    func testTappingAnItemTwiceSelectsAndDeselectsIt() {
        var selection = TimelineSelection()
        selection.begin()

        selection.toggle("a")
        XCTAssertTrue(selection.contains("a"))

        selection.toggle("a")
        XCTAssertFalse(selection.contains("a"))
        XCTAssertTrue(selection.isActive, "deselecting the last item does not leave the mode")
    }

    func testSelectAllTakesTheWholeTimelineAndTheCountIsRight() {
        let items = (0..<50).map { Fixture.item(id: "photo-\($0)") }
        var selection = TimelineSelection()
        selection.begin()

        selection.selectAll(in: items)

        XCTAssertEqual(selection.count, 50)
        XCTAssertTrue(selection.coversAll(of: items))
    }

    func testDeselectAllClearsTheSelectionButStaysInTheMode() {
        // The distinction the type exists for: "Deselect All" is not "Done", and collapsing the
        // two makes the button exit a mode the user asked to stay in.
        let items = (0..<50).map { Fixture.item(id: "photo-\($0)") }
        var selection = TimelineSelection()
        selection.begin()
        selection.selectAll(in: items)

        selection.deselectAll()

        XCTAssertEqual(selection.count, 0)
        XCTAssertTrue(selection.isActive)
    }

    func testAPartialSelectionDoesNotCoverEverything() {
        let items = (0..<10).map { Fixture.item(id: "photo-\($0)") }
        var selection = TimelineSelection()
        selection.begin(with: "photo-3")

        XCTAssertFalse(selection.coversAll(of: items),
                       "the button has to still read Select All")
    }

    func testAnEmptyTimelineIsNotCovered() {
        // Otherwise the toolbar offers to deselect a library with nothing in it.
        var selection = TimelineSelection()
        selection.begin()

        // Spelled out rather than `[]`: the query is generic over anything with a `String` id now
        // — the device-library album selects with the same type — so a bare empty literal has
        // nothing to infer an element type from.
        XCTAssertFalse(selection.coversAll(of: [MediaItem]()))
    }

    // MARK: - Resolving against the library

    func testResolvingReturnsTheSelectedItemsInTimelineOrder() {
        let items = ["a", "b", "c", "d"].map { Fixture.item(id: $0) }
        var selection = TimelineSelection()
        selection.begin()
        selection.toggle("d")
        selection.toggle("b")

        XCTAssertEqual(selection.resolve(in: items).map(\.id), ["b", "d"],
                       "the order comes from the timeline, not from the order of tapping")
    }

    func testAnItemThatLeavesTheLibraryDropsOutOfTheSelection() {
        // A sync, or a delete on another device, mid-selection. A bulk action must not go on to
        // address something the library no longer has.
        let items = ["a", "b", "c"].map { Fixture.item(id: $0) }
        var selection = TimelineSelection()
        selection.begin()
        selection.selectAll(in: items)

        let remaining = ["a", "c"].map { Fixture.item(id: $0) }
        selection.prune(against: remaining)

        XCTAssertEqual(selection.count, 2)
        XCTAssertFalse(selection.contains("b"))
        XCTAssertEqual(selection.resolve(in: remaining).map(\.id), ["a", "c"])
    }

    func testResolvingSkipsIdsTheLibraryNoLongerHasEvenBeforeAPrune() {
        let items = ["a"].map { Fixture.item(id: $0) }
        var selection = TimelineSelection()
        selection.begin()
        selection.toggle("a")
        selection.toggle("gone")

        XCTAssertEqual(selection.resolve(in: items).map(\.id), ["a"])
    }
}
