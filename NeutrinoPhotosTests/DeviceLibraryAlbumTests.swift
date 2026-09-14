import XCTest
@testable import NeutrinoPhotos

// MARK: - DeviceAssetSelectionTests

/// ``TimelineSelection`` driven over ``ScannedAsset`` rather than ``MediaItem``.
///
/// The device album selects with the same type the timeline does — see the note on that type for
/// why — so what is worth asserting here is not the toggling, which `TimelineSelectionTests`
/// already covers, but that the generic queries actually resolve against a device listing and
/// behave when that listing changes underneath a selection. The library on a phone changes for
/// reasons this app does not control: a photo taken in the camera, an item deleted in Apple Photos,
/// a limited grant narrowed in Settings.
final class DeviceAssetSelectionTests: XCTestCase {

    private func asset(_ identifier: String) -> ScannedAsset {
        ScannedAsset(localIdentifier: identifier, creationDate: nil, isVideo: false,
                     pixelWidth: 4032, pixelHeight: 3024, duration: 0)
    }

    func testAnAssetIsIdentifiedByItsPhotosIdentifier() {
        XCTAssertEqual(asset("ABC-123/L0/001").id, "ABC-123/L0/001")
    }

    func testResolvingKeepsTheGridsOrderRatherThanTheOrderTheyWereTapped() {
        // The resolved order is the upload order, and the grid's order is newest first. Tapping
        // three pictures bottom-to-top must not upload them oldest first.
        let listing = [asset("newest"), asset("middle"), asset("oldest")]
        var selection = TimelineSelection()
        selection.begin()
        selection.toggle("oldest")
        selection.toggle("newest")

        XCTAssertEqual(selection.resolve(in: listing).map(\.localIdentifier), ["newest", "oldest"])
    }

    func testSelectAllOverADeviceListingSelectsEveryItem() {
        let listing = (0..<50).map { asset("asset-\($0)") }
        var selection = TimelineSelection()
        selection.begin()

        selection.selectAll(in: listing)

        XCTAssertEqual(selection.count, 50)
        XCTAssertTrue(selection.coversAll(of: listing))
    }

    func testAnItemDeletedFromThePhoneDropsOutOfTheSelection() {
        // Otherwise Upload reports "3 items" and queues two, or queues an identifier Photos no
        // longer answers for.
        var selection = TimelineSelection()
        selection.begin()
        selection.selectAll(in: [asset("a"), asset("b"), asset("c")])

        selection.prune(against: [asset("a"), asset("c")])

        XCTAssertEqual(selection.count, 2)
        XCTAssertFalse(selection.contains("b"))
    }

    func testAnEmptyListingNeverCountsAsFullySelected() {
        // What decides whether the toolbar offers Select All or Deselect All. A phone with no
        // photographs on it must not offer to deselect them.
        var selection = TimelineSelection()
        selection.begin()

        XCTAssertFalse(selection.coversAll(of: [ScannedAsset]()))
    }
}

// MARK: - DeviceLibraryFilterTests

/// The device album's derived shape, and the property the type exists for: that a body pass which
/// changes nothing costs nothing.
///
/// That is not a micro-optimisation to assert out of habit. ``DeviceLibraryView`` draws an upload
/// progress bar from a fraction published several times a second, so its body runs at that rate
/// while an upload is going — and the filter it reads runs over the whole camera roll. Without the
/// memoization the grid stops scrolling during exactly the operation the screen exists to start.
final class DeviceLibraryFilterTests: XCTestCase {

    private func listing(_ count: Int) -> [ScannedAsset] {
        (0..<count).map {
            ScannedAsset(localIdentifier: "asset-\($0)", creationDate: nil, isVideo: false,
                         pixelWidth: 4032, pixelHeight: 3024, duration: 0)
        }
    }

    /// Every even-numbered asset has been uploaded.
    private func evensImported(_ identifier: String) -> Bool {
        Int(identifier.dropFirst("asset-".count)).map { $0 % 2 == 0 } ?? false
    }

    private func inputs(revision: Int = 1, importedCount: Int = 5,
                        hidesUploaded: Bool = false) -> DeviceLibraryFilter.Inputs {
        DeviceLibraryFilter.Inputs(revision: revision, importedCount: importedCount,
                                   hidesUploaded: hidesUploaded)
    }

    // MARK: - Filtering

    func testEverythingIsVisibleWhenTheFilterIsOff() {
        let filter = DeviceLibraryFilter()

        filter.refresh(inputs(hidesUploaded: false), source: { self.listing(10) },
                       isImported: evensImported)

        XCTAssertEqual(filter.visible.count, 10)
        XCTAssertEqual(filter.uploadedCount, 5)
        XCTAssertEqual(filter.visibleUploadedCount, 5)
    }

