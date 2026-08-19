import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - MediaRendition

/// The three sizes a photograph exists in, and what each one is for.
///
/// ## The ladder
///
/// | | Longest edge | Generated | Stored | Used by |
/// |---|---|---|---|---|
/// | ``thumbnail`` | 512 px | on the uploading device | **plaintext** on the Drive file, and in ``ThumbnailCache`` | the grid |
/// | ``preview`` | 2048 px | on the uploading device | **encrypted**, as a second Drive file | the viewer |
/// | ``original`` | as the camera wrote it | not at all | **encrypted**, the Drive file itself | zoom, export, save-back |
///
/// ## Why the thumbnail is plaintext and the preview is not
///
/// A grid cell has to draw before any key is imported — that is what makes a locked library
/// browsable — and it has to draw a thousand of them from one listing response rather than a
/// thousand downloads. So the 512 px cover thumbnail rides along with the file's metadata in the
/// clear, exactly as the web app writes it. It is small enough to be a contact sheet and too small
/// to be the photograph.
///
/// Everything above that is the photograph, and is encrypted like one.
///
/// ## Why the preview is worth uploading
///
/// Opening one picture on a phone otherwise means fetching a 4 MB original to fill a screen that
/// holds about 400 KB of it. The preview costs about a tenth of the original's bytes once, and
/// saves the other nine tenths every time the item is opened on any device. It is generated where
/// the plaintext already is — the uploading device — because nowhere else can: the server holds
/// ciphertext and has no key.
///
/// A rendition is never *required*. Anything missing one falls back to the step below it in the
/// ladder, which is why `previewData` can answer from a downloaded original and why a failed
/// rendition upload does not fail an import.
enum MediaRendition: String, CaseIterable {

    /// The grid's contact sheet.
    case thumbnail

    /// What the viewer opens at.
    case preview

    /// The bytes as they were uploaded.
    case original

    // MARK: - Geometry

    /// Longest edge in pixels, or nil for ``original``, which is whatever it is.
    ///
    /// 512 is the web app's `generateThumbnail` size, so a picture uploaded here and one uploaded
    /// there are the same size in the same grid. 2048 covers the longest edge of every iPhone and
    /// iPad screen at 3× with room to spare, which is the point at which a bigger preview stops
    /// being visible and starts being bandwidth.
    var maximumPixels: CGFloat? {
        switch self {
        case .thumbnail: return 512
        case .preview:   return 2048
        case .original:  return nil
        }
    }

    /// JPEG quality for the generated renditions. 0.8 is the web app's thumbnail setting; the
    /// preview is held slightly higher because it is looked *at* rather than glanced at.
    var jpegQuality: CGFloat {
        switch self {
        case .thumbnail: return 0.8
        case .preview:   return 0.85
        case .original:  return 1
        }
    }

    /// Suffix distinguishing this rendition's entry in a cache keyed by Drive file id.
    var cacheKeySuffix: String {
        switch self {
        case .thumbnail: return "-thumb.jpg"
        case .preview:   return "-preview.jpg"
        case .original:  return ""
        }
    }

    /// The name a preview rendition is stored under in Drive, given the original's file id.
    ///
    /// The name is the *index*: nothing on the photo record can hold a rendition's file id, so a
    /// device that did not perform the upload finds a preview by listing the renditions folder and
    /// reading the names. Changing this format orphans every rendition already uploaded.
    static func renditionFileName(forOriginal fileID: String, rendition: MediaRendition) -> String {
        "\(fileID).\(rendition.rawValue).jpg"
    }

    /// Reverses ``renditionFileName(forOriginal:rendition:)``.
    static func originalFileID(fromRenditionName name: String) -> (fileID: String, rendition: MediaRendition)? {
        let parts = name.split(separator: ".")
        guard parts.count == 3, parts[2] == "jpg",
              let rendition = MediaRendition(rawValue: String(parts[1])) else { return nil }
        return (String(parts[0]), rendition)
    }
}

// MARK: - RenditionGenerator

/// Makes the smaller steps of the ladder out of the bigger ones.
///
/// Everything here goes through ImageIO rather than `UIImage`. Decoding a 12-megapixel photograph
/// with `UIImage(data:)` to draw it 500 px wide holds about 48 MB of bitmap to throw 47 of them
/// away; `CGImageSourceCreateThumbnailAtIndex` decodes straight to the size asked for. On an import
/// run that difference is the difference between a working phone and one the OS kills.
///
/// Nothing here is on an actor: generating a rendition is CPU work that belongs off the main thread,
/// and every input and output is a value.
enum RenditionGenerator {

    // MARK: - Bitmaps

    /// Decodes `data` at no more than `maxPixels` on its longest edge.
    static func image(from data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let cgImage = cgImage(from: data, maxPixels: maxPixels) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Decodes `data` whole — for an export, where "the original" means the original.
    static func image(from data: Data) -> UIImage? {
        UIImage(data: data)
    }

    private static func cgImage(from data: Data, maxPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Without this a photograph taken in portrait displays sideways: the rotation lives in
            // the file's EXIF orientation, which a re-encoded bitmap does not carry.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Renditions

    /// A JPEG of `data` at `rendition`'s size, or nil when `data` is not an image this device can
    /// read. ``MediaRendition/original`` has no rendition to make and always answers nil.
    ///
    /// Answers nil rather than throwing throughout: a picture whose preview could not be made is
    /// still a picture worth uploading, and every caller here has a fallback.
    static func jpeg(from data: Data, rendition: MediaRendition) -> Data? {
        guard let maxPixels = rendition.maximumPixels,
              let cgImage = cgImage(from: data, maxPixels: maxPixels) else { return nil }

        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: rendition.jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return jpeg as Data
    }

    /// The preview to upload alongside an original, or nil when one is not worth uploading.
    ///
    /// Two ways to not be worth it. A picture already smaller than the preview would produce a
    /// rendition no smaller than the file it is a rendition *of* — a screenshot thumbnail, a web
    /// graphic — and uploading that is pure cost. And a saving under ``previewSavingThreshold``
    /// does not pay for a second file, a second key, and a second request. Both cases fall back to
    /// the original at read time, which is exactly what happens for every photograph uploaded
    /// before this existed.
    static func previewWorthUploading(for data: Data) -> Data? {
        guard let preview = jpeg(from: data, rendition: .preview) else { return nil }
        guard Double(preview.count) < Double(data.count) * previewSavingThreshold else { return nil }
        return preview
    }

    /// A preview has to come in under this fraction of the original to earn its upload.
    static let previewSavingThreshold = 0.7

    // MARK: - Inspection

    /// The stored pixel dimensions of `data`, without decoding it.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Bytes of bitmap a decoded image occupies — the cost an `NSCache` should be told about, which
    /// is not the size of the file it came from.
    static func bitmapCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
