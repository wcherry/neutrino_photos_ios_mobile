import XCTest
@testable import NeutrinoPhotos

// MARK: - MediaMetadataExtractorTests

/// Reading a photograph's own account of itself.
///
/// Against real JPEGs with real EXIF written into them by `CGImageDestination`, not against a
/// hand-built dictionary: what is under test is whether this reads what a camera writes, and a
/// fixture that skipped the file format would assert only that ImageIO can round-trip a `CFDictionary`.
final class MediaMetadataExtractorTests: XCTestCase {

    // MARK: - Extraction

    func testReadsDimensionsCameraAndExposureFromAPhotograph() throws {
        let jpeg = TestImages.jpegWithMetadata(size: 128)

        let metadata = try XCTUnwrap(MediaMetadataExtractor.metadata(from: jpeg))

        XCTAssertEqual(metadata.width, 128)
        XCTAssertEqual(metadata.height, 128)
        XCTAssertEqual(metadata.format, "public.jpeg")

        let exif = try XCTUnwrap(metadata.exif)
        XCTAssertEqual(exif.make, "Apple")
        XCTAssertEqual(exif.model, "iPhone 15 Pro")
        XCTAssertEqual(exif.lensModel, "iPhone 15 Pro back triple camera 6.765mm f/1.78")
        XCTAssertEqual(exif.exposureTime, "1/120s")
        XCTAssertEqual(exif.fNumber ?? 0, 1.78, accuracy: 0.01)
        XCTAssertEqual(exif.iso, 200)
        XCTAssertEqual(exif.focalLength ?? 0, 6.765, accuracy: 0.01)
        XCTAssertEqual(exif.datetimeOriginal, "2024:06:15 14:25:36")
    }

    func testAPictureWithNoEXIFYieldsDimensionsAndNoCameraBlock() throws {
        // A screenshot, a web graphic, anything a program drew. It still has a size, and it must not
        // produce a `MediaExif` full of nulls — the info panel shows what is there, and a camera
        // section with nothing in it is worse than none.
        let plain = TestImages.jpeg(size: 64)

        let metadata = try XCTUnwrap(MediaMetadataExtractor.metadata(from: plain))

        XCTAssertEqual(metadata.width, 64)
        XCTAssertNil(metadata.exif, "an empty EXIF record is dropped rather than stored")
    }

    func testSomethingThatIsNotAnImageExtractsNothing() {
        XCTAssertNil(MediaMetadataExtractor.metadata(from: Data("plain text".utf8)))
    }

    // MARK: - GPS

    func testReadsCoordinatesInTheNorthernAndEasternHemispheres() throws {
        let jpeg = TestImages.jpegWithMetadata(latitude: 51.5074, latitudeRef: "N",
                                               longitude: 0.1278, longitudeRef: "E")

        let exif = try XCTUnwrap(MediaMetadataExtractor.metadata(from: jpeg)?.exif)

        XCTAssertTrue(exif.hasLocation)
        XCTAssertEqual(exif.gpsLatitude ?? 0, 51.5074, accuracy: 0.0001)
        XCTAssertEqual(exif.gpsLongitude ?? 0, 0.1278, accuracy: 0.0001)
    }

    func testAppliesTheHemisphereRefRatherThanDroppingIt() throws {
        // EXIF stores a magnitude and a hemisphere separately, so Santiago and Boston carry the
        // same latitude and differ by one character. Ignoring the ref puts half the planet in the
        // wrong hemisphere — and, worse, plausibly so.
        let jpeg = TestImages.jpegWithMetadata(latitude: 33.4489, latitudeRef: "S",
                                               longitude: 70.6693, longitudeRef: "W")

        let exif = try XCTUnwrap(MediaMetadataExtractor.metadata(from: jpeg)?.exif)

        XCTAssertEqual(exif.gpsLatitude ?? 0, -33.4489, accuracy: 0.0001)
        XCTAssertEqual(exif.gpsLongitude ?? 0, -70.6693, accuracy: 0.0001)
    }

    func testNullIslandIsReadAsNoFixRatherThanAsAPlace() throws {
        // 0,0 is in the Gulf of Guinea and is what a camera with no satellite lock writes. Storing
        // it would put a pin on every unlocated photograph in the same empty patch of ocean.
        let jpeg = TestImages.jpegWithMetadata(latitude: 0, longitude: 0)

        let metadata = try XCTUnwrap(MediaMetadataExtractor.metadata(from: jpeg))

        XCTAssertFalse(metadata.exif?.hasLocation ?? false)
    }

