import Foundation
import UIKit
import os.log

// MARK: - ThumbnailCache

/// The grid's pictures: decoded once per launch, kept on disk between them.
///
/// ## What it is actually saving
///
/// Not a download. A cover thumbnail arrives base64-encoded inside the library listing, so the
/// bytes are free by the time a cell wants them. What is *not* free is turning them into a bitmap:
/// a screenful of cells appearing at once is a screenful of base64 decodes and JPEG decodes, and
/// doing that again every time a cell scrolls back into view is what turns a smooth grid into a
/// stuttering one. The memory tier fixes that.
///
/// The disk tier exists for the launch after this one. It holds the JPEG rather than the bitmap —
/// a 512 px thumbnail is about 30 KB compressed and 1 MB decoded — so ten thousand of them fit in
/// the cap, and a library opens onto pictures before the listing request has answered.
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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "ThumbnailCache")

    // MARK: - Init

    init(disk: DiskCache = .thumbnails()) {
        self.disk = disk
    }

    // MARK: - Reading

    /// The item's grid thumbnail, from whichever tier has it.
    ///
    /// Falls through memory → disk → the listing's own base64, storing as it goes, and answers nil
    /// only when there is no thumbnail anywhere: a video (until Epic 8 makes poster frames), or a
    /// file whose uploader sent none. A cell draws its placeholder symbol for that rather than a
    /// hole in the grid.
    func image(for item: MediaItem) async -> UIImage? {
        let key = Self.key(for: item)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let disk = disk
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let bytes = disk.data(forKey: key), let image = UIImage(data: bytes) {
                return image
            }
            // Not on disk: the listing carried it, so decode and keep it for next launch.
            guard let bytes = item.thumbnailData, let image = UIImage(data: bytes) else {
                return nil
            }
            disk.store(bytes, forKey: key)
            return image
        }.value

        guard let decoded else { return nil }
        memory.setObject(decoded, forKey: key as NSString,
                         cost: RenditionGenerator.bitmapCost(of: decoded))
        return decoded
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
