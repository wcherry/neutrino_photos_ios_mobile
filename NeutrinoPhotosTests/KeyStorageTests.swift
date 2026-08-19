import XCTest
@testable import NeutrinoPhotos

// MARK: - KeychainAccessibilityTests

/// Where the encryption key is allowed to live, and when it is readable.
///
/// These attributes have no visible effect until they are wrong — a `WhenUnlocked` item silently
/// stops background upload the moment the screen locks, and one without `ThisDeviceOnly` puts an
/// end-to-end encryption key into an iCloud backup. Both fail quietly, so they are asserted.
final class KeychainAccessibilityTests: XCTestCase {

    private let key = "nphoto.tests.accessibility"

    override func tearDown() {
        KeychainService.delete(forKey: key)
        super.tearDown()
    }

    func testItemsAreReadableAfterFirstUnlockAndNeverLeaveTheDevice() {
        KeychainService.save("secret", forKey: key)

        XCTAssertEqual(KeychainService.accessibility(forKey: key),
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "AfterFirstUnlock so a background upload can still seal a file key with the screen locked; ThisDeviceOnly so the key is never restored onto another device")
    }

    func testOverwritingAnItemKeepsTheAccessibilityRatherThanInheritingTheOldOne() {
        // `SecItemUpdate` changes only the attributes it is handed, so an item written by an older
        // build with different accessibility would keep it forever if the update omitted it.
        KeychainService.save("first", forKey: key)
        KeychainService.save("second", forKey: key)

        XCTAssertEqual(KeychainService.load(forKey: key), "second")
        XCTAssertEqual(KeychainService.accessibility(forKey: key),
                       KeychainService.accessibility as String)
    }

    func testTheEncryptionKeyItselfIsStoredThatWay() {
        TestKeys.install()
        defer { TestKeys.remove() }

        for key in [KeyImportService.publicKeyKeychainKey,
                    KeyImportService.privateKeyKeychainKey,
                    KeyImportService.keyVersionKeychainKey] {
            XCTAssertEqual(KeychainService.accessibility(forKey: key),
                           KeychainService.accessibility as String, key)
        }
    }
}

// MARK: - KeyFileRouterTests

/// Opening a `.json` key file handed to the app from outside — AirDropped, or tapped in Files.
@MainActor
final class KeyFileRouterTests: XCTestCase {

    private var sut: KeyFileRouter!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        TestKeys.remove()
        sut = KeyFileRouter()
        directory = makeTemporaryDirectory()
    }

    override func tearDown() {
        TestKeys.remove()
        sut = nil
        directory = nil
        super.tearDown()
    }

    // MARK: - Routing

    func testOnlyClaimsLocalJSONFiles() {
        XCTAssertTrue(KeyFileRouter.canHandle(URL(fileURLWithPath: "/tmp/key.json")))
        XCTAssertTrue(KeyFileRouter.canHandle(URL(fileURLWithPath: "/tmp/KEY.JSON")))
        XCTAssertFalse(KeyFileRouter.canHandle(URL(fileURLWithPath: "/tmp/photo.jpg")))
        // A Universal Link belongs to whatever handles those, not to this.
        XCTAssertFalse(KeyFileRouter.canHandle(URL(string: "https://www.getneutrino.app/open/photo/1")!))
    }

    func testANonKeyURLIsLeftForSomethingElse() {
        let handled = sut.handle(URL(string: "https://www.getneutrino.app/open/photo/1")!)

        XCTAssertFalse(handled)
        XCTAssertNil(sut.outcome)
    }

    // MARK: - Importing

    func testImportsAKeyFileAndStoresIt() throws {
        let url = directory.appendingPathComponent("neutrino-key.json")
        try TestKeys.keyFileJSON().write(to: url)

        XCTAssertTrue(sut.handle(url))

        XCTAssertEqual(sut.outcome, .imported("neutrino-key.json"))
        XCTAssertTrue(KeyImportService.hasStoredKeys())
    }

    func testAMalformedKeyFileIsReportedRatherThanDropped() throws {
        let url = directory.appendingPathComponent("broken.json")
        try Data("not json at all".utf8).write(to: url)

        XCTAssertTrue(sut.handle(url), "still consumed — a file that appears to do nothing is worse")

        XCTAssertEqual(sut.outcome, .failed(KeyImportError.invalidJSON.localizedDescription))
        XCTAssertFalse(KeyImportService.hasStoredKeys())
    }

    func testAMismatchedKeyPairIsRefusedBeforeItIsStored() throws {
        // Caught here rather than discovered later as photographs nobody can decrypt.
        let url = directory.appendingPathComponent("mismatched.json")
        let dict = ["public_key": TestKeys.base64URL(Data(repeating: 1, count: 32)),
                    "private_key": TestKeys.base64URL(Data(repeating: 2, count: 32))]
        try JSONSerialization.data(withJSONObject: dict).write(to: url)

        XCTAssertTrue(sut.handle(url))

        XCTAssertEqual(sut.outcome, .failed(KeyImportError.keyPairMismatch.localizedDescription))
        XCTAssertFalse(KeyImportService.hasStoredKeys())
    }
}
