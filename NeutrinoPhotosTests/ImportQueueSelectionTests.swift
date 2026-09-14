import XCTest
@testable import NeutrinoPhotos

// MARK: - PrependImportQueueTests

/// What happens to the import queue when somebody picks forty photographs out of the device-library
/// album and taps Upload.
///
/// The properties here are the ones a selection has and a scan does not. A scan *owns* the queue —
/// it is the work list, and replacing it wholesale is correct. A selection arrives beside whatever
/// is already queued, which makes two things assertable that would otherwise be nobody's job: that
/// an interrupted full-library run is still there afterwards, and that the items just picked are the
/// next ones uploaded rather than the last.
final class PrependImportQueueTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
    }

    private func makeStore(named name: String = "queue.sqlite") throws -> LocalStore {
        try LocalStore(url: directory.appendingPathComponent(name))
    }

    private func items(_ identifiers: [String]) -> [ImportQueueItem] {
        identifiers.enumerated().map { index, identifier in
            ImportQueueItem(localIdentifier: identifier, sortIndex: index,
                            estimatedBytes: 1_000_000)
        }
    }

    // MARK: - Not destroying what is there

    func testASelectionDoesNotDiscardAnInterruptedFullLibraryRun() async throws {
        // The failure this exists to prevent: somebody force-quits mid-import, comes back, browses
        // the device album, uploads four pictures — and silently loses the two thousand still
        // queued from the run before.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items((0..<2_000).map { "scan-\($0)" }))

        try await store.prependImportQueue(with: items(["picked-1", "picked-2"]))

        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.pending, 2_002)
    }

    func testASelectionIsTakenBeforeEverythingAlreadyQueued() async throws {
        // Somebody who just tapped Upload on four pictures is watching for those four, not for the
        // 2,000th item of a library scan started last week.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(["scan-a", "scan-b", "scan-c"]))

        try await store.prependImportQueue(with: items(["picked-1", "picked-2"]))

        let order = try await store.nextPendingImportItems(limit: 10).map(\.localIdentifier)
        XCTAssertEqual(order, ["picked-1", "picked-2", "scan-a", "scan-b", "scan-c"])
    }

    func testASelectionKeepsItsOwnOrderInsideTheQueue() async throws {
        // The grid hands them over newest first, and that is the order they should upload in — an
        // upload stopped halfway has then sent the recent ones.
        let store = try makeStore()

        try await store.prependImportQueue(with: items(["newest", "middle", "oldest"]))

        let order = try await store.nextPendingImportItems(limit: 10).map(\.localIdentifier)
        XCTAssertEqual(order, ["newest", "middle", "oldest"])
    }

    func testTwoSelectionsInARowStayInTheOrderTheyWerePicked() async throws {
        // Each batch goes in front of the queue, so the second batch lands in front of the first.
        // That is the right reading of "front": the most recent tap is the one being watched.
        let store = try makeStore()
        try await store.prependImportQueue(with: items(["first-a", "first-b"]))

        try await store.prependImportQueue(with: items(["second-a", "second-b"]))

        let order = try await store.nextPendingImportItems(limit: 10).map(\.localIdentifier)
        XCTAssertEqual(order, ["second-a", "second-b", "first-a", "first-b"])
    }

    // MARK: - Edges

    func testPrependingOntoAnEmptyQueueWorks() async throws {
        // `MIN(sort_index)` over no rows is NULL, and a base index read wrongly from that would put
        // the very first selection at an index nothing else could ever get in front of.
        let store = try makeStore()

        try await store.prependImportQueue(with: items(["only"]))

        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.pending, 1)
        let next = try await store.nextPendingImportItems().first
        XCTAssertEqual(next?.localIdentifier, "only")
    }

    func testPrependingNothingIsHarmless() async throws {
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(["scan-a"]))

        try await store.prependImportQueue(with: [])

        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.pending, 1)
    }

    func testRepickingAnItemThatFailedRetriesItRatherThanDuplicatingIt() async throws {
        // `local_identifier` is the primary key, so the row is replaced. Its attempt count comes
        // back at zero, which is what somebody deliberately picking it again is asking for.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(["asset-1"]))
        try await store.updateImportItem("asset-1", state: .failed, attempts: 3, error: "no signal")

        try await store.prependImportQueue(with: items(["asset-1"]))

        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.total, 1, "replaced, not added beside itself")
        XCTAssertEqual(counts.pending, 1)
        let row = try await store.nextPendingImportItems().first
        XCTAssertEqual(row?.attempts, 0)
        XCTAssertNil(row?.lastError)
    }

    func testASelectionSurvivesTheAppBeingKilled() async throws {
        let url = directory.appendingPathComponent("interrupted.sqlite")
        let first = try LocalStore(url: url)
        try await first.prependImportQueue(with: items(["picked-1", "picked-2", "picked-3"]))
        try await first.updateImportItem("picked-1", state: .done, attempts: 1)

        // Killed here. Nothing flushed, nothing closed politely.
        let second = try LocalStore(url: url)

        let counts = await second.importQueueCounts()
        XCTAssertEqual(counts.done, 1)
        XCTAssertEqual(counts.pending, 2)
        let next = try await second.nextPendingImportItems().first
        XCTAssertEqual(next?.localIdentifier, "picked-2", "resumes where it stopped")
    }

    // MARK: - What travels with a selection

    func testTheVideoFlagAndSizeEstimateAreCarriedOntoTheRow() async throws {
        // Both are read back by the run: the flag decides which import path an item takes, and the
        // estimate is what the progress bar and the ETA are computed from.
        let store = try makeStore()
        let clip = ScannedAsset(localIdentifier: "clip", creationDate: nil, isVideo: true,
                                pixelWidth: 3840, pixelHeight: 2160, duration: 30)

        try await store.prependImportQueue(with: [
            ImportQueueItem(localIdentifier: clip.localIdentifier, sortIndex: 0,
                            isVideo: clip.isVideo,
                            estimatedBytes: ImportSizeEstimate.bytes(for: clip)),
        ])

        let row = try await store.nextPendingImportItems().first
        XCTAssertEqual(row?.isVideo, true)
        XCTAssertEqual(row?.estimatedBytes, ImportSizeEstimate.bytes(for: clip))
    }
}
