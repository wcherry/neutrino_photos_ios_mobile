import XCTest
import NeutrinoCore
import NeutrinoCrypto
@testable import NeutrinoPhotos

// MARK: - ImportQueueStoreTests

/// The queue table itself: the thing that makes an import survive being killed.
///
/// Written against a real SQLite file in a temporary directory rather than a stub, for the same
/// reason `LocalStoreTests` is — a mocked queue would assert that a dictionary can hold a value,
/// and the property under test is that a *process* can die between two items and lose nothing.
final class ImportQueueStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
    }

    private func makeStore(named name: String = "queue.sqlite") throws -> LocalStore {
        try LocalStore(url: directory.appendingPathComponent(name))
    }

    private func items(_ count: Int, bytes: Int64 = 1_000_000) -> [ImportQueueItem] {
        (0..<count).map {
            ImportQueueItem(localIdentifier: "asset-\($0)", sortIndex: $0, estimatedBytes: bytes)
        }
    }

    // MARK: - Round trip

    func testAQueuedRowSurvivesTheRoundTripIntact() async throws {
        let store = try makeStore()
        let queued = ImportQueueItem(localIdentifier: "asset-1", sortIndex: 7, state: .pending,
                                     attempts: 2, lastError: "the network went away",
                                     isVideo: true, estimatedBytes: 987_654_321,
                                     albumTitles: ["Trip to Rome", "Best of 2024"])

        try await store.replaceImportQueue(with: [queued])
        let read = try await store.nextPendingImportItems(limit: 10).first

        XCTAssertEqual(read, queued)
    }

    func testAlbumTitlesSurviveCharactersThatWouldBreakADelimiter() async throws {
        // A title is whatever somebody typed in Apple Photos, and every separator worth choosing is
        // one an album is named after. Hence JSON.
        let store = try makeStore()
        let titles = ["Rome, 2024", "Ben's | Party", "a\nnewline", "commas,,,"]
        try await store.replaceImportQueue(with: [
            ImportQueueItem(localIdentifier: "asset-1", sortIndex: 0, albumTitles: titles),
        ])

        let read = try await store.nextPendingImportItems().first

        XCTAssertEqual(read?.albumTitles, titles)
    }

    // MARK: - Ordering

    func testTheQueueComesBackInScanOrder() async throws {
        // Newest first, which is the order the scan writes: an import interrupted at 40% should
        // have backed up the photographs somebody took this month, not the ones from 2009.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5).shuffled())

        let read = try await store.nextPendingImportItems(limit: 5)

        XCTAssertEqual(read.map(\.sortIndex), [0, 1, 2, 3, 4])
    }

    // MARK: - Counts

    func testCountsAggregateWithoutReadingTheRows() async throws {
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(10, bytes: 100))
        try await store.updateImportItem("asset-0", state: .done, attempts: 1)
        try await store.updateImportItem("asset-1", state: .skipped, attempts: 1)
        try await store.updateImportItem("asset-2", state: .failed, attempts: 1, error: "nope")

        let counts = await store.importQueueCounts()

        XCTAssertEqual(counts.done, 1)
        XCTAssertEqual(counts.skipped, 1)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.pending, 7)
        XCTAssertEqual(counts.total, 10)
        XCTAssertEqual(counts.finishedBytes, 200, "done and skipped both count as finished work")
        XCTAssertEqual(counts.failedBytes, 100)
        XCTAssertEqual(counts.pendingBytes, 700)
    }

    // MARK: - Surviving a relaunch

    func testAQueueLeftMidRunIsStillThereOnTheNextLaunch() async throws {
        let url = directory.appendingPathComponent("interrupted.sqlite")
        let first = try LocalStore(url: url)
        try await first.replaceImportQueue(with: items(100))
        for index in 0..<30 {
            try await first.updateImportItem("asset-\(index)", state: .done, attempts: 1)
        }

        // The app is killed here. Nothing is flushed, nothing is closed politely.
        let second = try LocalStore(url: url)
        let counts = await second.importQueueCounts()

        XCTAssertEqual(counts.done, 30)
        XCTAssertEqual(counts.pending, 70)
        let next = try await second.nextPendingImportItems().first
        XCTAssertEqual(next?.localIdentifier, "asset-30", "resumes where it stopped, not at the top")
    }

    // MARK: - Retry

    func testFailedItemsAreRequeuedOnlyWhileTheyHaveAttemptsLeft() async throws {
        // A poison item must not stall the queue and must not be retried forever. Three attempts,
        // then it waits in the failed list for the user.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(3))
        try await store.updateImportItem("asset-0", state: .failed, attempts: 1, error: "blip")
        try await store.updateImportItem("asset-1", state: .failed,
                                         attempts: LibraryImportService.maximumAttempts,
                                         error: "genuinely broken")

        let requeued = try await store.requeueFailedImportItems(
            maximumAttempts: LibraryImportService.maximumAttempts)

        XCTAssertEqual(requeued, 1)
        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.pending, 2)
    }

    func testTheRetryButtonRequeuesEverythingRegardlessOfAttempts() async throws {
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(2))
        try await store.updateImportItem("asset-0", state: .failed, attempts: 99, error: "nope")

        let requeued = try await store.requeueFailedImportItems()

        XCTAssertEqual(requeued, 1)
        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.failed, 0)
    }

    func testFailedItemsCarryTheirReasonBackToTheUser() async throws {
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(1))
        try await store.updateImportItem("asset-0", state: .failed, attempts: 1,
                                         error: "The Internet connection appears to be offline.")

        let failed = try await store.failedImportItems()

        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.lastError, "The Internet connection appears to be offline.")
        XCTAssertEqual(failed.first?.attempts, 1)
    }

    // MARK: - Scale

    func testATwoThousandItemQueueIsWrittenAndCountedInOneGo() async throws {
        // The development library's size. Written in one transaction — without it, each insert is
        // its own trip to the filesystem and a scan's write takes seconds rather than milliseconds.
        let store = try makeStore()

        try await store.replaceImportQueue(with: items(2_000))

        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.pending, 2_000)
        XCTAssertEqual(counts.totalBytes, 2_000_000_000)
    }

    func testARescanQueuesAPreviousRunsFailuresAgainWithAFreshAttemptCount() async throws {
        // A failed item was, by definition, never recorded as imported — so a scan finds it again.
        // Coming back with attempts reset is what somebody scanning again is asking for.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(2))
        try await store.updateImportItem("asset-0", state: .failed, attempts: 2, error: "nope")

        try await store.replaceImportQueue(with: items(4))

        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.failed, 0)
        XCTAssertEqual(counts.pending, 4)
        let next = try await store.nextPendingImportItems().first
        XCTAssertEqual(next?.attempts, 0)
    }

    // MARK: - Discarding

    func testDiscardingTheQueueLeavesTheLedgerAlone() async throws {
        // Cancelling a *run* must not un-remember what was already uploaded, or the next run would
        // send it all again.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        try await store.recordImport(localIdentifier: "asset-0", fingerprint: "hash",
                                     photoID: "photo-1")

        try await store.clearImportQueue()

        let counts = await store.importQueueCounts()
        XCTAssertTrue(counts.isEmpty)
        let remembered = await store.importedCount()
        XCTAssertEqual(remembered, 1)
    }
}

