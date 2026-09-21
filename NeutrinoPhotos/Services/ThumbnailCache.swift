import Foundation
import UIKit
import os.log

// MARK: - ThumbnailFetching

/// The one thing ``ThumbnailCache`` needs from the network: the bytes behind a thumbnail URL.
///
/// A protocol rather than an ``APIClient`` reference so the cache can be built without one — the
/// tests that are about eviction and decoding have no business standing up a transport — and so a
/// test that *is* about fetching can count the calls.
///
/// Nil means "there is no thumbnail there", which a 404 says and a failure does not: a thumbnail
/// swept or replaced between the listing and the fetch is a placeholder in one cell, while a
/// phone in a tunnel is something to try again on the next pass.
/// ``APIClient`` conforms, in its own file — a protocol that inherits `Sendable` can only be
/// conformed to where the class is declared.
protocol ThumbnailFetching: AnyObject, Sendable {
    func thumbnailData(at path: String) async throws -> Data?
}

// MARK: - ThumbnailCache

/// The grid's pictures: decoded once per launch, kept on disk between them.
///
/// ## What it is actually saving
///
/// A download and a decode, in that order of expense. Since issue #175 a cover thumbnail is *not*
/// carried inside the library listing — the row holds a URL and the bytes are fetched per item —
/// so an uncached cell costs a request. Doing that again every time a cell scrolls back into view
/// is what would turn a smooth grid into a stuttering one; so would re-decoding the JPEG, which is
/// what the memory tier saves even on a hit.
///
/// The disk tier exists for the launch after this one, and for the scroll after this one. It holds
/// the JPEG rather than the bitmap — a 512 px thumbnail is about 30 KB compressed and 1 MB decoded
/// — so ten thousand of them fit in the cap, and a library opens onto pictures before the listing
/// request has answered.
///
/// ## Two tiers, two eviction rules
///
/// `NSCache` empties itself under memory pressure, which is the entire reason to use one: twenty
/// thousand decoded thumbnails is an out-of-memory kill, and the right response to a warning is to
/// drop them rather than to be terminated holding them. The disk tier is capped by bytes and
/// evicted least-recently-used, because disk pressure arrives as a full phone rather than as a
/// notification.
///
/// Callable from any thread. Decoding happens off the main actor by construction — the caller
/// `await`s a value rather than a view — and the grid depends on that.
final class ThumbnailCache: ObservableObject, @unchecked Sendable {

    // MARK: - Tiers

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Bytes of bitmap. About sixty full screens of a dense grid, and dropped wholesale the
        // moment the system says it needs the room.
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private let disk: DiskCache

    /// Where a thumbnail neither tier holds comes from. Nil in the tests and previews that only
    /// exercise the tiers, in which case an uncached item simply draws its placeholder.
    private let fetcher: ThumbnailFetching?

    /// The loads running right now, keyed the same way the tiers are.
    ///
    /// A grid asks for the same thumbnail more than once in the ordinary course of scrolling: a
    /// cell's `task` is cancelled and started again every time it leaves and re-enters the view,
    /// and a photograph on screen in the timeline can be on screen in an album at the same time.
    /// Without this each of those is its own request for bytes another one is already fetching.
    ///
    /// Guarded by ``lock`` rather than by an actor so ``image(for:)`` keeps working from any
    /// thread, which is what its callers — a grid, a viewer, and an import — rely on.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private let lock = NSLock()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "ThumbnailCache")

    // MARK: - Init

    init(disk: DiskCache = .thumbnails(), fetcher: ThumbnailFetching? = nil) {
        self.disk = disk
        self.fetcher = fetcher
    }

    // MARK: - Reading

    /// The item's grid thumbnail, from whichever tier has it or from the server.
    ///
    /// Falls through memory → disk → ``MediaItem/thumbnailURL``, storing as it goes, and answers
    /// nil only when there is no thumbnail to be had: a video (until Epic 8 makes poster frames),
    /// a file whose uploader sent none, or a fetch that failed. A cell draws its placeholder
    /// symbol for that rather than a hole in the grid.
    func image(for item: MediaItem) async -> UIImage? {
        let key = Self.key(for: item)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        guard let decoded = await load(key: key, from: item.thumbnailURL) else { return nil }
        memory.setObject(decoded, forKey: key as NSString,
                         cost: RenditionGenerator.bitmapCost(of: decoded))
        return decoded
    }

    /// Reads one thumbnail off disk, or fetches it, joining a load already running for the key.
    ///
    /// Detached rather than a child of the caller, and that is load-bearing in two ways. It keeps
    /// the JPEG decode off the main actor, which is the memory tier's whole reason for existing.
    /// And it means a cell scrolling out of view — which cancels its `task`, and with it the
    /// `await` below — does not cancel the download: the bytes land in the cache anyway, so
    /// scrolling back finds a picture rather than starting the same request again.
    private func load(key: String, from remotePath: String?) async -> UIImage? {
        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }

        let disk = disk
        let fetcher = fetcher
        let logger = logger
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let bytes = disk.data(forKey: key), let image = UIImage(data: bytes) {
                return image
            }
            guard let remotePath, let fetcher else { return nil }
            do {
                guard let bytes = try await fetcher.thumbnailData(at: remotePath),
                      let image = UIImage(data: bytes) else { return nil }
                disk.store(bytes, forKey: key)
                return image
            } catch where error.isCancellation {
                return nil
            } catch {
                // One cell of a grid, so no banner and nothing thrown: the placeholder is the
                // report. Logged because "the whole library is placeholders" is a real failure and
                // this line is the only place it says why.
                logger.error("thumbnail fetch failed for \(key, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
        inFlight[key] = task
        lock.unlock()

        let image = await task.value
        lock.lock()
        // Identity-checked: a later load for the same key may already have replaced this entry,
        // and clearing it unconditionally would orphan a fetch other callers are waiting on.
        if inFlight[key] == task { inFlight[key] = nil }
        lock.unlock()
        return image
    }

    /// Adds a thumbnail the device just generated, so the item it belongs to draws from the cache
    /// rather than waiting for the server to hand its own copy back in the next listing.
    func store(_ jpeg: Data, forFileID fileID: String) {
        disk.store(jpeg, forKey: Self.key(forFileID: fileID))
    }

    // MARK: - Housekeeping

    func totalBytesOnDisk() -> Int64 {
        disk.totalBytes()
    }

    func clear() {
        memory.removeAllObjects()
        disk.removeAll()
        // Not cancelled, only forgotten: a load in flight has already read what it needed from the
        // caches and its waiters are owed an answer. Dropping the entries means the next request
        // for one of those keys starts a fresh load rather than joining one whose bytes are about
        // to be written into a directory this just emptied.
        lock.lock()
        inFlight.removeAll()
        lock.unlock()
    }

    // MARK: - Keys

    /// Keyed by the *Drive file* rather than the photo record: the thumbnail is a property of the
    /// bytes, and a file that is registered twice (or unregistered and registered again) should not
    /// re-decode a picture that has not changed.
    private static func key(for item: MediaItem) -> String {
        key(forFileID: item.fileID)
    }

    private static func key(forFileID fileID: String) -> String {
        fileID + MediaRendition.thumbnail.cacheKeySuffix
    }
}
