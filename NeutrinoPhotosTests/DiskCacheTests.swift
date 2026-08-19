import XCTest
@testable import NeutrinoPhotos

// MARK: - DiskCacheTests

/// The cap and the eviction order, which are the only two things a cache can get wrong quietly.
///
/// Every test here uses a directory of its own — a cache with a shared directory would pass or fail
/// depending on which test ran first, and the eviction assertions in particular depend on knowing
/// exactly what is in there.
final class DiskCacheTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
    }

    private func makeCache(capacityBytes: Int64 = 1 << 20) -> DiskCache {
        DiskCache(directory: directory, capacityBytes: capacityBytes)
    }

    // MARK: - Round trip

    func testStoresAndReadsBytesBack() {
        let cache = makeCache()
        let bytes = Data("a decrypted photograph".utf8)

        XCTAssertNotNil(cache.store(bytes, forKey: "file-1.jpg"))
        XCTAssertEqual(cache.data(forKey: "file-1.jpg"), bytes)
        XCTAssertTrue(cache.contains(key: "file-1.jpg"))
    }

    func testAMissingKeyIsNilRatherThanAnError() {
        let cache = makeCache()

        XCTAssertNil(cache.data(forKey: "never-stored"))
        XCTAssertNil(cache.url(forKey: "never-stored"))
        XCTAssertFalse(cache.contains(key: "never-stored"))
    }

    func testTheStoredFileKeepsItsExtension() throws {
        // `AVPlayer` picks its demuxer from the path extension, so a `.mov` written as `.dat`
        // simply does not play — the key carries the extension for that reason alone.
        let cache = makeCache()
        cache.store(Data("clip".utf8), forKey: "file-v.mov")

        let url = try XCTUnwrap(cache.url(forKey: "file-v.mov"))
        XCTAssertEqual(url.pathExtension, "mov")
    }

    func testAdoptMovesAFileWrittenElsewhereIntoTheCache() throws {
        // The streaming path decrypts to a temporary file and hands it over rather than reading it
        // back into memory to store it; if the move did not happen the file would be deleted.
        let cache = makeCache()
        let staged = directory.appendingPathComponent("staged.tmp")
        try Data("streamed plaintext".utf8).write(to: staged)

        let url = try XCTUnwrap(cache.adopt(fileAt: staged, forKey: "file-big.mov"))

        XCTAssertEqual(try Data(contentsOf: url), Data("streamed plaintext".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path),
                       "adopt moves rather than copies; a copy leaves the staging file behind")
    }

    // MARK: - Accounting

    func testTotalBytesCountsWhatIsThere() {
        let cache = makeCache()
        cache.store(Data(repeating: 1, count: 1000), forKey: "a")
        cache.store(Data(repeating: 2, count: 2000), forKey: "b")

        XCTAssertEqual(cache.totalBytes(), 3000)
    }

    func testRemoveAllEmptiesTheCacheAndLeavesItUsable() {
        let cache = makeCache()
        cache.store(Data(repeating: 1, count: 1000), forKey: "a")

        cache.removeAll()

        XCTAssertEqual(cache.totalBytes(), 0)
        // The directory has to come back, or the first write after "Clear cache" fails silently.
        XCTAssertNotNil(cache.store(Data("again".utf8), forKey: "b"))
    }

    // MARK: - Eviction

    func testEvictsDownToBelowTheCapWhenItIsExceeded() {
        let cache = makeCache(capacityBytes: 10_000)
        for index in 0..<10 {
            cache.store(Data(repeating: UInt8(index), count: 2000), forKey: "file-\(index)")
        }

        // 20,000 bytes written into a 10,000-byte cache. Eviction runs to 80% of the cap, so what
        // is left has to be under 8,000 — and non-empty, because a cache that empties itself
        // whenever it fills is not a cache.
        XCTAssertLessThanOrEqual(cache.totalBytes(), 8000)
        XCTAssertGreaterThan(cache.totalBytes(), 0)
    }

    func testEvictionDropsTheLeastRecentlyUsedFirst() throws {
        let cache = makeCache(capacityBytes: 6000)
        cache.store(Data(repeating: 1, count: 2000), forKey: "oldest")
        cache.store(Data(repeating: 2, count: 2000), forKey: "middle")

        // Touch the oldest so it is no longer the least recently *used*, which is the distinction
        // the whole eviction order rests on. The stamps have one-second granularity on some
        // filesystems, so they are set explicitly rather than by waiting.
        try setModificationDate(Date(timeIntervalSinceNow: -600), forKey: "middle", in: cache)
        try setModificationDate(Date(), forKey: "oldest", in: cache)

        cache.store(Data(repeating: 3, count: 4000), forKey: "newest")

        XCTAssertFalse(cache.contains(key: "middle"), "the least recently used should go first")
        XCTAssertTrue(cache.contains(key: "newest"))
    }

    func testAReadCountsAsUse() throws {
        // Sized so exactly one file has to go: 11,000 bytes in a 10,000-byte cache evicts down to
        // 8,000, which the oldest 3,000 covers on its own. Whichever file that is, is the assertion.
        let cache = makeCache(capacityBytes: 10_000)
        cache.store(Data(repeating: 1, count: 3000), forKey: "read-later")
        cache.store(Data(repeating: 2, count: 3000), forKey: "never-read")
        try setModificationDate(Date(timeIntervalSinceNow: -600), forKey: "read-later", in: cache)
        try setModificationDate(Date(timeIntervalSinceNow: -300), forKey: "never-read", in: cache)

        _ = cache.data(forKey: "read-later")
        cache.store(Data(repeating: 3, count: 5000), forKey: "newest")

        XCTAssertTrue(cache.contains(key: "read-later"),
                      "reading a file must stamp it as used, or a hot item is evicted for being old")
        XCTAssertFalse(cache.contains(key: "never-read"))
    }

    // MARK: - Keys

    func testAKeyCannotEscapeTheCacheDirectory() {
        // A cache key is a file id, which is data from the server. "../../Documents/x" as a file
        // name is the kind of thing that is only funny once.
        let cache = makeCache()
        cache.store(Data("x".utf8), forKey: "../../escaped")

        let url = cache.destination(forKey: "../../escaped")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    func testALeadingDotIsNotAllowedToHideAFile() {
        // `contentsOfDirectory(options: .skipsHiddenFiles)` is what eviction walks, so a file named
        // ".x" would be invisible to it and would never be evicted.
        XCTAssertFalse(DiskCache.fileName(for: ".hidden").hasPrefix("."))
    }

    // MARK: - Helpers

    private func setModificationDate(_ date: Date, forKey key: String, in cache: DiskCache) throws {
        try FileManager.default.setAttributes([.modificationDate: date],
                                              ofItemAtPath: cache.destination(forKey: key).path)
    }
}
