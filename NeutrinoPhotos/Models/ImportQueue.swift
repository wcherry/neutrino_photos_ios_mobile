import Foundation

// MARK: - ScannedAsset

/// One item found by a full-library scan, holding only what deciding *whether and in what order to
/// import it* needs.
///
/// Deliberately smaller than ``DeviceAsset``. Building a `DeviceAsset` asks
/// `PHAssetResource.assetResources(for:)` whether the item has a RAW original, and that is a
/// per-asset trip across the Photos XPC boundary — perfectly cheap for the forty items a picker
/// hands back, and minutes of wall clock over a fifty-thousand-item library. A scan therefore reads
/// only what `PHAsset` already has in hand, and the full record is fetched one item at a time, at
/// the moment that item is actually imported.
struct ScannedAsset: Equatable, Sendable {

    let localIdentifier: String
    let creationDate: Date?
    let isVideo: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    /// Seconds, for a video; zero for a photograph.
    let duration: TimeInterval

    init(localIdentifier: String, creationDate: Date?, isVideo: Bool,
         pixelWidth: Int, pixelHeight: Int, duration: TimeInterval) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.isVideo = isVideo
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }
}

// MARK: - ImportSizeEstimate

/// How big an item is likely to be, before anything has been read off disk.
///
/// ## Why an estimate rather than the number
///
/// The Photos framework does not publish a resource's byte count. `PHAssetResource` has the value —
/// it is right there in the private `fileSize` property that half of GitHub reads by KVC — and this
/// app does not touch it, because an undocumented key that returns nil on the next iOS release
/// would take the progress bar with it, and because reading private properties is a way to fail App
/// Review for a number that is only ever used to draw a bar.
///
/// The alternative would be writing every resource to disk before starting, which is the import
/// itself. So: a pixel-count estimate, and a total that gets *corrected* as real files go past.
///
/// ## Why an estimate is enough
///
/// The estimate is only ever used in two places, and both are ratios in the same units:
/// `finished / total` for the bar, and `remaining / rate` for the ETA — where the rate is itself
/// measured in estimate-units per second. A systematic bias cancels: if every photograph is guessed
/// at half its true size, the observed rate is also half, and the ETA comes out right anyway. What
/// would *not* cancel is a bias that differs between photographs and videos, which is why the two
/// are estimated separately rather than by one average item size.
enum ImportSizeEstimate {

    /// HEIC runs about 0.17 bytes per pixel and JPEG about 0.3 at the quality an iPhone writes.
    static let photoBytesPerPixel = 0.25

    /// A floor, for the thumbnails-and-screenshots end of a library where the pixel estimate
    /// underestimates the container overhead badly.
    static let minimumPhotoBytes: Int64 = 150_000

    /// Per pixel *per second* of video. 4K30 HEVC lands near 6 MB/s and 1080p30 near 1.5 MB/s,
    /// which is what this constant reproduces at both ends.
    static let videoBytesPerPixelSecond = 0.72

    /// What a video with no usable duration is assumed to be. A zero would make a multi-gigabyte
    /// file weightless in the progress bar.
    static let assumedVideoSeconds: TimeInterval = 10

    static let minimumVideoBytes: Int64 = 1_000_000

    static func bytes(for asset: ScannedAsset) -> Int64 {
        let pixels = Double(max(asset.pixelWidth, 1) * max(asset.pixelHeight, 1))
        if asset.isVideo {
            let seconds = asset.duration > 0 ? asset.duration : assumedVideoSeconds
            let estimate = Int64(pixels * videoBytesPerPixelSecond * seconds)
            return max(estimate, minimumVideoBytes)
        }
        return max(Int64(pixels * photoBytesPerPixel), minimumPhotoBytes)
    }
}

// MARK: - ImportQueueItem

/// One row of the import queue: an item to be imported, and how the attempts to import it went.
///
/// Held in SQLite rather than in memory, because the property Epic 6 is actually about is that a
/// run survives the app being killed. An in-memory queue would restart a fifty-thousand-item import
/// from the beginning every time iOS reclaimed the app, which is the same as not having one.
struct ImportQueueItem: Identifiable, Equatable {

    enum State: String {
        /// Waiting to be imported, or waiting to be retried.
        case pending
        /// Every attempt so far has failed. Retryable by hand, and automatically re-queued while
        /// the attempt count is under ``LibraryImportService/maximumAttempts``.
        case failed
        /// Uploaded and registered.
        case done
        /// Deliberately not imported: already in the account, or no longer on the device.
        case skipped
    }

    let localIdentifier: String
    /// The order the scan found it in — newest first, so an interrupted import has backed up the
    /// photographs somebody took most recently rather than the ones from 2009.
    var sortIndex: Int
    var state: State
    var attempts: Int
    var lastError: String?
    var isVideo: Bool
    var estimatedBytes: Int64
    /// The titles of the device albums this item belongs to, so the structure can be rebuilt on the
    /// far side. Carried on the row rather than looked up later: after a relaunch, the run that
    /// finishes this item has no memory of the scan that found it.
    var albumTitles: [String]

    var id: String { localIdentifier }

    init(localIdentifier: String, sortIndex: Int, state: State = .pending, attempts: Int = 0,
         lastError: String? = nil, isVideo: Bool = false, estimatedBytes: Int64 = 0,
         albumTitles: [String] = []) {
        self.localIdentifier = localIdentifier
        self.sortIndex = sortIndex
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.isVideo = isVideo
        self.estimatedBytes = estimatedBytes
        self.albumTitles = albumTitles
    }
}

// MARK: - ImportQueueCounts

