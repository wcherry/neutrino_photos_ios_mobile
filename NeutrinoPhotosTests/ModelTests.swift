import XCTest
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
@testable import NeutrinoPhotos

// MARK: - DriveDateTests

final class DriveDateTests: XCTestCase {

    func testReadsTheZonelessShapeDriveEmits() throws {
        // `NaiveDateTime`, microseconds, no zone — read as UTC, which is what the server means.
        let date = try XCTUnwrap(DriveDate.date(from: "2026-07-30T14:25:36.123456"))
        XCTAssertEqual(date.timeIntervalSince1970, 1785421536.123, accuracy: 0.001)
    }

    func testReadsTheRFC3339ShapeThePhotosEndpointsEmit() throws {
        let zulu = try XCTUnwrap(DriveDate.date(from: "2026-07-30T14:25:36.123456789Z"))
        let offset = DriveDate.date(from: "2026-07-30T14:25:36.123456789+00:00")
        XCTAssertEqual(zulu.timeIntervalSince1970, 1785421536.123, accuracy: 0.001)
        XCTAssertEqual(zulu, offset)
    }

    func testReadsATimestampWithNoFractionAtAll() {
        XCTAssertNotNil(DriveDate.date(from: "2026-07-30T14:25:36"))
        XCTAssertNotNil(DriveDate.date(from: "2026-07-30T14:25:36Z"))
    }

    func testAnOffsetIsNotConfusedWithTheDatesOwnHyphens() {
        let utc = DriveDate.date(from: "2026-07-30T14:25:36Z")!
        let behind = DriveDate.date(from: "2026-07-30T09:25:36-05:00")!
        XCTAssertEqual(utc, behind)
    }

    func testRejectsNonsense() {
        XCTAssertNil(DriveDate.date(from: ""))
        XCTAssertNil(DriveDate.date(from: "yesterday"))
        XCTAssertNil(DriveDate.date(from: "2026-07-30T14:25:36.12x456"))
    }

    func testWritesTheShapeThePhotosRegisterEndpointParses() {
        // `%Y-%m-%dT%H:%M:%S`: no zone, no fraction. Anything else is silently dropped there.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DriveDate.naiveUTCString(from: date), "2023-11-14T22:13:20")
    }

    func testRoundTripsThroughItsOwnFormat() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DriveDate.date(from: DriveDate.naiveUTCString(from: date)), date)
    }
}

// MARK: - MediaItemTests

final class MediaItemTests: XCTestCase {

    func testKindComesFromTheMIMEType() {
        XCTAssertEqual(Fixture.item(mimeType: "image/heic").kind, .photo)
        XCTAssertEqual(Fixture.item(mimeType: "video/quicktime").kind, .video)
        XCTAssertEqual(Fixture.item(mimeType: "application/pdf").kind, .other)
    }

    func testTimelineDatePrefersTheCaptureDate() {
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        let uploaded = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(Fixture.item(captureDate: taken, createdAt: uploaded).timelineDate, taken)
        XCTAssertEqual(Fixture.item(captureDate: nil, createdAt: uploaded).timelineDate, uploaded)
    }

    func testDisplayNameDropsTheExtension() {
        XCTAssertEqual(Fixture.item(fileName: "IMG_0001.jpg").displayName, "IMG_0001")
        XCTAssertEqual(Fixture.item(fileName: "no-extension").displayName, "no-extension")
        // A leading dot is the whole name, not an extension separator.
        XCTAssertEqual(Fixture.item(fileName: ".hidden").displayName, ".hidden")
    }

    func testThumbnailDataDecodesTheBase64TheListingCarries() {
        let encoded = Data("preview".utf8).base64EncodedString()
        XCTAssertEqual(Fixture.item(thumbnailBase64: encoded).thumbnailData, Data("preview".utf8))
        XCTAssertNil(Fixture.item(thumbnailBase64: nil).thumbnailData)
    }

    func testDecodesTheServersPhotoResponse() throws {
        let json = Fixture.photoJSON(id: "p", fileID: "f", thumbnail: "AAAA", isStarred: true)
        let item = try PhotoLibraryService.decoder.decode(MediaItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.id, "p")
        XCTAssertEqual(item.fileID, "f")
        XCTAssertEqual(item.thumbnailBase64, "AAAA")
        XCTAssertTrue(item.isStarred)
        XCTAssertNil(item.metadata)
    }

    func testDecodesExtractedMetadataWhenTheWorkerHasRun() throws {
        let json = """
        {"id":"p","fileId":"f","fileName":"a.jpg","mimeType":"image/jpeg","sizeBytes":10,
         "contentUrl":"/x","thumbnail":null,"thumbnailMimeType":null,"isStarred":false,
         "isArchived":false,"captureDate":null,"createdAt":"2026-07-30T14:25:36Z",
         "updatedAt":"2026-07-30T14:25:36Z",
         "metadata":{"width":4032,"height":3024,"format":"jpeg",
                     "exif":{"make":"Apple","model":"iPhone","iso":200,"fNumber":2.8,
                             "exposureTime":"1/120","gpsLatitude":51.5,"gpsLongitude":-0.12}}}
        """
        let item = try PhotoLibraryService.decoder.decode(MediaItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.formattedDimensions, "4032 × 3024")
        XCTAssertEqual(item.metadata?.exif?.exposureSummary, "ƒ2.8 · 1/120 · ISO 200")
        XCTAssertTrue(item.metadata?.exif?.hasLocation == true)
    }
}

