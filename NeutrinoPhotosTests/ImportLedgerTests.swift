import XCTest
@testable import NeutrinoPhotos

// MARK: - ImportLedgerTests

/// The record that makes running an import twice safe.
///
/// This is the single most important property in Epic 6 — its verification step 2 says so — and it
/// is a property of this type rather than of either importer, which is why both consult one.
@MainActor
final class ImportLedgerTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = makeTemporaryDirectory()
        defaults = makeTemporaryDefaults()
    }

    private func makeStore(named name: String = "ledger.sqlite") throws -> LocalStore {
        try LocalStore(url: directory.appendingPathComponent(name))
    }

    // MARK: - The two keys

    func testAnAssetIsRememberedByItsIdentifier() async throws {
        let store = try makeStore()
        let sut = ImportLedger(store: store, defaults: defaults)
        await sut.hydrate()

        XCTAssertFalse(sut.contains(localIdentifier: "ABCD/L0/001"))

        await sut.record(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1", photoID: "photo-1")

        XCTAssertTrue(sut.contains(localIdentifier: "ABCD/L0/001"))
        XCTAssertEqual(sut.count, 1)
    }

    func testAnAssetIsAlsoRememberedByItsBytes() async throws {
        // The second key catches what the identifier cannot: the same picture imported on a device
        // that never granted library access, or AirDropped from another phone, where there is no
        // asset to name.
        let store = try makeStore()
        let sut = ImportLedger(store: store, defaults: defaults)
        await sut.hydrate()

        await sut.record(localIdentifier: nil, fingerprint: "hash-1", photoID: "photo-1")

        let seen = await sut.contains(fingerprint: "hash-1")
        let unseen = await sut.contains(fingerprint: "hash-2")
        XCTAssertTrue(seen)
        XCTAssertFalse(unseen)
    }

    func testRecordingTheSameAssetTwiceDoesNotCountItTwice() async throws {
        // A re-import of the same asset — a retry, or the picker importing something a scan later
        // finds — must update the row rather than add a second, or "already imported: 4,318" drifts
        // away from the truth on every run.
        let store = try makeStore()
        let sut = ImportLedger(store: store, defaults: defaults)
        await sut.hydrate()

        await sut.record(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1", photoID: "photo-1")
        await sut.record(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1", photoID: "photo-1")

        XCTAssertEqual(sut.count, 1)
    }

    func testTheRecordSurvivesARelaunch() async throws {
        let store = try makeStore()
        let first = ImportLedger(store: store, defaults: defaults)
        await first.hydrate()
        await first.record(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1",
                           photoID: "photo-1")

        // A second launch over the same database, which is what verification step 2 actually does.
        let second = ImportLedger(store: try makeStore(), defaults: makeTemporaryDefaults())
        await second.hydrate()

        XCTAssertTrue(second.contains(localIdentifier: "ABCD/L0/001"))
        let byBytes = await second.contains(fingerprint: "hash-1")
        XCTAssertTrue(byBytes)
        XCTAssertEqual(second.count, 1)
    }

    func testThePhotoAnAssetBecameCanBeLookedUp() async throws {
        let store = try makeStore()
        let sut = ImportLedger(store: store, defaults: defaults)
        await sut.hydrate()
        await sut.record(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1", photoID: "photo-9")

        let photoID = await sut.photoID(forAsset: "ABCD/L0/001")
        XCTAssertEqual(photoID, "photo-9")
    }

    // MARK: - Migration

    func testTheOldUserDefaultsRecordIsMigratedRatherThanLost() async throws {
        // Upgrading with a list in `UserDefaults` and losing it would re-upload the user's entire
        // library on their next import — which is the exact failure the ledger exists to prevent,
        // arriving via the code that prevents it.
        defaults.set(["hash-1", "hash-2"], forKey: ImportLedger.legacyFingerprintsKey)

        let sut = ImportLedger(store: try makeStore(), defaults: defaults)
        // Known before hydration, too: a launch that imports before the database answers must not
        // act as though nothing was ever uploaded.
        let earlyHit = await sut.contains(fingerprint: "hash-1")
        XCTAssertTrue(earlyHit)

        await sut.hydrate()

        let stillKnown = await sut.contains(fingerprint: "hash-2")
        XCTAssertTrue(stillKnown)
        XCTAssertEqual(sut.count, 2)
        XCTAssertNil(defaults.stringArray(forKey: ImportLedger.legacyFingerprintsKey),
                     "migrated once, not on every launch")
    }

    // MARK: - No database

    func testItStillWorksWithoutADatabase() async {
        // A device whose database would not open gets a slower app, not one that duplicates a
        // library — the same rule every other consumer of `LocalStore` follows.
        let sut = ImportLedger(store: nil, defaults: defaults)
        await sut.hydrate()

        await sut.record(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1", photoID: "photo-1")

        XCTAssertTrue(sut.contains(localIdentifier: "ABCD/L0/001"))
        let byBytes = await sut.contains(fingerprint: "hash-1")
        XCTAssertTrue(byBytes)
        XCTAssertEqual(defaults.stringArray(forKey: ImportLedger.legacyFingerprintsKey), ["hash-1"])
    }

    // MARK: - Forgetting

    func testForgettingClearsBothKeys() async throws {
        let store = try makeStore()
        let sut = ImportLedger(store: store, defaults: defaults)
        await sut.hydrate()
        await sut.record(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1", photoID: "photo-1")

        await sut.forget()

        XCTAssertFalse(sut.contains(localIdentifier: "ABCD/L0/001"))
        let byBytes = await sut.contains(fingerprint: "hash-1")
        XCTAssertFalse(byBytes)
        XCTAssertEqual(sut.count, 0)
        let stored = await store.importedCount()
        XCTAssertEqual(stored, 0)
    }

    func testSigningOutTakesTheLedgerWithIt() async throws {
        // The next account on this device has none of these photographs. A ledger that survived
        // would leave them with an empty library and an import that reports nothing to do.
        let store = try makeStore()
        try await store.recordImport(localIdentifier: "ABCD/L0/001", fingerprint: "hash-1",
                                     photoID: "photo-1")

        try await store.clear()

        let count = await store.importedCount()
        XCTAssertEqual(count, 0)
    }
}