/// The state of the whole queue, as one SQL aggregate rather than as a list of rows.
///
/// The distinction matters at scale: drawing the progress screen must not mean reading fifty
/// thousand rows into memory, and neither must deciding whether there is anything left to do.
struct ImportQueueCounts: Equatable {

    var pending = 0
    var failed = 0
    var done = 0
    var skipped = 0

    var pendingBytes: Int64 = 0
    var failedBytes: Int64 = 0
    var finishedBytes: Int64 = 0

    var total: Int { pending + failed + done + skipped }
    /// Items that will not be attempted again unless something asks: done or deliberately skipped.
    var finished: Int { done + skipped }
    var totalBytes: Int64 { pendingBytes + failedBytes + finishedBytes }

    var isEmpty: Bool { total == 0 }

    /// Whether a run has anything left to attempt.
    var hasWorkLeft: Bool { pending > 0 }

    /// Moves one pending item into its finished state.
    ///
    /// Applied in memory rather than re-read from SQLite after every item, deliberately: the
    /// aggregate is a scan of the whole queue table, and paying for one per item over a
    /// fifty-thousand-item run is fifty thousand scans of fifty thousand rows. The transition is
    /// known exactly here, so the arithmetic is exact — and the store is still the authority, read
    /// back at every pass boundary and at launch.
    mutating func record(_ state: ImportQueueItem.State, bytes: Int64) {
        pending = max(0, pending - 1)
        pendingBytes = max(0, pendingBytes - bytes)
        switch state {
        case .done:
            done += 1
            finishedBytes += bytes
        case .skipped:
            skipped += 1
            finishedBytes += bytes
        case .failed:
            failed += 1
            failedBytes += bytes
        case .pending:
            // Put back rather than finished — a cancelled item. Undo the decrement above.
            pending += 1
            pendingBytes += bytes
        }
    }

    /// Progress as the bar draws it, by bytes rather than by item count — a library is mostly
    /// photographs and mostly bytes of video, and an item-counting bar sits at 99% through the part
    /// that takes the longest.
    var fraction: Double {
        guard totalBytes > 0 else {
            guard total > 0 else { return 0 }
            return Double(finished) / Double(total)
        }
        return min(1, Double(finishedBytes) / Double(totalBytes))
    }
}

// MARK: - ImportRate

/// Throughput and time remaining, measured over the part of a run that was actually running.
///
/// Paused time is excluded deliberately: a run paused for the night and resumed in the morning has
/// an eight-hour elapsed time and a throughput near zero, and an ETA computed from that would say
/// "4 days" about a queue with ten items left in it.
///
/// Units are whatever the caller counts in — ``ImportSizeEstimate``'s estimated bytes, here — since
/// the rate and the remaining work are always in the same ones. See the note on that type for why
/// that makes a biased estimate harmless.
struct ImportRate: Equatable {

    /// How much has gone past since the run started.
    private(set) var unitsDone: Int64 = 0

    /// Seconds of running time in the spans that have already ended.
    private(set) var completedSeconds: TimeInterval = 0

    /// When the current running span began, or nil while paused or stopped.
    private(set) var spanStartedAt: Date?

    var isRunning: Bool { spanStartedAt != nil }

    /// Below this there is not enough evidence to say anything, and a wildly wrong first estimate
    /// is worse than none — it is the number the user reads and then plans around.
    static let minimumSecondsBeforeEstimating: TimeInterval = 8

    // MARK: - Driving it

    mutating func begin(at now: Date) {
        guard spanStartedAt == nil else { return }
        spanStartedAt = now
    }

    mutating func suspend(at now: Date) {
        guard let started = spanStartedAt else { return }
        completedSeconds += max(0, now.timeIntervalSince(started))
        spanStartedAt = nil
    }

    mutating func record(units: Int64) {
        unitsDone += max(0, units)
    }

    /// Forgets everything, for a new run.
    mutating func reset() {
        unitsDone = 0
        completedSeconds = 0
        spanStartedAt = nil
    }

    // MARK: - Reading it

    func activeSeconds(at now: Date) -> TimeInterval {
        guard let started = spanStartedAt else { return completedSeconds }
        return completedSeconds + max(0, now.timeIntervalSince(started))
    }

    /// Units per second over the run so far, or nil while there is too little to go on.
    func unitsPerSecond(at now: Date) -> Double? {
        let seconds = activeSeconds(at: now)
        guard seconds >= Self.minimumSecondsBeforeEstimating, unitsDone > 0 else { return nil }
        return Double(unitsDone) / seconds
    }

    /// How much longer, or nil when that cannot honestly be said yet.
    func estimatedTimeRemaining(unitsRemaining: Int64, at now: Date) -> TimeInterval? {
        guard unitsRemaining > 0 else { return 0 }
        guard let rate = unitsPerSecond(at: now), rate > 0 else { return nil }
        return Double(unitsRemaining) / rate
    }
}

// MARK: - Formatting

extension ImportRate {

    /// "about 4 minutes", or nil when there is nothing worth saying.
    ///
    /// Coarse on purpose. A countdown that reads "3 minutes 41 seconds" over an import whose rate
    /// swings by a factor of three between a screenshot and a 4K clip is precision the number does
    /// not have.
    static func formatted(remaining seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.includesApproximationPhrase = false
        formatter.maximumUnitCount = 1
        switch seconds {
        case ..<90:      formatter.allowedUnits = [.second]
        case ..<3600:    formatter.allowedUnits = [.minute]
        default:         formatter.allowedUnits = [.hour]
        }
        return formatter.string(from: max(seconds, 1))
    }
}
