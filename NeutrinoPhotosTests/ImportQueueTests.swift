import XCTest
@testable import NeutrinoPhotos

// MARK: - ImportSizeEstimateTests

/// The arithmetic behind the progress bar and the ETA.
///
/// Worth testing precisely because the numbers are estimates: an estimate that is *biased* is
/// harmless here — the rate is measured in the same units, so it cancels — but one that is
/// *degenerate* is not. A video that estimates to zero bytes makes a ten-gigabyte item weightless
/// in the bar, and that is the failure these assert against.
final class ImportSizeEstimateTests: XCTestCase {

    func testAPhotographIsEstimatedFromItsPixels() {
        let twelveMegapixels = ScannedAsset(localIdentifier: "a", creationDate: nil, isVideo: false,
                                            pixelWidth: 4032, pixelHeight: 3024, duration: 0)

        let bytes = ImportSizeEstimate.bytes(for: twelveMegapixels)

        // A 12MP HEIC off an iPhone is 2–3 MB. Asserted as a range rather than a constant: the
        // point is that the figure is in the right order of magnitude, not that it equals a
        // particular multiplication.
        XCTAssertGreaterThan(bytes, 1_000_000)
        XCTAssertLessThan(bytes, 6_000_000)
    }

    func testATinyPictureStillCountsForSomething() {
        // A 64×64 icon estimates to a thousand bytes by pixels alone, and a library with a thousand
        // of them would show a progress bar that leaps and then stalls.
        let tiny = ScannedAsset(localIdentifier: "a", creationDate: nil, isVideo: false,
                                pixelWidth: 64, pixelHeight: 64, duration: 0)

        XCTAssertEqual(ImportSizeEstimate.bytes(for: tiny), ImportSizeEstimate.minimumPhotoBytes)
    }

    func testAVideoIsEstimatedFromItsDurationAsWellAsItsPixels() {
        let short = ScannedAsset(localIdentifier: "a", creationDate: nil, isVideo: true,
                                 pixelWidth: 3840, pixelHeight: 2160, duration: 30)
        let long = ScannedAsset(localIdentifier: "b", creationDate: nil, isVideo: true,
                                pixelWidth: 3840, pixelHeight: 2160, duration: 300)

        let shortBytes = ImportSizeEstimate.bytes(for: short)
        let longBytes = ImportSizeEstimate.bytes(for: long)

        // Ten times the duration is ten times the file. Without this a 20-minute 4K clip weighs the
        // same as a 3-second one and the ETA is nonsense for the whole run.
        XCTAssertEqual(Double(longBytes) / Double(shortBytes), 10, accuracy: 0.01)
        // 4K30 HEVC is around 6 MB/s; 30 seconds of it should land near 180 MB.
        XCTAssertGreaterThan(shortBytes, 100_000_000)
        XCTAssertLessThan(shortBytes, 400_000_000)
    }

    func testAVideoWithNoDurationIsNotWeightless() {
        let unknown = ScannedAsset(localIdentifier: "a", creationDate: nil, isVideo: true,
                                   pixelWidth: 1920, pixelHeight: 1080, duration: 0)

        XCTAssertGreaterThanOrEqual(ImportSizeEstimate.bytes(for: unknown),
                                    ImportSizeEstimate.minimumVideoBytes)
    }

    func testAVideoIsEstimatedFarLargerThanAPhotographOfTheSameSize() {
        // The one bias that would *not* cancel out: photographs and videos are estimated by
        // different formulas because one average item size across a library that is 95% pictures
        // and 90% bytes-of-video is wrong for both.
        let photo = ScannedAsset(localIdentifier: "a", creationDate: nil, isVideo: false,
                                 pixelWidth: 1920, pixelHeight: 1080, duration: 0)
        let video = ScannedAsset(localIdentifier: "b", creationDate: nil, isVideo: true,
                                 pixelWidth: 1920, pixelHeight: 1080, duration: 60)

        XCTAssertGreaterThan(ImportSizeEstimate.bytes(for: video),
                             ImportSizeEstimate.bytes(for: photo) * 50)
    }
}

