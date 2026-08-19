import Foundation
import os.log

// MARK: - DiskCache

/// A byte-capped store of files on disk, evicted least-recently-used first.
///
/// The one piece of machinery behind every cache in the app: decrypted originals, decrypted videos,
/// and grid thumbnails all differ in what they hold and how much of it, not in how they hold it.
///
/// ## Why "least recently used" is a modification date
///
/// iOS does not reliably update a file's *access* date — the volume is mounted `noatime` and
/// `.contentAccessDateKey` is whatever the last writer left behind. So a read through this cache
/// stamps the modification date instead, and eviction sorts on that. It costs one `setAttributes`
/// per hit, and it is the only ordering that survives a relaunch: an in-memory recency list is
/// empty exactly when the cache is fullest.
///
/// ## Where it lives, and what that means
///
/// Under `Library/Caches`, which the system may purge under storage pressure — correct for
/// everything here, since every byte is re-derivable from the account. Excluded from iCloud backup,
/// and written with `.completeUntilFirstUserAuthentication` file protection: these are *decrypted*
/// photographs, so they get the same accessibility class as the key that decrypted them and no more.
///
/// Every method is safe to call from any thread; the cache is a shared resource and the callers are
/// a grid, a viewer, and an upload queue running at once.
final class DiskCache: @unchecked Sendable {

    // MARK: - Configuration

    /// The directory this cache owns outright. `removeAll()` deletes it.
    let directory: URL

    /// The cap, in bytes. Exceeded briefly by a single write; eviction runs immediately after.
    let capacityBytes: Int64

    /// Eviction runs down to this fraction of the cap rather than exactly to it, so a cache sitting
    /// at its limit doesn't evict one file per write for the rest of the session.
    private static let evictionTarget = 0.8

    // MARK: - Private

    private let lock = NSLock()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "DiskCache")

    // MARK: - Init

    init(directory: URL, capacityBytes: Int64) {
        self.directory = directory
        self.capacityBytes = capacityBytes
        prepareDirectory()
    }

    /// The app's cache of decrypted originals — photographs and videos both.
    ///
    /// 512 MB is roughly a hundred 12-megapixel photographs plus a couple of videos: enough that
    /// scrolling back through a week of pictures re-downloads nothing, small enough that the app
    /// is not the reason a phone runs out of room.
    static func originals() -> DiskCache {
        DiskCache(directory: Self.cachesDirectory(named: "originals"), capacityBytes: 512 << 20)
    }

    /// The grid's thumbnails. Small files, many of them: 64 MB holds well over ten thousand.
    static func thumbnails() -> DiskCache {
        DiskCache(directory: Self.cachesDirectory(named: "thumbnails"), capacityBytes: 64 << 20)
    }

    static func cachesDirectory(named name: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Reading

    /// The cached bytes for `key`, or nil. A hit is stamped as recently used.
    func data(forKey key: String) -> Data? {
        guard let url = url(forKey: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The file holding `key`, or nil when there is none — for the callers that want a URL rather
    /// than bytes (`AVPlayer`, `ImageIO`, an export). A hit is stamped as recently used.
    func url(forKey key: String) -> URL? {
        let url = destination(forKey: key)
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    func contains(key: String) -> Bool {
        FileManager.default.fileExists(atPath: destination(forKey: key).path)
    }

    /// Where `key` is stored, whether or not anything is there yet. For a caller that writes the
    /// file itself — a streaming decrypt, say — and then calls ``registerWrite(forKey:)``.
    func destination(forKey key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key), isDirectory: false)
    }

    // MARK: - Writing

    /// Stores `data` under `key` and returns where it landed.
    @discardableResult
    func store(_ data: Data, forKey key: String) -> URL? {
        let url = destination(forKey: key)
        lock.lock()
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            touch(url)
        } catch {
            logger.error("store failed for \(Self.fileName(for: key), privacy: .public): \(error, privacy: .public)")
            lock.unlock()
            return nil
        }
        lock.unlock()
        evictIfNeeded()
        return url
    }

    /// Moves a file that already exists elsewhere — the output of a streaming decrypt, which was
    /// never in memory and must not be — into the cache under `key`.
    @discardableResult
    func adopt(fileAt source: URL, forKey key: String) -> URL? {
        let url = destination(forKey: key)
        lock.lock()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: source, to: url)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
            touch(url)
        } catch {
            logger.error("adopt failed for \(Self.fileName(for: key), privacy: .public): \(error, privacy: .public)")
            lock.unlock()
            return nil
        }
        lock.unlock()
        evictIfNeeded()
        return url
    }

    func remove(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: destination(forKey: key))
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        prepareDirectory()
    }

    // MARK: - Accounting

    /// Bytes currently held. Walked rather than tracked: a `Library/Caches` directory can be emptied
    /// by the system without telling the app, and a counter would then be a confident lie.
    func totalBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries().reduce(into: Int64(0)) { $0 += $1.size }
    }

    /// Deletes the least recently used files until the cache is comfortably under its cap.
    func evictIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        var files = entries()
        var total = files.reduce(into: Int64(0)) { $0 += $1.size }
        guard total > capacityBytes else { return }

        let target = Int64(Double(capacityBytes) * Self.evictionTarget)
        files.sort { $0.lastUsed < $1.lastUsed }
        var evicted = 0
        for file in files where total > target {
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            evicted += 1
        }
        logger.debug("evicted \(evicted) file(s) from \(self.directory.lastPathComponent, privacy: .public), now \(total) bytes")
    }

    // MARK: - Private

    private struct Entry {
        let url: URL
        let size: Int64
        let lastUsed: Date
    }

    /// Every file in the cache with the two facts eviction needs. Call with the lock held.
    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else {
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: url,
                         size: Int64(values.fileSize ?? 0),
                         lastUsed: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Stamps a file as used now. Call with the lock held.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // These are decrypted photographs. Excluding them from backup keeps plaintext out of
        // iCloud, where the key that produced it deliberately never goes.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// A file name that cannot escape the cache directory, whatever the key was.
    ///
    /// Keys here are Drive file ids, which are already tame — but a key is data from the server,
    /// and "../../Documents" as a file name is the kind of thing that is only funny once.
    static func fileName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = String(String.UnicodeScalarView(
            key.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        // A leading dot would hide the file from `contentsOfDirectory`'s `skipsHiddenFiles`, and
        // eviction would then never see it.
        let safe = sanitized.hasPrefix(".") ? "_" + sanitized.dropFirst() : sanitized
        return String(safe.prefix(200))
    }
}
