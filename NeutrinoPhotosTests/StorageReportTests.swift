import XCTest
@testable import NeutrinoPhotos

// MARK: - CloudStorageReportTests

final class CloudStorageReportTests: XCTestCase {

    private func quota(used: Int64, limit: Int64?, dailyCap: Int64? = nil) -> DriveQuota {
        DriveQuota(usedBytes: used, quotaBytes: limit, dailyUploadBytes: 0, dailyCapBytes: dailyCap)
    }

    func testTheLibraryIsBrokenDownByKind() {
        let report = CloudStorageReport(
            items: [
                Fixture.item(id: "p1", mimeType: "image/jpeg", sizeBytes: 3_000),
                Fixture.item(id: "p2", mimeType: "image/heic", sizeBytes: 2_000),
                Fixture.item(id: "v1", mimeType: "video/quicktime", sizeBytes: 10_000),
                Fixture.item(id: "d1", mimeType: "application/pdf", sizeBytes: 500),
            ],
            trash: [Fixture.item(id: "t1", sizeBytes: 700)],
            quota: nil)

        XCTAssertEqual(report.photos, 5_000)
        XCTAssertEqual(report.videos, 10_000)
        XCTAssertEqual(report.otherLibrary, 500)
        XCTAssertEqual(report.recentlyDeleted, 700, "trash counts against the quota until purged")
        XCTAssertEqual(report.libraryTotal, 16_200)
    }

    func testTheRestOfTheAccountIsReportedSoTheBarAddsUpToTheQuota() {
        let report = CloudStorageReport(items: [Fixture.item(sizeBytes: 4_000)], trash: [],
                                        quota: quota(used: 10_000, limit: 40_000))

        XCTAssertEqual(report.otherNeutrino, 6_000)
        XCTAssertEqual(report.freeBytes, 30_000)
        XCTAssertEqual(report.fractionUsed ?? 0, 0.25, accuracy: 0.0001)
    }

    func testANewerListingThanTheQuotaNeverMakesOtherNegative() {
        let report = CloudStorageReport(items: [Fixture.item(sizeBytes: 12_000)], trash: [],
                                        quota: quota(used: 10_000, limit: nil))

        XCTAssertEqual(report.otherNeutrino, 0)
        XCTAssertNil(report.freeBytes, "an unlimited account has no free figure")
        XCTAssertNil(report.fractionUsed)
    }

    func testWithoutAQuotaTheAccountTotalIsUnknownNotZero() {
        let report = CloudStorageReport(items: [], trash: [], quota: nil)

        XCTAssertNil(report.usedBytes)
        XCTAssertNil(report.otherNeutrino)
    }
}

// MARK: - DiskCacheSelectionTests

final class DiskCacheSelectionTests: XCTestCase {

    private var directory: URL!
    private var cache: DiskCache!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCacheSelectionTests-\(UUID().uuidString)")
        cache = DiskCache(directory: directory, capacityBytes: 1 << 20)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testBytesAndRemovalCanBeLimitedByFileName() {
        cache.store(Data(count: 100), forKey: "a.jpg")
        cache.store(Data(count: 40), forKey: "a-preview.jpg")
        cache.store(Data(count: 200), forKey: "b.mov")

        XCTAssertEqual(cache.totalBytes(whereFileName: { $0.hasSuffix("-preview.jpg") }), 40)

        let freed = cache.removeAll(whereFileName: { !$0.hasSuffix("-preview.jpg") })

        XCTAssertEqual(freed, 300)
        XCTAssertTrue(cache.contains(key: "a-preview.jpg"))
        XCTAssertFalse(cache.contains(key: "a.jpg"))
        XCTAssertFalse(cache.contains(key: "b.mov"))
    }
}
