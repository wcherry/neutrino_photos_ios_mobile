import Foundation
import UIKit
import os.log
import NeutrinoCore
import NeutrinoCrypto

// MARK: - LibraryImportService

/// Moves an entire Apple Photos library across, once, reliably.
///
/// ## The shape of it
///
/// A **scan** walks the device library, throws away everything the ledger says is already in the
/// account, and writes what is left into a queue table. A **run** takes items off that queue one at
/// a time, imports each through ``MediaImportPipeline``, and records the outcome on the row. That
/// split is what makes every property this epic is judged on fall out rather than be arranged:
///
/// | | |
/// |---|---|
/// | Re-running adds nothing | the scan asks ``ImportLedger`` before queueing, and asks it again per item |
/// | Incremental | "everything not in the ledger" *is* "everything new since last time" |
/// | Survives termination | the queue is a table; a relaunch reads it back and offers to carry on |
/// | Pause and resume | a run stops taking rows; the rows are still there |
/// | Per-item retry | the row records the attempt count and the error |
///
/// ## Why one item at a time
///
/// The same reason the picker path is serial, only more so: a run holds one item's plaintext and
/// one item's ciphertext, and a phone importing five 48-megapixel photographs at once is a phone
/// the OS kills. Serial also makes the byte accounting honest and gives the queue somewhere
/// natural to check whether it should still be running at all — see ``waitForConditions()``.
///
/// ## What this is not
///
/// Not background upload. The run needs the app to be in the foreground (a background task
/// assertion buys the seconds after a home-press, no more), which is why the flag beside it is
/// ``FeatureFlags/automaticBackup`` and why Epic 7 exists. What it *is* is a run that loses nothing
/// when the app goes away: everything is on the row before the next item starts.
@MainActor
final class LibraryImportService: ObservableObject {

    // MARK: - Phase

    /// What the importer is doing, and — when it is not running — why not.
    enum Phase: Equatable {
        case idle
        /// Walking the device library. The associated value is the live count.
        case scanning(Int)
        case running
        /// Running, but holding: no network, an overheating phone, a metered connection the user
        /// asked not to use. The queue is intact and this clears itself when the condition does.
        case waiting(String)
        /// Stopped and waiting for the user: they paused it, or something happened that this app
        /// cannot resolve on its own, such as running out of storage.
        case paused(String?)
        /// A queue with pending rows that no run is draining — what a relaunch finds after the app
        /// was killed mid-import.
        case interrupted
        case finished
    }

    // MARK: - Published State

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var counts = ImportQueueCounts()
    @Published private(set) var currentName: String?
    /// Fraction of the item in flight, 0 to 1.
    @Published private(set) var currentFraction: Double = 0
    /// The most recent failures, for the list the user can retry from.
    @Published private(set) var failures: [ImportQueueItem] = []
    /// When a run last drained the queue to nothing.
    @Published private(set) var lastCompletedAt: Date?
    /// When the device library was last walked.
    @Published private(set) var lastScannedAt: Date?

