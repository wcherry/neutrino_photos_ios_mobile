import CoreGraphics
import Foundation
import ImageIO

// MARK: - MediaMetadataExtractor

/// Reads a picture's dimensions, camera, exposure, and coordinates out of its own bytes.
///
/// ## Why this is the device's job
///
/// The server has a metadata worker, and for a file uploaded in the clear it is the right place for
/// this: it can open the picture. Nothing this app uploads is in the clear. The bytes that reach
/// Neutrino are ciphertext and the key never leaves the phone, so an encrypted photograph's EXIF is
/// readable in exactly one place — here, on the device that still has the plaintext, in the seconds
/// between the picker handing it over and the upload sealing it.
///
/// That is why `MediaItem.metadata` was nil for every item this app had ever imported, and why the
/// info panel had nothing to show but a file name.
///
/// ## What it does not do
///
/// No decoding. Every property here comes from `CGImageSourceCopyPropertiesAtIndex`, which reads the
/// file's headers and stops — a 48-megapixel photograph costs a few kilobytes of parsing rather than
/// 200 MB of bitmap. Nothing here is on an actor; every input and output is a value, so an import
/// runs it on the same background task that does the encryption.
enum MediaMetadataExtractor {

    // MARK: - Extraction

    /// Everything readable from `data`, or nil when it is not an image or carries nothing at all.
    static func metadata(from data: Data) -> MediaMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return metadata(from: source)
    }

    static func metadata(from source: CGImageSource) -> MediaMetadata? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps  = properties[kCGImagePropertyGPSDictionary]  as? [CFString: Any] ?? [:]

        let coordinate = self.coordinate(from: gps)
        let record = MediaExif(
            make: string(tiff[kCGImagePropertyTIFFMake]),
            model: string(tiff[kCGImagePropertyTIFFModel]),
            lensModel: string(exif[kCGImagePropertyExifLensModel]),
            exposureTime: (exif[kCGImagePropertyExifExposureTime] as? Double)
                .map(exposureTimeString(_:)),
            fNumber: exif[kCGImagePropertyExifFNumber] as? Double,
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double,
            gpsLatitude: coordinate?.latitude,
            gpsLongitude: coordinate?.longitude,
            datetimeOriginal: string(exif[kCGImagePropertyExifDateTimeOriginal])
                ?? string(exif[kCGImagePropertyExifDateTimeDigitized])
        )

        // The stored pixel dimensions, which are what every other client reports. Not the *displayed*
        // ones: a portrait photograph from an iPhone is stored landscape with an EXIF orientation
        // tag, and reporting 3024 × 4032 here would disagree with the same file opened anywhere else.
        let metadata = MediaMetadata(
            width: (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            height: (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            format: CGImageSourceGetType(source).map { $0 as String },
            exif: record.isEmpty ? nil : record
        )
        return metadata.isEmpty ? nil : metadata
    }

    // MARK: - Merging

    /// Folds what the device library knew into what the file said.
    ///
    /// The two disagree in one direction that matters: a `PHAsset` has a creation date for every
    /// item, including the screenshots and the edited exports that carry no EXIF at all. Where both
    /// have something, the file wins for anything about the *picture* and the asset wins for
    /// anything about the *library* — which is the only sensible split, since neither can observe
    /// the other's half.
    static func merged(_ extracted: MediaMetadata?, with asset: DeviceAsset?,
                       liveVideoFileID: String? = nil) -> MediaMetadata? {
        guard asset != nil || liveVideoFileID != nil else { return extracted }

        var exif = extracted?.exif
        if let coordinate = asset?.coordinate, exif?.hasLocation != true {
            // The asset's location is the fallback, not the override: a picture whose own EXIF
            // carries coordinates is carrying the ones the camera recorded, and Apple Photos'
            // may have been edited since.
            exif = MediaExif(make: exif?.make, model: exif?.model, lensModel: exif?.lensModel,
                             exposureTime: exif?.exposureTime, fNumber: exif?.fNumber,
                             iso: exif?.iso, focalLength: exif?.focalLength,
                             gpsLatitude: coordinate.latitude, gpsLongitude: coordinate.longitude,
                             datetimeOriginal: exif?.datetimeOriginal)
        }

        let facts = MediaDeviceFacts(
            localIdentifier: asset?.localIdentifier,
            isLivePhoto: asset.map(\.isLivePhoto),
            isRAW: asset.map(\.isRAW),
            subtypes: asset.map(\.subtypes).flatMap { $0.isEmpty ? nil : $0 },
            liveVideoFileID: liveVideoFileID
        )

        return MediaMetadata(width: extracted?.width ?? asset?.pixelWidth,
                             height: extracted?.height ?? asset?.pixelHeight,
                             format: extracted?.format,
                             exif: exif,
                             device: facts)
    }

    // MARK: - Formatting

    /// EXIF's exposure time is a number of seconds; every camera in the world displays it as a
    /// fraction. "1/120s" and "2s" — never "0.008333333s", which is the same fact spelled
    /// unreadably, and never "0" for a fast shutter, which is the same fact spelled wrongly.
    static func exposureTimeString(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0s" }
        guard seconds < 1 else {
            // Trailing zeros dropped: "2s", not "2.0s".
            let rounded = (seconds * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? String(format: "%.0fs", rounded)
                : String(format: "%.1fs", rounded)
        }
        return "1/\(Int((1 / seconds).rounded()))s"
    }

    // MARK: - GPS

    /// EXIF stores a magnitude and a hemisphere separately, so a photograph taken in Santiago and
    /// one taken in Boston carry the same latitude and differ only in a one-character tag. Dropping
    /// the ref puts half the planet in the wrong hemisphere.
    private static func coordinate(from gps: [CFString: Any]) -> (latitude: Double,
                                                                  longitude: Double)? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latitudeRef = string(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased() ?? "N"
        let longitudeRef = string(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased() ?? "E"
        // 0,0 is in the Gulf of Guinea and is what a camera with no fix writes, so it is read as
        // "no location" rather than as a place nobody photographed.
        guard latitude != 0 || longitude != 0 else { return nil }
        return (latitude * (latitudeRef == "S" ? -1 : 1),
                longitude * (longitudeRef == "W" ? -1 : 1))
    }

    // MARK: - Helpers

    /// Trims, and answers nil for the empty string. ImageIO hands back `" "` for a camera that
    /// wrote a blank tag, and a blank row in the info panel is worse than an absent one.
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