// MARK: - LibraryImportServiceTests

/// The importer's state machine and the conditions that stop it.
///
/// `PHAsset` cannot be constructed and a simulator has no camera roll, so nothing that actually
/// touches the Photos framework is reachable from here — the same constraint `DevicePhotoLibrary`
/// has lived under since Epic 5. What *is* testable is everything on either side of it: what the
/// service does with a queue, what it reports, and when it refuses to run.
@MainActor
final class LibraryImportServiceTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var monitor: NetworkMonitor!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.remove()
        directory = makeTemporaryDirectory()
        defaults = makeTemporaryDefaults()
        settings = AppSettings(defaults: defaults)
        monitor = NetworkMonitor(autoStart: false)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        super.tearDown()
    }

    private func makeService(store: LocalStore?) -> LibraryImportService {
        let api = APIClient(session: MockURLProtocol.makeSession())
        let ledger = ImportLedger(store: store, defaults: defaults)
        let pipeline = MediaImportPipeline(content: MediaContentService(api: api, store: store),
                                           library: PhotoLibraryService(api: api, store: store),
                                           settings: settings, ledger: ledger)
        return LibraryImportService(pipeline: pipeline, deviceLibrary: DevicePhotoLibrary(),
                                    settings: settings, monitor: monitor, store: store)
    }

    private func makeStore(named name: String = "import.sqlite") throws -> LocalStore {
        try LocalStore(url: directory.appendingPathComponent(name))
    }

    private func items(_ count: Int) -> [ImportQueueItem] {
        (0..<count).map {
            ImportQueueItem(localIdentifier: "asset-\($0)", sortIndex: $0,
                            estimatedBytes: 1_000_000)
        }
    }

    // MARK: - Restoring

    func testALaunchOverAnEmptyQueueIsIdle() async throws {
        let sut = makeService(store: try makeStore())

        await sut.restore()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertTrue(sut.counts.isEmpty)
    }

    func testALaunchOverAQueueLeftMidRunOffersToResume() async throws {
        // Verification step 4: force-quit at ~50%, relaunch, and be *told* — a user who killed the
        // app has no other way to discover that two thousand photographs are still waiting.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(10))
        try await store.updateImportItem("asset-0", state: .done, attempts: 1)

        let sut = makeService(store: store)
        await sut.restore()

        XCTAssertEqual(sut.phase, .interrupted)
        XCTAssertEqual(sut.counts.pending, 9)
        XCTAssertEqual(sut.counts.done, 1)
    }

    func testALaunchOverAFinishedQueueSaysSoRatherThanOfferingToResume() async throws {
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(2))
        try await store.updateImportItem("asset-0", state: .done, attempts: 1)
        try await store.updateImportItem("asset-1", state: .skipped, attempts: 1)

        let sut = makeService(store: store)
        await sut.restore()

        XCTAssertEqual(sut.phase, .finished)
        XCTAssertFalse(sut.counts.hasWorkLeft)
    }

    func testRestoringHydratesTheLedgerBeforeAnythingCanImport() async throws {
        // An importer that started before the ledger hydrated would have an empty one, and would
        // cheerfully re-upload a library it had already uploaded.
        let store = try makeStore()
        try await store.recordImport(localIdentifier: "asset-1", fingerprint: "hash",
                                     photoID: "photo-1")

        let sut = makeService(store: store)
        await sut.restore()

        XCTAssertEqual(sut.ledger.count, 1)
    }

    // MARK: - Refusing to start

    func testAnImportWillNotStartWithoutAnEncryptionKey() async throws {
        // Bytes sealed to nobody could never be decrypted again, so refusing is the only correct
        // outcome — the same guard the picker path has.
        XCTAssertFalse(KeyImportService.hasStoredKeys())
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(3))
        let sut = makeService(store: store)
        await sut.restore()

        sut.start()

        XCTAssertEqual(sut.phase, .paused("Unlock your encryption key before importing."))
        XCTAssertEqual(sut.counts.pending, 3, "and nothing was taken off the queue")
    }

    func testAnImportWillNotStartWithNothingToDo() async throws {
        TestKeys.install()
        let sut = makeService(store: try makeStore())
        await sut.restore()

        sut.start()

        XCTAssertEqual(sut.phase, .idle)
    }

    func testScanningIsRefusedWithoutPhotoLibraryAccess() async throws {
        // A simulator's `DevicePhotoLibrary` reports `.notDetermined`, which is exactly the state
        // this needs: the scan must explain itself rather than prompting from a background run.
        let sut = makeService(store: try makeStore())

        await sut.scan()

        guard case .paused(let reason) = sut.phase else {
            return XCTFail("expected a paused phase, got \(sut.phase)")
        }
        XCTAssertEqual(reason,
                       "Neutrino Photos needs access to your photo library to import it.")
    }

    func testAFullImportRefusesToRunWithoutSomewhereToPersistItsQueue() async {
        // The one place a missing database is not merely slower. Everything else in this app treats
        // `LocalStore` as an accelerator; a resumable queue with nowhere to persist itself would
        // silently restart from the beginning after every relaunch, which is worse than saying so.
        let sut = makeService(store: nil)

        await sut.scan()

        guard case .paused(let reason) = sut.phase else {
            return XCTFail("expected a paused phase, got \(sut.phase)")
        }
        XCTAssertNotNil(reason)
        XCTAssertTrue(try XCTUnwrap(reason).contains("photo picker"),
                      "and it names the route that still works")
    }

    // MARK: - Pausing

    func testPausingLeavesTheQueueIntact() async throws {
        TestKeys.install()
        monitor.setPathForTesting(isOnline: true, isExpensive: false)
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        let sut = makeService(store: store)
        await sut.restore()

        sut.start()
        sut.pause()

        XCTAssertEqual(sut.phase, .paused(nil))
        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.pending, 5, "pausing is not cancelling")
    }

    func testDiscardingTheQueueClearsItWithoutForgettingWhatWasUploaded() async throws {
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        try await store.recordImport(localIdentifier: "asset-0", fingerprint: "hash",
                                     photoID: "photo-1")
        let sut = makeService(store: store)
        await sut.restore()

        await sut.cancelRun()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertTrue(sut.counts.isEmpty)
        XCTAssertEqual(sut.ledger.count, 1)
    }

    func testSigningOutForgetsTheQueueAndTheLedgerTogether() async throws {
        // The hazard this closes: the next account on this device has none of these photographs,
        // and a ledger claiming they are all uploaded would leave them with an empty library and an
        // import that reports nothing to do.
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        try await store.recordImport(localIdentifier: "asset-0", fingerprint: "hash",
                                     photoID: "photo-1")
        let sut = makeService(store: store)
        await sut.restore()
        XCTAssertEqual(sut.ledger.count, 1)

        await sut.reset()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertTrue(sut.counts.isEmpty)
        XCTAssertEqual(sut.ledger.count, 0)
        XCTAssertFalse(sut.ledger.contains(localIdentifier: "asset-0"),
                       "the in-memory copy has to go with the table, not outlive it")
    }

    // MARK: - Retrying

    func testRetryingPutsFailedItemsBackAndClearsTheList() async throws {
        TestKeys.install()
        monitor.setPathForTesting(isOnline: true, isExpensive: false)
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(3))
        try await store.updateImportItem("asset-0", state: .failed, attempts: 99, error: "nope")
        let sut = makeService(store: store)
        await sut.restore()
        XCTAssertEqual(sut.failures.count, 1)

        await sut.retryFailed()
        sut.pause()

        XCTAssertTrue(sut.failures.isEmpty)
        let counts = await store.importQueueCounts()
        XCTAssertEqual(counts.failed, 0)
    }

    // MARK: - Conditions

    func testTheHoldReasonsAreTheOnesTheUserCanActOn() {
        let sut = makeService(store: nil)

        monitor.setPathForTesting(isOnline: false, isExpensive: false)
        XCTAssertEqual(sut.holdReason(),
                       "Waiting for a connection. Nothing has been lost — the import continues when you're back online.")

        // Online but metered, with the user's Wi-Fi-only preference on: a different situation with
        // a different fix, and telling somebody to check their connection would send them looking
        // for a problem that is not there.
        monitor.setPathForTesting(isOnline: true, isExpensive: true)
        settings.wifiOnlyUploads = true
        XCTAssertEqual(sut.holdReason(),
                       "Waiting for Wi-Fi. Turn off “Upload over Wi-Fi only” in Settings to import over cellular.")

        settings.wifiOnlyUploads = false
        XCTAssertNil(sut.holdReason(), "cellular is allowed once the user says so")
    }

    func testFreeSpaceIsReadFromTheDeviceRatherThanAssumed() {
        // The number itself is whatever the simulator has; what matters is that the question is
        // answerable at all, since a nil would silently disable the storage guard entirely.
        XCTAssertNotNil(LibraryImportService.freeDiskBytes())
    }

    // MARK: - Stopping without saying so

    func testAStopTheUserDidNotAskForExplainsItself() async throws {
        // The failure this closes: the background assertion expires, the run stops, and `.paused(nil)`
        // draws no banner anywhere — so somebody who glanced at another app comes back to an upload
        // that is making no progress and says nothing about why.
        TestKeys.install()
        monitor.setPathForTesting(isOnline: true, isExpensive: false)
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        let sut = makeService(store: store)
        await sut.restore()
        sut.start()

        sut.pauseForBackgrounding()

        XCTAssertEqual(sut.phase, .paused(LibraryImportService.backgroundedReason))
    }

    func testAnImportIOSStoppedCarriesOnWhenTheAppComesBack() async throws {
        // An import only runs in the foreground, so without this one look at another app ends a
        // twenty-thousand-item upload permanently.
        TestKeys.install()
        monitor.setPathForTesting(isOnline: true, isExpensive: false)
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        let sut = makeService(store: store)
        await sut.restore()
        sut.start()
        sut.pauseForBackgrounding()

        sut.resumeIfBackgrounded()

        XCTAssertEqual(sut.phase, .running)
    }

    func testAnImportTheUserPausedStaysPaused() async throws {
        // The other half of the same rule: coming back to the app must not undo a deliberate Pause.
        TestKeys.install()
        monitor.setPathForTesting(isOnline: true, isExpensive: false)
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        let sut = makeService(store: store)
        await sut.restore()
        sut.start()
        sut.pause()

        sut.resumeIfBackgrounded()

        XCTAssertEqual(sut.phase, .paused(nil))
    }

    func testPausingSaysWhetherThereWasAnythingToPause() async throws {
        // What tells `pauseForBackgrounding()` not to remember a run that was already stopped —
        // otherwise the next return to the foreground would start an upload nobody asked for.
        TestKeys.install()
        monitor.setPathForTesting(isOnline: true, isExpensive: false)
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        let sut = makeService(store: store)
        await sut.restore()

        XCTAssertFalse(sut.pause(), "nothing was running")
        sut.start()
        XCTAssertTrue(sut.pause())
    }

    func testABackgroundedPauseOverAStoppedRunIsNotResumedLater() async throws {
        TestKeys.install()
        monitor.setPathForTesting(isOnline: true, isExpensive: false)
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(5))
        let sut = makeService(store: store)
        await sut.restore()
        sut.start()
        sut.pause()

        // The assertion expires after the user has already paused: there is no run to stop, and
        // nothing to carry on later.
        sut.pauseForBackgrounding()
        sut.resumeIfBackgrounded()

        XCTAssertEqual(sut.phase, .paused(nil))
    }

    // MARK: - Estimates

    func testNoTimeIsEstimatedWhileTheImportIsNotRunning() async throws {
        let store = try makeStore()
        try await store.replaceImportQueue(with: items(10))
        let sut = makeService(store: store)
        await sut.restore()

        XCTAssertNil(sut.estimatedTimeRemaining, "an interrupted queue has no throughput to go on")
    }
}