    /// Time remaining, or nil while there is too little evidence to say. See ``ImportRate``.
    var estimatedTimeRemaining: TimeInterval? {
        guard phase == .running else { return nil }
        return rate.estimatedTimeRemaining(unitsRemaining: counts.pendingBytes + counts.failedBytes,
                                           at: Date())
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .running, .waiting: return true
        case .idle, .paused, .interrupted, .finished: return false
        }
    }

    // MARK: - Tuning

    /// How many times an item is retried automatically before it is left in the failed list for the
    /// user to decide about. Three passes catches a network blip; a fourth would only be a longer
    /// wait on an item that is genuinely broken.
    static let maximumAttempts = 3

    /// Free space this refuses to import below, on top of the item's own size. A device driven to
    /// literally zero bytes free is one that cannot write a Keychain entry or a database page, and
    /// the failure that produces is not "the import stopped".
    static let requiredFreeBytes: Int64 = 300_000_000

    /// How long to wait before re-checking a condition that stopped the run — no network, a hot
    /// phone. Long enough not to spin, short enough that reconnecting feels like it worked.
    static let conditionPollSeconds: UInt64 = 5

    /// Pause between items while the device is merely warm. Enough to let a sustained import stop
    /// being the thing that pushes it further.
    static let thermalCooldownSeconds: UInt64 = 3

    // MARK: - Dependencies

    private let pipeline: MediaImportPipeline
    private let deviceLibrary: DevicePhotoLibrary
    private let settings: AppSettings
    private let monitor: NetworkMonitor
    private let albums: AlbumService?
    private let store: LocalStore?

    /// The shared record of what this device has uploaded — the same one the picker path consults.
    var ledger: ImportLedger { pipeline.ledger }

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "LibraryImportService")

    private var runTask: Task<Void, Never>?

    /// Which run is the current one.
    ///
    /// Pausing cancels the task, but a cancelled task does not stop where it stands — it resumes at
    /// its next suspension point and unwinds, which can be after the user has already pressed
    /// Resume. Without this, that unwinding would clear the *new* run's task handle, and the press
    /// after that would start a second drain beside the first — two loops taking items off one
    /// queue and uploading them twice.
    private var runGeneration = 0

    private var rate = ImportRate()

    /// Neutrino albums this run has already found or made, by device album title. Per-run rather
    /// than persisted: it is a cache over ``AlbumService/albums``, which is the real record.
    private var albumIDsByTitle: [String: String] = [:]

    /// Keeps the run alive for the few seconds after the app is backgrounded, so an item in flight
    /// finishes rather than being killed halfway and retried from scratch.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Thermal state, read rather than observed: it is checked once per item, and an item is
    /// seconds long.
    private var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    // MARK: - Init

    init(pipeline: MediaImportPipeline, deviceLibrary: DevicePhotoLibrary, settings: AppSettings,
         monitor: NetworkMonitor, albums: AlbumService? = nil, store: LocalStore? = nil) {
        self.pipeline = pipeline
        self.deviceLibrary = deviceLibrary
        self.settings = settings
        self.monitor = monitor
        self.albums = albums
        self.store = store
    }

    // MARK: - Restoring

    /// Reads back whatever the last run left behind.
    ///
    /// Called at launch. A queue with pending rows in it means the app went away mid-import — the
    /// user force-quit it, or iOS reclaimed it — and the honest response is to say so and offer to
    /// carry on, rather than either silently restarting a two-thousand-item upload or silently
    /// forgetting it.
    func restore() async {
        await ledger.hydrate()
        guard let store else { return }
        counts = await store.importQueueCounts()
        lastScannedAt = await date(forKey: LocalStore.MetaKey.lastLibraryScanAt)
        lastCompletedAt = await date(forKey: LocalStore.MetaKey.lastLibraryImportAt)
        failures = (try? await store.failedImportItems(limit: 50)) ?? []

        if counts.hasWorkLeft {
            phase = .interrupted
            logger.debug("restored an interrupted import: \(self.counts.pending) item(s) pending")
        } else if !counts.isEmpty {
            phase = .finished
        }
    }

    // MARK: - Scanning

    /// Walks the device library and queues everything that is not already in the account.
    ///
    /// Both the first full import and every incremental one afterwards; there is deliberately no
    /// difference between them. "What is new since the last run" and "what the ledger has never
    /// seen" are the same set, and a scan defined the second way cannot drift out of step with
    /// reality the way a date cursor can — an item restored from a backup, or one the user added to
    /// a shared album months after it was taken, has an old creation date and is still new here.
    func scan() async {
        guard !isBusy else { return }
        guard FeatureFlags.fullLibraryImport else { return }
        // Checked before the permission, because it is the more fundamental refusal: asking
        // somebody for photo access and then telling them it cannot be used is the wrong order.
        //
        // This is also the one place in this app where a missing database is not merely slower.
        // Everything else treats ``LocalStore`` as an accelerator and degrades; a resumable queue
        // with nowhere to persist itself is not a resumable queue, and one that silently restarted
        // from the beginning after every relaunch would be worse than saying so.
        guard store != nil else {
            phase = .paused("This device's library index is unavailable, so a full import can't be resumed if it's interrupted. Import with the photo picker instead.")
            return
        }
        guard deviceLibrary.access.isUsable else {
            phase = .paused("Neutrino Photos needs access to your photo library to import it.")
            return
        }

        phase = .scanning(0)
        await ledger.hydrate()

        do {
            let snapshot = try await deviceLibrary.scan { [weak self] found in
                guard let self, case .scanning = self.phase else { return }
                self.phase = .scanning(found)
            }

            // The ledger check happens here rather than per item, so a re-run of a fully imported
            // library queues nothing at all and reports "nothing to import" instead of walking two
            // thousand rows to skip every one of them. It is checked *again* inside the run, for
            // the items imported by the picker between the scan and now.
            var queued: [ImportQueueItem] = []
            queued.reserveCapacity(snapshot.assets.count)
            for (index, asset) in snapshot.assets.enumerated()
            where !ledger.contains(localIdentifier: asset.localIdentifier) {
                queued.append(ImportQueueItem(
                    localIdentifier: asset.localIdentifier,
                    sortIndex: index,
                    isVideo: asset.isVideo,
                    estimatedBytes: ImportSizeEstimate.bytes(for: asset),
                    albumTitles: snapshot.albumTitles[asset.localIdentifier] ?? []
                ))
            }

            try await store?.replaceImportQueue(with: queued)
            await setDate(Date(), forKey: LocalStore.MetaKey.lastLibraryScanAt)
            lastScannedAt = Date()
            await refreshCounts()
            phase = queued.isEmpty ? .finished : .paused(nil)
            logger.debug("scan queued \(queued.count) of \(snapshot.assets.count) item(s)")
        } catch {
            logger.error("scan failed: \(error, privacy: .public)")
            phase = .paused(error.localizedDescription)
        }
    }

    /// Scans and then immediately starts importing — the single button on the import screen.
    func scanAndStart() async {
        await scan()
        guard counts.hasWorkLeft else { return }
        start()
    }

    // MARK: - A hand-picked selection

    /// Queues exactly these items and starts uploading them — the Upload button on the
    /// device-library grid.
    ///
    /// ## Why this is here rather than in ``PhotoImportService``
    ///
    /// The other importer's unit of work is a `PhotosPickerItem`, and the grid has none: it selects
    /// out of a listing this app made, so what it has is a `PHAsset.localIdentifier`. Importing *by
    /// identifier* is precisely what this service already does, item by item, in ``process(_:)`` —
    /// and everything that hangs off it comes along unchanged: the ledger's duplicate check, the
    /// RAW original rather than a rendering, a Live Photo's motion, the queue that survives the app
    /// being killed, the retry passes, and the Wi-Fi / storage / heat conditions.
    ///
    /// A selection therefore differs from a full-library run in two things and nothing else: which
    /// items are queued, and that they go to the front. Device album membership is deliberately not
    /// carried across — reading it means walking every album in the library, which is a cost a scan
    /// pays once and a forty-item selection should not pay at all.
    ///
    /// Safe while a full-library run is going: the rows are added to the queue rather than
    /// replacing it, and the drain in flight picks them up next.
    ///
    /// - Returns: false when nothing could be queued, with ``phase`` carrying the reason.
    @discardableResult
    func importSelected(_ assets: [ScannedAsset]) async -> Bool {
        guard FeatureFlags.fullLibraryImport, !assets.isEmpty else { return false }
        guard let store else {
            phase = .paused("This device's library index is unavailable. Import with the photo picker instead.")
            return false
        }
        guard deviceLibrary.access.isUsable else {
            phase = .paused("Neutrino Photos needs access to your photo library to upload from it.")
            return false
        }

        await ledger.hydrate()
        // Ordered as the grid ordered them — newest first — so the sort indices this writes put
        // them back in that order, and an upload stopped halfway has sent the recent ones.
        let queued = assets.enumerated().map { index, asset in
            ImportQueueItem(localIdentifier: asset.localIdentifier,
                            sortIndex: index,
                            isVideo: asset.isVideo,
                            estimatedBytes: ImportSizeEstimate.bytes(for: asset))
        }

        do {
            try await store.prependImportQueue(with: queued)
        } catch {
            logger.error("could not queue a selection: \(error, privacy: .public)")
            phase = .paused(error.localizedDescription)
            return false
        }

        await refreshCounts()
        // A no-op while a run is already draining — `start()` refuses a second one — and the rows
        // just written are the next it will take.
        start()
        logger.debug("queued \(queued.count) hand-picked item(s)")
        return true
    }

    // MARK: - Running

    func start() {
        guard runTask == nil else { return }
        guard counts.hasWorkLeft || counts.failed > 0 else { return }
        guard KeyImportService.hasStoredKeys() else {
            phase = .paused("Unlock your encryption key before importing.")
            return
        }

        phase = .running
        rate.begin(at: Date())
        beginBackgroundTask()
        runGeneration &+= 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    /// Stops after the item in flight.
    ///
    /// The item itself is not abandoned mid-upload where that can be helped: `URLSession` propagates
    /// the cancellation and Drive only records a file for a request that carried its bytes, so an
    /// interrupted upload leaves nothing half-written to clean up.
    func pause() {
        guard runTask != nil else { return }
        runTask?.cancel()
        runTask = nil
        rate.suspend(at: Date())
        endBackgroundTask()
        phase = .paused(nil)
        currentName = nil
        currentFraction = 0
    }

    /// Puts every failed row back in the queue and starts again — the Retry button.
    func retryFailed() async {
        guard let store else { return }
        _ = try? await store.requeueFailedImportItems()
        failures = []
        await refreshCounts()
        start()
    }

    /// Throws the queue away. The ledger is untouched, so this cancels the *run*, not the record of
    /// what has already been uploaded.
    func cancelRun() async {
        pause()
        try? await store?.clearImportQueue()
        failures = []
        await refreshCounts()
        phase = .idle
    }

    /// Everything this service knows, forgotten — what signing out needs.
    ///
    /// The ledger goes too, and that is the point of having this rather than ``cancelRun()``: the
    /// next account on this device has none of these photographs, and a ledger claiming they are
    /// all uploaded would leave them with an empty library and an import that reports nothing to
    /// do. ``LocalStore/clear()`` empties the same tables; this is what stops the copies held in
    /// memory from outliving them.
    func reset() async {
        pause()
        try? await store?.clearImportQueue()
        await ledger.forget()
        failures = []
        counts = ImportQueueCounts()
        lastCompletedAt = nil
        lastScannedAt = nil
        albumIDsByTitle = [:]
        phase = .idle
    }

    // MARK: - The loop

    private func drain(generation: Int) async {
        defer {
            // Only if this is still the current run — a cancelled one unwinding after its
            // replacement has started must not tidy away the replacement's state.
            if generation == runGeneration {
                runTask = nil
                endBackgroundTask()
                rate.suspend(at: Date())
                currentName = nil
                currentFraction = 0
                // Originals are written out of the photo library on their way to an upload, and a
                // run that stopped between two items leaves the last one behind. Over a library of
                // videos that is gigabytes of temporary files.
                deviceLibrary.clearStaging()
            }
        }

        // Passes rather than one sweep: a failure is left on its row, and at the end of a pass
        // everything that has not exhausted its attempts goes back in the queue. A poison item is
        // therefore retried a few times *around* the rest of the library rather than in front of
        // it, and never stalls the queue — which is what a single item failing must never do.
        var stoppedEarly = false
        for pass in 0..<Self.maximumAttempts {
            await drainPass()
            if Task.isCancelled || generation != runGeneration { return }
            guard case .running = phase else {
                // A condition stopped it, and `phase` already says which.
                stoppedEarly = true
                break
            }

            let requeued = (try? await store?.requeueFailedImportItems(
                maximumAttempts: Self.maximumAttempts)) ?? 0
            await refreshCounts()
            guard requeued > 0 else { break }
            logger.debug("pass \(pass + 1) finished; re-queued \(requeued) failed item(s)")
        }

        await refreshCounts()
        failures = (try? await store?.failedImportItems(limit: 50)) ?? []
        guard !stoppedEarly, !counts.hasWorkLeft else { return }

        phase = .finished
        lastCompletedAt = Date()
        await setDate(lastCompletedAt, forKey: LocalStore.MetaKey.lastLibraryImportAt)
        logger.debug("import finished: \(self.counts.done) imported, \(self.counts.skipped) skipped, \(self.counts.failed) failed")
    }

    /// One sweep through the pending rows.
    private func drainPass() async {
        guard let store else { return }
        while !Task.isCancelled {
            guard await waitForConditions() else { return }
            guard let next = (try? await store.nextPendingImportItems(limit: 1))?.first else {
                return
            }
            await process(next)
        }
    }

    // MARK: - One item

    private func process(_ queued: ImportQueueItem) async {
        currentFraction = 0
        var staged: URL?
        defer { staged.map { try? FileManager.default.removeItem(at: $0) } }

        // Asked again here, and not only at scan time: the picker may have imported this very item
        // between the scan and now, and a scan of a fifty-thousand-item library is not instant.
        guard !ledger.contains(localIdentifier: queued.localIdentifier) else {
            await finish(queued, state: .skipped)
            return
        }

        guard let device = deviceLibrary.attributes(forLocalIdentifier: queued.localIdentifier)
        else {
            // Deleted from the device between the scan and now, or the permission was narrowed.
            // Not a failure: there is nothing to import and nothing anybody can do about it.
            await finish(queued, state: .skipped, error: "No longer in this device's photo library.")
            return
        }

        do {
            let original = try await deviceLibrary.writeOriginal(for: queued.localIdentifier)
            staged = original.url

            let name = ImagePreparation.fileName(
                from: original.originalFileName, extension: original.fileExtension,
                fallbackDate: device.creationDate ?? Date())
            currentName = name

            let outcome: MediaImportPipeline.Outcome
            if queued.isVideo {
                outcome = try await pipeline.importVideo(
                    at: original.url, fileName: name, mimeType: original.mimeType, device: device,
                    onProgress: { [weak self] fraction in self?.currentFraction = fraction })
            } else {
                outcome = try await pipeline.importPhoto(
                    try prepare(original, device: device), fileName: name, device: device,
                    onProgress: { [weak self] fraction in self?.currentFraction = fraction })
            }

            if let item = outcome.item, !queued.albumTitles.isEmpty {
                await fileIntoAlbums(queued.albumTitles, photoID: item.id)
            }
            await finish(queued, state: outcome.wasDuplicate ? .skipped : .done)
        } catch is CancellationError where Task.isCancelled {
            // Left pending on purpose: a cancelled item is one the user paused, and it must be the
            // next thing tried rather than a failure they have to go and retry by hand.
            logger.debug("import cancelled during \(queued.localIdentifier, privacy: .public)")
        } catch {
            logger.error("import failed for \(queued.localIdentifier, privacy: .public): \(error, privacy: .public)")
            await finish(queued, state: .failed, error: error.localizedDescription)
        }
    }

    /// Turns a written-out original into what should be stored.
    ///
    /// Mapped rather than read: a 60 MB DNG is paged in as the encryptor walks it instead of being
    /// resident before a byte is sealed. RAW keeps its bytes exactly — see
    /// ``ImagePreparation/prepareOriginal(_:mimeType:fileExtension:)`` — and everything else goes
    /// through the same preparation the picker path uses, which is what converts a HEIC to a JPEG
    /// the web app can display.
    private func prepare(_ original: DeviceOriginal,
                         device: DeviceAsset) throws -> ImagePreparation.Prepared {
        let bytes = try Data(contentsOf: original.url, options: .mappedIfSafe)
        guard device.isRAW else {
            return try ImagePreparation.prepare(bytes, suggestedName: original.originalFileName)
        }
        return ImagePreparation.prepareOriginal(bytes, mimeType: original.mimeType,
                                                fileExtension: original.fileExtension)
    }

    /// Writes the outcome to the row, which is the thing that makes the run resumable — the state
    /// is on disk before the next item begins, so being killed costs at most one item.
    private func finish(_ queued: ImportQueueItem, state: ImportQueueItem.State,
                        error: String? = nil) async {
        try? await store?.updateImportItem(queued.localIdentifier, state: state,
                                           attempts: queued.attempts + 1, error: error)
        counts.record(state, bytes: queued.estimatedBytes)
        if state == .done || state == .skipped {
            rate.record(units: queued.estimatedBytes)
        }
    }

    // MARK: - Albums

    /// Rebuilds one item's album membership on the far side.
    ///
    /// "Where Drive can express it" is the roadmap's phrasing and it is the right caveat: Neutrino
    /// albums are a flat list of titles containing photographs, so a flat list is what survives.
    /// Nested folders, smart albums, and an album's own ordering have nowhere to go and are not
    /// invented here.
    ///
    /// Only fresh imports are filed. An item skipped as a duplicate is already in the account and
    /// may already be in albums the user has since edited by hand; adding it back on every
    /// incremental run would slowly undo their edits.
    private func fileIntoAlbums(_ titles: [String], photoID: String) async {
        guard FeatureFlags.albums, let albums else { return }
        for title in titles {
            do {
                let albumID: String
                if let known = albumIDsByTitle[title] {
                    albumID = known
                } else if let existing = albums.albums.first(where: {
                    !$0.isAuto && $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
                }) {
                    albumID = existing.id
                    albumIDsByTitle[title] = existing.id
                } else {
                    let created = try await albums.create(title: title)
                    albumID = created.id
                    albumIDsByTitle[title] = created.id
                }
                try await albums.add(photoID: photoID, to: albumID)
            } catch {
                // The photograph is in the library either way. An album is organisation, and losing
                // it must not cost the user the picture.
                logger.error("could not file \(photoID, privacy: .public) into \(title, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Conditions

    /// Blocks until it is reasonable to import the next item, or answers false to stop the run.
    ///
    /// Three things can stop it, and they are handled differently on purpose:
    ///
    /// - **Storage** stops the run outright. The device is out of space, this app cannot make more,
    ///   and polling would just be a spinner over a message the user has to act on.
    /// - **Network and heat** hold. Both resolve themselves — a phone comes back into signal, a
    ///   phone cools down — so the queue waits with an explanation rather than making the user come
    ///   back and press Resume.
    /// - **A merely warm phone** is not a stop at all, just a pause between items. This is the
    ///   backpressure Epic 6's thermal check asks for: sustained import is exactly the workload
    ///   that drives a phone into throttling, and the fix is to do less of it per minute rather
    ///   than to stop.
    private func waitForConditions() async -> Bool {
        while !Task.isCancelled {
            if let blocker = storageBlocker() {
                phase = .paused(blocker)
                return false
            }

            if let reason = holdReason() {
                phase = .waiting(reason)
                rate.suspend(at: Date())
                try? await Task.sleep(nanoseconds: Self.conditionPollSeconds * 1_000_000_000)
                continue
            }

            if case .waiting = phase {
                phase = .running
                rate.begin(at: Date())
            }
            if thermalState == .serious {
                try? await Task.sleep(nanoseconds: Self.thermalCooldownSeconds * 1_000_000_000)
            }
            return !Task.isCancelled
        }
        return false
    }

    /// Why the run should hold, or nil to carry on.
    ///
    /// Not private so the wording can be asserted: these three strings are the whole of what a
    /// stalled import tells the user, and each names a different fix.
    func holdReason() -> String? {
        if !monitor.isOnline {
            return "Waiting for a connection. Nothing has been lost — the import continues when you're back online."
        }
        if !monitor.shouldUpload(wifiOnly: settings.wifiOnlyUploads) {
            return "Waiting for Wi-Fi. Turn off “Upload over Wi-Fi only” in Settings to import over cellular."
        }
        if thermalState == .critical {
            return "Your iPhone is too warm to keep importing. This continues on its own once it cools down."
        }
        return nil
    }

    /// The "not enough space" message, or nil when there is room.
    ///
    /// An import writes each original out of the photo library and its ciphertext beside it before
    /// sending either, so it needs roughly twice the largest item free at any moment — on a device
    /// that is, by definition, already full of photographs.
    private func storageBlocker() -> String? {
        guard let free = Self.freeDiskBytes(), free < Self.requiredFreeBytes else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: Self.requiredFreeBytes,
                                                  countStyle: .file)
        return "Not enough storage on this iPhone to keep importing. Free up about \(formatted) and tap Resume — nothing already uploaded is affected."
    }

    static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Background

    /// Asks iOS for the seconds after a home-press.
    ///
    /// This is not background upload — that is Epic 7 and needs a background `URLSession`. What it
    /// buys is that backgrounding the app mid-item finishes that item instead of killing it, so the
    /// resume picks up at the next one rather than re-uploading the interrupted one.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "library-import") {
            [weak self] in
            // The window is closing. Stop cleanly: everything up to the last completed item is
            // already on its row, and the interrupted one is still pending.
            Task { @MainActor in self?.pause() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Counts

    private func refreshCounts() async {
        guard let store else { return }
        counts = await store.importQueueCounts()
    }

    private func date(forKey key: String) async -> Date? {
        guard let raw = await store?.string(forKey: key), let seconds = Double(raw) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private func setDate(_ date: Date?, forKey key: String) async {
        try? await store?.setString(date.map { String($0.timeIntervalSince1970) }, forKey: key)
    }
}
