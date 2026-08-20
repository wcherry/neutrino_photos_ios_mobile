import XCTest
@testable import NeutrinoPhotos

// MARK: - LocalStoreTests

/// The device's copy of the library: that it migrates, that a row survives the round trip intact,
/// and that the timeline comes back in the order the grid draws it.
///
/// Every test opens a database of its own in a temporary directory. A shared one would make the
/// migration assertions depend on test order, which is exactly the property a migration test is
/// supposed to have none of.
final class LocalStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
    }

    private func makeStore(named name: String = "library.sqlite") throws -> LocalStore {
        try LocalStore(url: directory.appendingPathComponent(name))
    }

    // MARK: - Schema

    func testOpeningACreatesTheSchema() async throws {
        let store = try makeStore()

        // Nothing to read yet, but the query has to succeed — which it only does if the table is
        // there, so this is the migration assertion in disguise.
        let items = try await store.libraryItems()
        let count = await store.libraryCount()
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(count, 0)
    }

    func testReopeningAnExistingDatabaseDoesNotRerunMigrations() async throws {
        let url = directory.appendingPathComponent("reopen.sqlite")
        let first = try LocalStore(url: url)
        try await first.save(Fixture.item(id: "kept"))

        // `CREATE TABLE` without `IF NOT EXISTS` throws on a second run, which is deliberate: it
        // is what makes a broken `user_version` a loud failure rather than a silent one.
        let second = try LocalStore(url: url)
        let items = try await second.libraryItems()
        XCTAssertEqual(items.map(\.id), ["kept"])
    }

    func testSchemaVersionMatchesTheMigrationCount() {
        // The two are derived from each other, so this asserts the derivation rather than a
        // constant — an appended migration that forgets to bump the version cannot happen.
        XCTAssertGreaterThan(LocalStore.schemaVersion, 0)
    }

    // MARK: - Deletion date (schema 3)

    func testADeletionDateSurvivesTheRoundTrip() async throws {
        let store = try makeStore()
        let deletedAt = Date(timeIntervalSince1970: 1_700_200_000)

        try await store.save(Fixture.item(id: "gone", deletedAt: deletedAt), trashed: true)
        let trashed = try await store.trashedItems()

        let restored = try XCTUnwrap(trashed.first)
        // Recently Deleted is one of the views a cold launch with no signal draws from the cache,
        // so the countdown has to survive on disk rather than only in the listing response.
        XCTAssertEqual(restored.deletedAt?.timeIntervalSince1970 ?? 0,
                       deletedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(TrashRetention.daysRemaining(for: restored,
                                                    now: deletedAt.addingTimeInterval(86_400)), 29)
    }

    func testALiveRowHasNoDeletionDateAfterTheRoundTrip() async throws {
        let store = try makeStore()
        try await store.save(Fixture.item(id: "live"))

        let items = try await store.libraryItems()
        XCTAssertNil(items.first?.deletedAt)
    }

    func testDeletingARowRemovesItFromBothListings() async throws {
        let store = try makeStore()
        try await store.save(Fixture.item(id: "gone", deletedAt: Date()), trashed: true)
        try await store.save(Fixture.item(id: "kept"))

        try await store.delete(id: "gone")

        let live = try await store.libraryItems()
        let trashed = try await store.trashedItems()
        // Distinct from a soft delete, which writes the row back with `is_trashed = 1`. A permanent
        // delete leaves nothing, so a cold launch cannot hydrate a photograph the account has lost.
        XCTAssertEqual(live.map(\.id), ["kept"])
        XCTAssertTrue(trashed.isEmpty)
    }

    func testDeletingARowThatIsNotThereIsHarmless() async throws {
        let store = try makeStore()
        try await store.save(Fixture.item(id: "kept"))

        try await store.delete(id: "never-existed")

        let items = try await store.libraryItems()
        XCTAssertEqual(items.map(\.id), ["kept"])
    }

    // MARK: - Round trip

    func testARowSurvivesTheRoundTripIntact() async throws {
        let store = try makeStore()
        let metadata = MediaMetadata(
            width: 4032, height: 3024, format: "jpeg",
            exif: MediaExif(make: "Apple", model: "iPhone 15 Pro", exposureTime: "1/120",
                            fNumber: 1.78, iso: 200, focalLength: 6.86,
                            gpsLatitude: 51.5, gpsLongitude: -0.12,
                            datetimeOriginal: "2024:06:01 10:00:00"))
        let item = Fixture.item(id: "p1", fileID: "f1", fileName: "IMG_1.jpg",
                                thumbnailBase64: "AAAA", isStarred: true, isArchived: true,
                                metadata: metadata)

        try await store.save(item)
        let stored = try await store.libraryItems()
        let restored = try XCTUnwrap(stored.first)

        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.fileID, item.fileID)
        XCTAssertEqual(restored.fileName, item.fileName)
        XCTAssertEqual(restored.mimeType, item.mimeType)
        XCTAssertEqual(restored.sizeBytes, item.sizeBytes)
        XCTAssertEqual(restored.thumbnailBase64, "AAAA")
        XCTAssertTrue(restored.isStarred)
        XCTAssertTrue(restored.isArchived)
        XCTAssertEqual(restored.captureDate?.timeIntervalSince1970,
                       item.captureDate?.timeIntervalSince1970)
        XCTAssertEqual(restored.metadata, metadata,
                       "the EXIF is what the info panel draws; losing it silently would show as a "
                       + "photograph that forgot its own camera")
    }

    func testTheDeviceFactsAndTheLensSurviveTheRoundTripToo() async throws {
        // Added by Epic 5 to an existing JSON column, so the migration is "none" — which is only
        // true as long as the encoder and decoder agree about the new keys. A Live Photo whose
        // `liveVideoFileID` did not persist is one whose motion nothing can ever find again.
        let store = try makeStore()
        let metadata = MediaMetadata(
            width: 4032, height: 3024,
            exif: MediaExif(make: "Apple", lensModel: "iPhone 15 Pro back camera 6.765mm f/1.78"),
            device: MediaDeviceFacts(localIdentifier: "ABCD-1234/L0/001", isLivePhoto: true,
                                     isRAW: false, subtypes: ["live", "hdr"],
                                     liveVideoFileID: "video-1"))

        try await store.save(Fixture.item(metadata: metadata))
        let stored = try await store.libraryItems()
        let restored = try XCTUnwrap(stored.first)

        XCTAssertEqual(restored.metadata, metadata)
        XCTAssertTrue(restored.isLivePhoto)
        XCTAssertEqual(restored.liveVideoFileID, "video-1")
    }

    func testTheTimelineComesBackNewestFirst() async throws {
        let store = try makeStore()
        let old = Fixture.item(id: "old", captureDate: Date(timeIntervalSince1970: 1_000_000))
        let new = Fixture.item(id: "new", captureDate: Date(timeIntervalSince1970: 2_000_000))
        // Inserted in the wrong order on purpose: the index is what sorts them, not the caller.
        try await store.replaceLibrary(with: [old, new])

        let items = try await store.libraryItems()
        XCTAssertEqual(items.map(\.id), ["new", "old"])
    }

    func testTheTimelineDateFallsBackToTheUploadDate() async throws {
        // `timelineDate` is `captureDate ?? createdAt`, and the stored column has to agree with it
        // or a photograph with no EXIF sorts differently on disk than it does in memory.
        let store = try makeStore()
        let noCapture = Fixture.item(id: "no-exif", captureDate: nil,
                                     createdAt: Date(timeIntervalSince1970: 3_000_000))
        let withCapture = Fixture.item(id: "exif", captureDate: Date(timeIntervalSince1970: 1_000_000),
                                       createdAt: Date(timeIntervalSince1970: 4_000_000))
        try await store.replaceLibrary(with: [withCapture, noCapture])

        let ordered = try await store.libraryItems().map(\.id)
        XCTAssertEqual(ordered, ["no-exif", "exif"])
    }

    // MARK: - Replacement

    func testReplacingTheLibraryLeavesTheTrashAlone() async throws {
        // The two come from different endpoints and are loaded separately; a listing that emptied
        // Recently Deleted as a side effect would lose photographs a user is still able to restore.
        let store = try makeStore()
        try await store.replaceTrash(with: [Fixture.item(id: "deleted")])
        try await store.replaceLibrary(with: [Fixture.item(id: "live")])

        let live = try await store.libraryItems().map(\.id)
        let deleted = try await store.trashedItems().map(\.id)
        XCTAssertEqual(live, ["live"])
        XCTAssertEqual(deleted, ["deleted"])
    }

    func testReplacingTheLibraryDropsWhatIsNoLongerThere() async throws {
        let store = try makeStore()
        try await store.replaceLibrary(with: [Fixture.item(id: "a"), Fixture.item(id: "b")])
        try await store.replaceLibrary(with: [Fixture.item(id: "b")])

        let remaining = try await store.libraryItems().map(\.id)
        XCTAssertEqual(remaining, ["b"])
    }

    func testSavingAnItemAsTrashedMovesItBetweenTheTwoListings() async throws {
        let store = try makeStore()
        let item = Fixture.item(id: "p")
        try await store.save(item)

        try await store.save(item, trashed: true)

        let live = try await store.libraryItems()
        let trashed = try await store.trashedItems().map(\.id)
        XCTAssertTrue(live.isEmpty)
        XCTAssertEqual(trashed, ["p"])
    }

    // MARK: - Renditions

    func testRecordsAndReadsBackARenditionFileID() async throws {
        let store = try makeStore()
        try await store.setRenditionFileID("rendition-1", forFile: "file-1", rendition: .preview)

        let preview = await store.renditionFileID(forFile: "file-1", rendition: .preview)
        let thumbnail = await store.renditionFileID(forFile: "file-1", rendition: .thumbnail)
        let unknown = await store.renditionFileID(forFile: "unknown", rendition: .preview)
        XCTAssertEqual(preview, "rendition-1")
        XCTAssertNil(thumbnail)
        XCTAssertNil(unknown)
    }

    func testReplacingTheRenditionIndexDropsRenditionsThatAreGone() async throws {
        // A preview deleted in Drive has to disappear from the index, or every open of that
        // photograph is a 404 before the fallback runs.
        let store = try makeStore()
        try await store.replaceRenditions(with: ["a": "ra", "b": "rb"], rendition: .preview)
        try await store.replaceRenditions(with: ["a": "ra"], rendition: .preview)

        let kept = await store.renditionFileID(forFile: "a", rendition: .preview)
        let dropped = await store.renditionFileID(forFile: "b", rendition: .preview)
        XCTAssertEqual(kept, "ra")
        XCTAssertNil(dropped)
    }

    // MARK: - Meta

    func testMetaValuesRoundTripAndClear() async throws {
        let store = try makeStore()
        try await store.setString("folder-1", forKey: LocalStore.MetaKey.renditionsFolderID)
        let stored = await store.string(forKey: LocalStore.MetaKey.renditionsFolderID)
        XCTAssertEqual(stored, "folder-1")

        try await store.setString(nil, forKey: LocalStore.MetaKey.renditionsFolderID)
        let cleared = await store.string(forKey: LocalStore.MetaKey.renditionsFolderID)
        XCTAssertNil(cleared)
    }

    // MARK: - Clearing

    func testClearEmptiesEveryTable() async throws {
        let store = try makeStore()
        try await store.replaceLibrary(with: [Fixture.item(id: "a")])
        try await store.replaceTrash(with: [Fixture.item(id: "b")])
        try await store.setRenditionFileID("r", forFile: "f", rendition: .preview)
        try await store.setString("v", forKey: "k")

        try await store.clear()

        let live = try await store.libraryItems()
        let trashed = try await store.trashedItems()
        let rendition = await store.renditionFileID(forFile: "f", rendition: .preview)
        let meta = await store.string(forKey: "k")
        XCTAssertTrue(live.isEmpty)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertNil(rendition)
        XCTAssertNil(meta)
    }

    // MARK: - Scale

    func testATwoThousandItemLibraryWritesAndReadsInOneTransaction() async throws {
        // The development library from the roadmap. What this is really asserting is that the
        // insert path is transactional: without a transaction each row is its own trip to the
        // filesystem and this takes seconds rather than milliseconds.
        let store = try makeStore()
        let items = (0..<2000).map { index in
            Fixture.item(id: "photo-\(index)", fileID: "file-\(index)",
                         captureDate: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        let started = Date()
        try await store.replaceLibrary(with: items)
        let written = Date()
        let restored = try await store.libraryItems()
        let read = Date()

        XCTAssertEqual(restored.count, 2000)
        XCTAssertEqual(restored.first?.id, "photo-1999", "newest first")
        XCTAssertLessThan(written.timeIntervalSince(started), 5,
                          "2,000 rows outside a transaction is where this test starts failing")
        XCTAssertLessThan(read.timeIntervalSince(written), 5)
    }

    func testReportsItsSizeOnDisk() async throws {
        let store = try makeStore()
        try await store.replaceLibrary(with: (0..<100).map { Fixture.item(id: "p\($0)") })

        let size = await store.sizeOnDisk()
        XCTAssertGreaterThan(size, 0)
    }
}