// MARK: - ImportRateTests

/// Throughput and time remaining.
///
/// Every assertion here is driven by an explicit `Date` rather than by the clock, which is what
/// makes "an eight-hour pause must not change the ETA" a test that runs in a millisecond.
final class ImportRateTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testNothingIsEstimatedUntilThereIsEvidence() {
        var rate = ImportRate()
        rate.begin(at: start)
        rate.record(units: 5_000_000)

        // One second in. A rate computed from this would be a number the user reads and plans
        // around, and it would be wrong by an order of magnitude.
        XCTAssertNil(rate.estimatedTimeRemaining(unitsRemaining: 100_000_000,
                                                 at: start.addingTimeInterval(1)))
        XCTAssertNotNil(rate.estimatedTimeRemaining(unitsRemaining: 100_000_000,
                                                    at: start.addingTimeInterval(20)))
    }

    func testTheEstimateIsWorkRemainingOverObservedThroughput() {
        var rate = ImportRate()
        rate.begin(at: start)
        rate.record(units: 100)   // 100 units in 10 seconds: 10 per second
        let now = start.addingTimeInterval(10)

        let remaining = rate.estimatedTimeRemaining(unitsRemaining: 250, at: now)

        XCTAssertEqual(try XCTUnwrap(remaining), 25, accuracy: 0.001)
    }

    func testPausedTimeIsNotCountedAgainstTheRate() {
        // The failure this exists for: a run paused overnight and resumed in the morning has eight
        // hours of elapsed time and a throughput near zero, and would tell somebody with ten items
        // left that they had four days to wait.
        var rate = ImportRate()
        rate.begin(at: start)
        rate.record(units: 100)
        rate.suspend(at: start.addingTimeInterval(10))

        let afterTheNight = start.addingTimeInterval(8 * 3600)
        rate.begin(at: afterTheNight)

        let remaining = rate.estimatedTimeRemaining(unitsRemaining: 100,
                                                    at: afterTheNight.addingTimeInterval(1))

        // 100 units over 11 seconds of *running*, not over eight hours of wall clock.
        XCTAssertEqual(try XCTUnwrap(remaining), 11, accuracy: 0.5)
    }

    func testSuspendingTwiceDoesNotDoubleCountTheSpan() {
        var rate = ImportRate()
        rate.begin(at: start)
        rate.suspend(at: start.addingTimeInterval(10))
        rate.suspend(at: start.addingTimeInterval(100))

        XCTAssertEqual(rate.activeSeconds(at: start.addingTimeInterval(200)), 10, accuracy: 0.001)
    }

    func testResettingForgetsTheRunButNotTheType() {
        var rate = ImportRate()
        rate.begin(at: start)
        rate.record(units: 500)
        rate.reset()

        XCTAssertEqual(rate.unitsDone, 0)
        XCTAssertFalse(rate.isRunning)
        XCTAssertNil(rate.unitsPerSecond(at: start.addingTimeInterval(60)))
    }

    func testNothingLeftIsZeroRatherThanUnknown() {
        // A finished queue must not draw "calculating…" forever.
        let rate = ImportRate()
        XCTAssertEqual(rate.estimatedTimeRemaining(unitsRemaining: 0, at: start), 0)
    }

    // MARK: - Formatting

    func testTheRemainingTimeIsRoundedToSomethingWorthSaying() {
        XCTAssertNil(ImportRate.formatted(remaining: nil))
        XCTAssertNil(ImportRate.formatted(remaining: 0))
        // One unit, whichever it is: a countdown reading "3 minutes 41 seconds" over a rate that
        // swings by 3× between a screenshot and a 4K clip is precision the number does not have.
        XCTAssertEqual(ImportRate.formatted(remaining: 45), "45 seconds")
        XCTAssertEqual(ImportRate.formatted(remaining: 300), "5 minutes")
        XCTAssertEqual(ImportRate.formatted(remaining: 7200), "2 hours")
    }
}