    // MARK: - Exposure formatting

    func testExposureTimeIsFormattedTheWayACameraWouldShowIt() {
        XCTAssertEqual(MediaMetadataExtractor.exposureTimeString(1.0 / 120), "1/120s")
        XCTAssertEqual(MediaMetadataExtractor.exposureTimeString(1.0 / 8000), "1/8000s")
        XCTAssertEqual(MediaMetadataExtractor.exposureTimeString(2), "2s")
        XCTAssertEqual(MediaMetadataExtractor.exposureTimeString(0.5), "1/2s")
        XCTAssertEqual(MediaMetadataExtractor.exposureTimeString(1.5), "1.5s")
        // Not "0s", which is what rounding a fast shutter to a whole number produces and which is
        // the same fact spelled wrongly.
        XCTAssertNotEqual(MediaMetadataExtractor.exposureTimeString(1.0 / 4000), "0s")
    }

    // MARK: - Merging with the device library

    func testTheAssetSuppliesWhatTheFileCannot() throws {
        let plain = try XCTUnwrap(MediaMetadataExtractor.metadata(from: TestImages.jpeg(size: 64)))
        let asset = DeviceAsset.fixture(coordinate: (latitude: 48.8584, longitude: 2.2945),
                                        isLivePhoto: true, subtypes: ["live", "hdr"])

        let merged = try XCTUnwrap(MediaMetadataExtractor.merged(plain, with: asset,
                                                                 liveVideoFileID: "live-file"))

        XCTAssertEqual(merged.exif?.gpsLatitude ?? 0, 48.8584, accuracy: 0.0001)
        XCTAssertEqual(merged.device?.localIdentifier, asset.localIdentifier)
        XCTAssertEqual(merged.device?.isLivePhoto, true)
        XCTAssertEqual(merged.device?.subtypes, ["live", "hdr"])
        XCTAssertEqual(merged.device?.liveVideoFileID, "live-file")
        XCTAssertEqual(merged.width, 64, "the file's own dimensions win over the asset's")
    }

    func testTheFilesOwnCoordinatesWinOverTheLibrarys() throws {
        // The picture carries what the camera recorded at the moment of the shot; Apple Photos'
        // copy may have been edited since. Where both exist, the one in the file is the original.
        let jpeg = TestImages.jpegWithMetadata(latitude: 51.5074, longitude: 0.1278)
        let extracted = MediaMetadataExtractor.metadata(from: jpeg)
        let asset = DeviceAsset.fixture(coordinate: (latitude: 0.1, longitude: 0.2))

        let merged = try XCTUnwrap(MediaMetadataExtractor.merged(extracted, with: asset))

        XCTAssertEqual(merged.exif?.gpsLatitude ?? 0, 51.5074, accuracy: 0.0001)
    }

    func testAVideoGetsARecordFromTheAssetAlone() throws {
        // Nothing in this app parses a video container, so the asset is the only source there is.
        let asset = DeviceAsset.fixture(isFavorite: true, subtypes: ["slowMotion"],
                                        pixelWidth: 3840, pixelHeight: 2160)

        let merged = try XCTUnwrap(MediaMetadataExtractor.merged(nil, with: asset))

        XCTAssertEqual(merged.width, 3840)
        XCTAssertEqual(merged.height, 2160)
        XCTAssertEqual(merged.device?.subtypes, ["slowMotion"])
    }

    func testWithNoAssetAndNoMotionTheExtractedRecordPassesThroughUntouched() {
        let extracted = MediaMetadataExtractor.metadata(from: TestImages.jpegWithMetadata())

        XCTAssertEqual(MediaMetadataExtractor.merged(extracted, with: nil), extracted)
        XCTAssertNil(MediaMetadataExtractor.merged(nil, with: nil))
    }
}

// MARK: - MediaMetadataTests

/// The model's own rules: what is redacted before publication, and what survives a round trip
/// through a server that never saw half of it.
final class MediaMetadataTests: XCTestCase {

    func testStrippingLocationLeavesEverythingElseAlone() {
        let metadata = MediaMetadata(
            width: 4032, height: 3024, format: "public.jpeg",
            exif: MediaExif(make: "Apple", model: "iPhone 15 Pro", lensModel: "wide",
                            exposureTime: "1/120s", fNumber: 1.78, iso: 200, focalLength: 6.7,
                            gpsLatitude: 51.5, gpsLongitude: 0.12,
                            datetimeOriginal: "2024:06:15 14:25:36"),
            device: MediaDeviceFacts(localIdentifier: "asset-1", isLivePhoto: true))

        let published = metadata.withoutLocation

        XCTAssertNil(published.exif?.gpsLatitude)
        XCTAssertNil(published.exif?.gpsLongitude)
        XCTAssertFalse(published.exif?.hasLocation ?? true)
        XCTAssertEqual(published.exif?.make, "Apple")
        XCTAssertEqual(published.exif?.exposureTime, "1/120s")
        XCTAssertEqual(published.width, 4032)
        XCTAssertEqual(published.device?.localIdentifier, "asset-1",
                       "only the coordinates are held back, not the whole record")
    }