    func testTurningTheFilterOnHidesWhatIsAlreadyUploaded() {
        let filter = DeviceLibraryFilter()

        filter.refresh(inputs(hidesUploaded: true), source: { self.listing(10) },
                       isImported: evensImported)

        XCTAssertEqual(filter.visible.map(\.localIdentifier),
                       ["asset-1", "asset-3", "asset-5", "asset-7", "asset-9"])
        // Still the count over the *whole* phone, which is what the empty state's sentence is about.
        XCTAssertEqual(filter.uploadedCount, 5)
        // Nothing visible needs uploading, so Select All would select nothing redundant.
        XCTAssertEqual(filter.visibleUploadedCount, 0)
    }

    func testFilteringPreservesTheListingsOrder() {
        // The visible order is the upload order. Newest first has to survive the filter.
        let filter = DeviceLibraryFilter()

        filter.refresh(inputs(hidesUploaded: true), source: { self.listing(100) },
                       isImported: evensImported)

        let indices = filter.visible.compactMap { Int($0.localIdentifier.dropFirst(6)) }
        XCTAssertEqual(indices, indices.sorted(), "the browser's order is not re-sorted")
    }

    // MARK: - Memoization

    func testABodyPassThatChangesNothingDoesNoWork() {
        let filter = DeviceLibraryFilter()
        let key = inputs()
        filter.refresh(key, source: { self.listing(10) }, isImported: evensImported)

        for _ in 0..<200 {
            filter.refresh(key, source: {
                XCTFail("the listing must not be re-read on an unchanged pass")
                return []
            }, isImported: { _ in false })
        }

        XCTAssertEqual(filter.recomputeCount, 1)
    }

    func testANewListingRebuilds() {
        let filter = DeviceLibraryFilter()
        filter.refresh(inputs(revision: 1), source: { self.listing(10) },
                       isImported: evensImported)

        filter.refresh(inputs(revision: 2), source: { self.listing(20) },
                       isImported: evensImported)

        XCTAssertEqual(filter.recomputeCount, 2)
        XCTAssertEqual(filter.visible.count, 20)
    }

    func testAnUploadFinishingRebuilds() {
        // The ledger's count is what stands in for "which items are uploaded". If a change in it did
        // not rebuild, a photograph would keep its un-uploaded look until something else moved.
        let filter = DeviceLibraryFilter()
        filter.refresh(inputs(importedCount: 5), source: { self.listing(10) },
                       isImported: evensImported)

        filter.refresh(inputs(importedCount: 6), source: { self.listing(10) },
                       isImported: { _ in true })

        XCTAssertEqual(filter.recomputeCount, 2)
        XCTAssertEqual(filter.uploadedCount, 10)
    }

    func testTogglingTheFilterRebuilds() {
        let filter = DeviceLibraryFilter()
        filter.refresh(inputs(hidesUploaded: false), source: { self.listing(10) },
                       isImported: evensImported)

        filter.refresh(inputs(hidesUploaded: true), source: { self.listing(10) },
                       isImported: evensImported)

        XCTAssertEqual(filter.recomputeCount, 2)
        XCTAssertEqual(filter.visible.count, 5)
    }

    // MARK: - Scale

    func testAFiftyThousandItemRollFiltersOnceAndThenIsFree() {
        // The acceptance library is ~2,000 items; this is the order of magnitude a real phone
        // reaches. One pass has to be quick, and the next two hundred have to be nothing at all.
        let filter = DeviceLibraryFilter()
        let roll = listing(50_000)
        let key = inputs()

        measure {
            filter.refresh(key, source: { roll }, isImported: self.evensImported)
        }

        XCTAssertEqual(filter.recomputeCount, 1, "only the very first pass did any work")
        XCTAssertEqual(filter.visible.count, 50_000)
    }
}

// MARK: - DeviceAssetDurationTests

/// The clock length drawn on a video cell.
final class DeviceAssetDurationTests: XCTestCase {

    func testSecondsAreZeroPaddedAgainstTheMinute() {
        // The bug this guards: "1:2" for 62 seconds, which reads as a minute and two *minutes*.
        XCTAssertEqual(DeviceAssetThumbnailView.durationText(62), "1:02")
        XCTAssertEqual(DeviceAssetThumbnailView.durationText(7), "0:07")
        XCTAssertEqual(DeviceAssetThumbnailView.durationText(600), "10:00")
    }

    func testAnHourLongClipGetsAnHoursField() {
        XCTAssertEqual(DeviceAssetThumbnailView.durationText(3_723), "1:02:03")
    }

    func testAPhotographHasNoDuration() {
        // Every still comes through with a duration of zero, and "0:00" on a photograph is wrong
        // twice — it is not a video, and it is not zero seconds long.
        XCTAssertNil(DeviceAssetThumbnailView.durationText(0))
    }

    func testSubSecondClipsAreNotDrawnAsZero() {
        XCTAssertNil(DeviceAssetThumbnailView.durationText(0.4))
    }
}
