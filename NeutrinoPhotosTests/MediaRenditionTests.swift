import UIKit
import XCTest
@testable import NeutrinoPhotos

// MARK: - MediaRenditionTests

/// The ladder: that each step is the size it claims, that the naming a rendition is found by round
/// trips, and that a rendition nobody would benefit from is not made.
final class MediaRenditionTests: XCTestCase {

    // MARK: - The ladder

    func testTheLadderAgreesWithTheWebApp() {
        // 512 is `generateThumbnail`'s size in the web client. A picture uploaded here and one
        // uploaded there have to be the same size in the same grid.
        XCTAssertEqual(MediaRendition.thumbnail.maximumPixels, 512)
        XCTAssertEqual(MediaRendition.thumbnail.jpegQuality, 0.8)
        XCTAssertEqual(MediaRendition.preview.maximumPixels, 2048)
        XCTAssertNil(MediaRendition.original.maximumPixels, "the original is whatever it is")
    }

    func testEachRenditionHasItsOwnCacheKey() {
        let suffixes = MediaRendition.allCases.map(\.cacheKeySuffix)
        XCTAssertEqual(Set(suffixes).count, suffixes.count,
                       "two renditions sharing a cache key means one overwrites the other")
    }

    // MARK: - Generating

    func testAThumbnailIsBoundedByItsLongestEdge() throws {
        let jpeg = TestImages.jpeg(size: 2000)

        let thumbnail = try XCTUnwrap(RenditionGenerator.jpeg(from: jpeg, rendition: .thumbnail))
        let image = try XCTUnwrap(UIImage(data: thumbnail))

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 512)
        XCTAssertLessThan(thumbnail.count, jpeg.count)
    }

    func testAPreviewIsBiggerThanAThumbnailAndSmallerThanTheOriginal() throws {
        let jpeg = TestImages.jpeg(size: 4000)

        let thumbnail = try XCTUnwrap(RenditionGenerator.jpeg(from: jpeg, rendition: .thumbnail))
        let preview = try XCTUnwrap(RenditionGenerator.jpeg(from: jpeg, rendition: .preview))

        XCTAssertGreaterThan(preview.count, thumbnail.count)
        let image = try XCTUnwrap(UIImage(data: preview))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 2048)
    }

    func testTheOriginalHasNoRenditionToMake() {
        XCTAssertNil(RenditionGenerator.jpeg(from: TestImages.jpeg(), rendition: .original))
    }

    func testSomethingThatIsNotAnImageProducesNoRendition() {
        // Answering nil rather than throwing is what lets an upload proceed without a preview.
        XCTAssertNil(RenditionGenerator.jpeg(from: Data("plain text".utf8), rendition: .thumbnail))
        XCTAssertNil(RenditionGenerator.previewWorthUploading(for: Data("plain text".utf8)))
    }

    // MARK: - Worth uploading

    func testAPreviewIsUploadedForAPictureBigEnoughToBenefit() throws {
        let large = TestImages.jpeg(size: 4000)

        let preview = try XCTUnwrap(RenditionGenerator.previewWorthUploading(for: large))
        XCTAssertLessThan(Double(preview.count),
                          Double(large.count) * RenditionGenerator.previewSavingThreshold)
    }

    func testNoPreviewIsUploadedForAPictureAlreadySmallerThanOne() {
        // A screenshot thumbnail or a web graphic: the rendition would be no smaller than the file
        // it is a rendition of, so uploading it is a second file, a second key, and a second
        // request bought for nothing.
        XCTAssertNil(RenditionGenerator.previewWorthUploading(for: TestImages.jpeg(size: 64)))
    }

    // MARK: - Naming

    func testARenditionNameRoundTripsToItsOriginal() throws {
        let name = MediaRendition.renditionFileName(forOriginal: "file-abc", rendition: .preview)

        let parsed = try XCTUnwrap(MediaRendition.originalFileID(fromRenditionName: name))
        XCTAssertEqual(parsed.fileID, "file-abc")
        XCTAssertEqual(parsed.rendition, .preview)
    }

    func testAnUnrelatedFileNameIsNotMistakenForARendition() {
        // The renditions folder is a Drive folder like any other; a user can put things in it, and
        // reading one of those as a rendition would map a photograph to bytes that are not of it.
        XCTAssertNil(MediaRendition.originalFileID(fromRenditionName: "IMG_0001.jpg"))
        XCTAssertNil(MediaRendition.originalFileID(fromRenditionName: "file.notarendition.jpg"))
        XCTAssertNil(MediaRendition.originalFileID(fromRenditionName: "file.preview.png"))
    }

    // MARK: - Decoding

    func testDownsamplingRespectsTheRequestedBound() throws {
        let jpeg = TestImages.jpeg(size: 1000)

        let image = try XCTUnwrap(RenditionGenerator.image(from: jpeg, maxPixels: 100))

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 100)
    }

    func testPixelSizeIsReadWithoutDecoding() throws {
        let size = try XCTUnwrap(RenditionGenerator.pixelSize(of: TestImages.jpeg(size: 300)))

        XCTAssertEqual(size.width, 300)
        XCTAssertEqual(size.height, 300)
    }
}