// MARK: - ImportQueueCountsTests

final class ImportQueueCountsTests: XCTestCase {

    func testProgressIsMeasuredInBytesRatherThanItems() {
        // A library is mostly photographs by count and mostly video by size. An item-counting bar
        // sits at 99% through the part that takes the longest.
        var counts = ImportQueueCounts()
        counts.done = 99
        counts.finishedBytes = 100_000_000
        counts.pending = 1
        counts.pendingBytes = 900_000_000

        XCTAssertEqual(counts.fraction, 0.1, accuracy: 0.001)
    }

    func testProgressFallsBackToItemsWhenNothingHasASize() {
        var counts = ImportQueueCounts()
        counts.done = 3
        counts.pending = 1

        XCTAssertEqual(counts.fraction, 0.75, accuracy: 0.001)
    }

    func testAnEmptyQueueIsNotDividedByZero() {
        XCTAssertEqual(ImportQueueCounts().fraction, 0)
        XCTAssertTrue(ImportQueueCounts().isEmpty)
        XCTAssertFalse(ImportQueueCounts().hasWorkLeft)
    }

    func testSkippedItemsCountAsFinishedRatherThanAsFailed() {
        // Verification step 2 — a second run over an already-imported library — is entirely made of
        // skipped items, and it must read as "done", not as "nothing happened".
        var counts = ImportQueueCounts()
        counts.skipped = 2_000
        counts.finishedBytes = 5_000_000_000

        XCTAssertEqual(counts.finished, 2_000)
        XCTAssertEqual(counts.fraction, 1, accuracy: 0.001)
        XCTAssertFalse(counts.hasWorkLeft)
    }

    // MARK: - In-memory bookkeeping

    func testFinishingAnItemMovesItOutOfPendingWithoutRereadingTheTable() {
        // The counts are applied in memory per item and re-read from SQLite only at pass
        // boundaries — one aggregate scan per item over a fifty-thousand-row queue is fifty
        // thousand scans. The arithmetic therefore has to match what the table would have said.
        var counts = ImportQueueCounts()
        counts.pending = 3
        counts.pendingBytes = 300

        counts.record(.done, bytes: 100)
        counts.record(.skipped, bytes: 100)
        counts.record(.failed, bytes: 100)

        XCTAssertEqual(counts.pending, 0)
        XCTAssertEqual(counts.pendingBytes, 0)
        XCTAssertEqual(counts.done, 1)
        XCTAssertEqual(counts.skipped, 1)
        XCTAssertEqual(counts.failed, 1)
        XCTAssertEqual(counts.finishedBytes, 200)
        XCTAssertEqual(counts.failedBytes, 100)
    }

    func testAnItemLeftPendingIsNotSilentlyDroppedFromTheTotal() {
        // What a cancelled item does: it stays queued, and the totals must not shrink underneath
        // the progress bar as though it had been dealt with.
        var counts = ImportQueueCounts()
        counts.pending = 2
        counts.pendingBytes = 200

        counts.record(.pending, bytes: 100)

        XCTAssertEqual(counts.pending, 2)
        XCTAssertEqual(counts.pendingBytes, 200)
        XCTAssertEqual(counts.total, 2)
    }

    func testTheCountsCannotGoNegative() {
        var counts = ImportQueueCounts()
        counts.record(.done, bytes: 100)

        XCTAssertEqual(counts.pending, 0)
        XCTAssertEqual(counts.pendingBytes, 0)
    }

    func testFailedWorkIsNotCountedAsFinished() {
        var counts = ImportQueueCounts()
        counts.done = 1
        counts.finishedBytes = 100
        counts.failed = 1
        counts.failedBytes = 100

        XCTAssertEqual(counts.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(counts.total, 2)
    }
}