// MARK: - AppSettingsTests

@MainActor
final class AppSettingsTests: XCTestCase {

    func testDefaultsAreTheSafeOnes() {
        let sut = AppSettings(defaults: makeTemporaryDefaults())

        XCTAssertEqual(sut.theme, .system)
        XCTAssertEqual(sut.timelineGrouping, .day)
        XCTAssertFalse(sut.showArchived, "archiving is pointless if archived items still show")
        XCTAssertTrue(sut.wifiOnlyUploads, "an unattended camera-roll import over cellular is a bill")
    }

    func testChangesPersistAndAreReadBack() {
        let defaults = makeTemporaryDefaults()
        let sut = AppSettings(defaults: defaults)

        sut.timelineGrouping = .year
        sut.wifiOnlyUploads = false
        sut.theme = .dark

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.timelineGrouping, .year)
        XCTAssertFalse(reloaded.wifiOnlyUploads)
        XCTAssertEqual(reloaded.theme, .dark)
    }

    func testResetRestoresEverything() {
        let sut = AppSettings(defaults: makeTemporaryDefaults())
        sut.timelineGrouping = .month
        sut.showArchived = true

        sut.resetToDefaults()

        XCTAssertEqual(sut.timelineGrouping, .day)
        XCTAssertFalse(sut.showArchived)
    }
}

// MARK: - KeyImportServiceTests

final class KeyImportServiceTests: XCTestCase {

    override func tearDown() {
        KeyImportService.removeKeys()
        super.tearDown()
    }

    func testImportsTheWebAppsExport() throws {
        let bundle = try KeyImportService.importKey(from: TestKeys.keyFileJSON())
        XCTAssertFalse(bundle.publicKey.isEmpty)
        XCTAssertEqual(bundle.keyVersion, "1")
    }

    func testAcceptsTheShortFieldSpellings() throws {
        let full = try JSONSerialization.jsonObject(with: TestKeys.keyFileJSON()) as! [String: String]
        let short = ["pk": full["public_key"]!, "sk": full["private_key"]!, "v": "2"]
        let data = try JSONSerialization.data(withJSONObject: short)

        XCTAssertEqual(try KeyImportService.importKey(from: data).keyVersion, "2")
    }

    func testRejectsAMismatchedPair() throws {
        var dict = try JSONSerialization.jsonObject(with: TestKeys.keyFileJSON()) as! [String: String]
        let other = try JSONSerialization.jsonObject(with: TestKeys.keyFileJSON()) as! [String: String]
        dict["public_key"] = other["public_key"]
        let data = try JSONSerialization.data(withJSONObject: dict)

        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            // Caught here rather than later, as an upload nobody can ever decrypt.
            XCTAssertEqual(error as? KeyImportError, .keyPairMismatch)
        }
    }

    func testRejectsPEM() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "public_key": "-----BEGIN PUBLIC KEY-----",
            "private_key": "-----BEGIN PRIVATE KEY-----",
        ])
        XCTAssertThrowsError(try KeyImportService.importKey(from: data)) { error in
            XCTAssertEqual(error as? KeyImportError, .unsupportedFormat)
        }
    }

    func testRejectsRubbish() {
        XCTAssertThrowsError(try KeyImportService.importKey(from: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? KeyImportError, .invalidJSON)
        }
    }

    func testStoresAndClearsTheKeychainEntries() {
        XCTAssertFalse(KeyImportService.hasStoredKeys())
        let bundle = TestKeys.install()

        XCTAssertTrue(KeyImportService.hasStoredKeys())
        XCTAssertEqual(KeyImportService.storedKeys(), bundle)

        KeyImportService.removeKeys()
        XCTAssertFalse(KeyImportService.hasStoredKeys())
        XCTAssertNil(KeyImportService.storedKeys())
    }
}

// MARK: - AccessTokenTests

final class AccessTokenTests: XCTestCase {

    override func tearDown() {
        TestTokens.remove()
        super.tearDown()
    }

    func testReadsTheSubjectClaim() {
        TestTokens.install()
        XCTAssertEqual(AccessToken.currentUserID(), TestTokens.userId)
    }

    func testAnswersNilWithoutAToken() {
        TestTokens.remove()
        XCTAssertNil(AccessToken.currentUserID())
    }

    func testAnswersNilForSomethingThatIsNotAJWT() {
        KeychainService.save("not-a-token", forKey: AuthService.accessTokenKey)
        XCTAssertNil(AccessToken.currentUserID())
    }
}
