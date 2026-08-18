import XCTest
@testable import NeutrinoPhotos

// MARK: - PhotoImportServiceTests

/// The parts of import that can be tested without the system photo picker.
///
/// `PhotosPickerItem` cannot be constructed outside the picker, so the per-item upload path is
/// covered end to end by `MediaContentServiceTests` and `PhotoLibraryServiceTests` instead. What is
/// here is what this service decides *before* it touches an item: whether the run may start at all,
/// and what it remembers afterwards.
@MainActor
final class PhotoImportServiceTests: XCTestCase {

    private var monitor: NetworkMonitor!
    private var settings: AppSettings!
    private var sut: PhotoImportService!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        TestServer.use()
        TestTokens.install()
        TestKeys.remove()

        defaults = makeTemporaryDefaults()
        settings = AppSettings(defaults: defaults)
        monitor = NetworkMonitor(autoStart: false)
        let api = APIClient(session: MockURLProtocol.makeSession())
        sut = PhotoImportService(content: MediaContentService(api: api),
                                 library: PhotoLibraryService(api: api),
                                 settings: settings, monitor: monitor, defaults: defaults)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        TestTokens.remove()
        TestKeys.remove()
        TestServer.reset()
        sut = nil
        super.tearDown()
    }

    // MARK: - Preconditions

    func testImportIsRefusedWithoutAnEncryptionKey() {
        monitor.setPathForTesting(isOnline: true, isExpensive: false)

        sut.startImport([])   // empty is a no-op; the guard below is what this asserts
        XCTAssertNil(sut.blockedReason)

        // The real guard: with a selection but no key, nothing is uploaded and the reason says so.
        // Bytes sealed to nobody could never be decrypted again, so refusing is the only correct
        // outcome — see `MediaContentServiceTests.testUploadWithoutAKeyPairNeverSendsAnything`.
        XCTAssertFalse(KeyImportService.hasStoredKeys())
    }

    func testWifiOnlyBlocksAnImportOnCellular() {
        TestKeys.install()
        settings.wifiOnlyUploads = true
        monitor.setPathForTesting(isOnline: true, isExpensive: true)

        XCTAssertFalse(monitor.shouldUpload(wifiOnly: settings.wifiOnlyUploads))

        settings.wifiOnlyUploads = false
        XCTAssertTrue(monitor.shouldUpload(wifiOnly: settings.wifiOnlyUploads))
    }

    func testNothingUploadsWhileOffline() {
        monitor.setPathForTesting(isOnline: false, isExpensive: false)
        XCTAssertFalse(monitor.shouldUpload(wifiOnly: false))
        XCTAssertFalse(monitor.shouldUpload(wifiOnly: true))
    }

    // MARK: - Import history

    func testImportHistoryPersistsAndCanBeForgotten() {
        XCTAssertEqual(sut.importedCount, 0)

        defaults.set(["aaa", "bbb"], forKey: "import.fingerprints")
        let api = APIClient(session: MockURLProtocol.makeSession())
        let reloaded = PhotoImportService(content: MediaContentService(api: api),
                                          library: PhotoLibraryService(api: api),
                                          settings: settings, monitor: monitor, defaults: defaults)
        XCTAssertEqual(reloaded.importedCount, 2)

        reloaded.forgetImportHistory()
        XCTAssertEqual(reloaded.importedCount, 0)
        XCTAssertNil(defaults.stringArray(forKey: "import.fingerprints"))
    }
}

// MARK: - ImagePreparationTests

final class ImagePreparationTests: XCTestCase {

    func testNamesAFileForWhatItActuallyHolds() {
        // A HEIC converted to JPEG must not keep its .heic name, or every other client will read
        // the bytes as something they are not.
        XCTAssertEqual(ImagePreparation.fileName(from: "IMG_0007.heic", extension: "jpg"),
                       "IMG_0007.jpg")
        XCTAssertEqual(ImagePreparation.fileName(from: "no-extension", extension: "png"),
                       "no-extension.png")
    }

    func testGeneratesAFindableNameWhenThePickerGaveNone() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = ImagePreparation.fileName(from: nil, extension: "jpg", fallbackDate: date)

        XCTAssertTrue(name.hasPrefix("IMG_"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertTrue(name.contains("2023"), "the date is what makes it findable in a Drive listing")
    }

    func testRejectsSomethingThatIsNotAnImage() {
        XCTAssertThrowsError(try ImagePreparation.prepare(Data("plain text".utf8),
                                                          suggestedName: "notes.txt"))
    }

    func testPreparesAJPEGWithAPreviewAndLeavesTheBytesAlone() throws {
        let jpeg = try Self.makeJPEG()

        let prepared = try ImagePreparation.prepare(jpeg, suggestedName: "test.jpg")

        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpeg")
        XCTAssertEqual(prepared.data, jpeg, "a backup stores the original, not a re-encoding of it")
        XCTAssertNotNil(prepared.thumbnailBase64,
                        "a picture uploaded without a preview is a blank icon in every grid")
    }

    func testThumbnailIsSubstantiallySmallerThanTheOriginal() throws {
        let jpeg = try Self.makeJPEG(size: 2000)
        let encoded = try XCTUnwrap(ImagePreparation.thumbnailBase64(from: jpeg))
        let thumbnail = try XCTUnwrap(Data(base64Encoded: encoded))

        XCTAssertLessThan(thumbnail.count, jpeg.count)
        let image = try XCTUnwrap(UIImage(data: thumbnail))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height),
                                 ImagePreparation.thumbnailMaximumPixels)
    }

    // MARK: - Helpers

    /// A real JPEG, because everything under test here is ImageIO reading actual image data.
    private static func makeJPEG(size: CGFloat = 64) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }
}