    func testAnEmptyRecordIsRecognisedSoNothingIsWrittenOrSent() {
        XCTAssertTrue(MediaMetadata().isEmpty)
        XCTAssertTrue(MediaExif().isEmpty)
        XCTAssertFalse(MediaMetadata(width: 100).isEmpty)
        XCTAssertFalse(MediaExif(gpsLatitude: 1, gpsLongitude: 2).isEmpty)
    }

    func testTheServersCopyIsMergedWithTheLocationOnlyThisDeviceHolds() {
        // The exact shape of a refresh for a user who did not opt in to publishing location: the
        // listing comes back without coordinates, and overwriting the local record with it would
        // blank the info panel on every photograph they own.
        let local = MediaMetadata(
            width: 4032, height: 3024,
            exif: MediaExif(make: "Apple", gpsLatitude: 51.5, gpsLongitude: 0.12),
            device: MediaDeviceFacts(localIdentifier: "asset-1", isRAW: true))
        let fromServer = MediaMetadata(width: 4032, height: 3024,
                                       exif: MediaExif(make: "Apple", iso: 400))

        let merged = fromServer.mergingDeviceOnlyFacts(from: local)

        XCTAssertEqual(merged.exif?.gpsLatitude ?? 0, 51.5, accuracy: 0.001)
        XCTAssertEqual(merged.exif?.iso, 400, "the server's copy still wins for what it carries")
        XCTAssertEqual(merged.device?.isRAW, true)
    }

    func testAPublishedLocationIsNotOverwrittenByAStaleLocalOne() {
        let local = MediaMetadata(exif: MediaExif(gpsLatitude: 1, gpsLongitude: 1))
        let fromServer = MediaMetadata(exif: MediaExif(gpsLatitude: 51.5, gpsLongitude: 0.12))

        let merged = fromServer.mergingDeviceOnlyFacts(from: local)

        XCTAssertEqual(merged.exif?.gpsLatitude ?? 0, 51.5, accuracy: 0.001)
    }

    // MARK: - Wire shape

    func testDecodesTheFieldsThisAppWritesAndIgnoresOnesItDoesNot() throws {
        // The endpoint stores an opaque JSON blob, so a record written by a newer build has to
        // decode here rather than failing the whole listing.
        let json = """
        {"width":4032,"height":3024,"format":"public.jpeg",
         "exif":{"make":"Apple","lensModel":"wide","gpsLatitude":51.5,"gpsLongitude":0.12},
         "device":{"localIdentifier":"asset-1","isLivePhoto":true,"isRAW":false,
                   "subtypes":["live"],"liveVideoFileID":"video-1"},
         "somethingFromTheFuture":{"a":1}}
        """

        let metadata = try JSONDecoder().decode(MediaMetadata.self, from: Data(json.utf8))

        XCTAssertEqual(metadata.width, 4032)
        XCTAssertEqual(metadata.exif?.lensModel, "wide")
        XCTAssertEqual(metadata.device?.liveVideoFileID, "video-1")
        XCTAssertEqual(metadata.device?.subtypes, ["live"])
    }

    func testAnItemReportsWhatItIsFromItsDeviceFacts() {
        let live = Fixture.item(metadata: MediaMetadata(
            device: MediaDeviceFacts(isLivePhoto: true, liveVideoFileID: "video-1")))
        XCTAssertTrue(live.isLivePhoto)
        XCTAssertEqual(live.liveVideoFileID, "video-1")

        let raw = Fixture.item(metadata: MediaMetadata(device: MediaDeviceFacts(isRAW: true)))
        XCTAssertTrue(raw.isRAW)
        XCTAssertFalse(raw.isLivePhoto)

        // An item uploaded by the web app, or by a build with no photo access: no device block at
        // all, and every one of these questions answers no rather than crashing.
        let plain = Fixture.item()
        XCTAssertFalse(plain.isLivePhoto)
        XCTAssertFalse(plain.isRAW)
        XCTAssertNil(plain.liveVideoFileID)
    }
}
