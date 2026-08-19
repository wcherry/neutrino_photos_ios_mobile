import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - ImagePreparation

/// Turns what the photo picker hands over into what Drive should store.
///
/// ## The original is what gets stored
///
/// The bytes go up at the resolution and in the format the camera wrote them, which is what the web
/// app does and what a *backup* has to mean — a library that silently re-compressed everything on
/// the way in is not one anybody can migrate back out of. Nothing is resized here; the memory that
/// resizing would have saved is saved at the other end instead, by
/// ``MediaContentService/downsample(data:maxPixels:)`` decoding to the size on screen rather than
/// the size on disk.
///
/// ## The one exception
///
/// HEIC is converted to JPEG. It is what an iPhone camera writes and what most browsers cannot
/// display, so a photograph stored as it came would render here and nowhere else — including in the
/// web app reading the same file. The conversion keeps full resolution.
enum ImagePreparation {

    // MARK: - Errors

    enum Failure: LocalizedError {
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unreadable: return "That file isn't an image or video this app can read."
            }
        }
    }

    // MARK: - Prepared

    /// A picture as it will be stored in Drive.
    struct Prepared: Equatable {
        let data: Data
        /// What the bytes actually are, for the Drive file's metadata and the library's `kind`.
        let mimeType: String
        /// The matching extension, so the stored file is named for what it holds.
        let fileExtension: String
        /// The plaintext preview to send as `thumbnail_b64`; nil for anything no preview could be
        /// made from, which is every video until this app can decode a frame from one.
        let thumbnailBase64: String?
        /// When the photograph was taken, from its EXIF. Nil when the file carries no such tag.
        let captureDate: Date?
    }

    /// Quality for the HEIC conversion. High enough that the result is visually the original; this
    /// is a format change, not a size reduction.
    static let transcodeQuality: CGFloat = 0.9

    /// Longest edge of the stored preview, in pixels. The web app's `generateThumbnail` uses the
    /// same 512, so a picture uploaded here and one uploaded there are the same size in the grid.
    static let thumbnailMaximumPixels: CGFloat = MediaRendition.thumbnail.maximumPixels ?? 512

    /// JPEG quality for that preview, again the web app's.
    static let thumbnailQuality: CGFloat = MediaRendition.thumbnail.jpegQuality

    // MARK: - Preparing

    /// Reads what `data` is and returns everything the upload needs.
    ///
    /// - Parameter suggestedName: whatever the picker knew the file as. Only its stem is used: the
    ///   extension has to describe what is actually stored, which a HEIC converted to JPEG no
    ///   longer would.
    static func prepare(_ data: Data, suggestedName: String?) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else {
            throw Failure.unreadable
        }

        let captureDate = captureDate(from: source)

        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            guard let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: transcodeQuality) else {
                throw Failure.unreadable
            }
            return Prepared(data: jpeg, mimeType: "image/jpeg", fileExtension: "jpg",
                            thumbnailBase64: thumbnailBase64(from: jpeg), captureDate: captureDate)
        }

        guard type.conforms(to: .image) else { throw Failure.unreadable }
        return Prepared(data: data,
                        mimeType: type.preferredMIMEType ?? "image/*",
                        fileExtension: type.preferredFilenameExtension ?? "img",
                        thumbnailBase64: thumbnailBase64(from: data),
                        captureDate: captureDate)
    }

    /// The same, for bytes that must not be touched and whose type is already known.
    ///
    /// This is the RAW path. ``prepare(_:suggestedName:)`` asks ImageIO what the data is and decides
    /// what to do about it; a DNG written out of the photo library has already been identified by
    /// its `PHAssetResource`, and re-deriving the type from a raw file's headers is a way to get it
    /// wrong — `CGImageSourceGetType` reports the generic `com.adobe.raw-image` for a dozen distinct
    /// camera formats, which has no MIME type and no sensible extension.
    ///
    /// Nothing is converted. A RAW original that came back as a JPEG would not be a RAW original,
    /// and the whole reason to reach past the picker for these bytes is that the picker hands back a
    /// rendering rather than the file the camera wrote.
    static func prepareOriginal(_ data: Data, mimeType: String, fileExtension: String) -> Prepared {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        return Prepared(data: data,
                        mimeType: mimeType,
                        fileExtension: fileExtension,
                        // ImageIO renders a thumbnail from a DNG perfectly well, which is what keeps
                        // a RAW photograph from being a grey box in every grid.
                        thumbnailBase64: thumbnailBase64(from: data),
                        captureDate: source.flatMap(captureDate(from:)))
    }

    /// A file name for an uploaded picture, carrying the extension its bytes actually have.
    ///
    /// - Parameter fallbackDate: used to name a file the picker gave no name for. `PhotosPicker`
    ///   often does exactly that, and "IMG_2026-08-18-142536.jpg" is a name somebody can find again
    ///   in a Drive listing, which a UUID is not.
    static func fileName(from suggestedName: String?, extension ext: String,
                         fallbackDate: Date = Date()) -> String {
        if let suggestedName, !suggestedName.trimmingCharacters(in: .whitespaces).isEmpty {
            let stem: String
            if let dot = suggestedName.lastIndex(of: "."), dot != suggestedName.startIndex {
                stem = String(suggestedName[..<dot])
            } else {
                stem = suggestedName
            }
            return "\(stem).\(ext)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "IMG_\(formatter.string(from: fallbackDate)).\(ext)"
    }

    // MARK: - EXIF

    /// The moment the photograph was taken, from EXIF `DateTimeOriginal` (falling back to
    /// `DateTimeDigitized`).
    ///
    /// EXIF timestamps carry no time zone — they are local wall-clock time as the camera saw it —
    /// so they are read as UTC, which is how the server stores a capture date and how the web app
    /// writes one. Reading them as *device local* instead would shift every imported photograph by
    /// the traveller's offset the moment they changed time zone.
    static func captureDate(from source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return nil
        }
        let raw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
        guard let raw else { return nil }
        return exifFormatter.date(from: raw)
    }

    /// EXIF's own format: "2026:08:18 14:25:36" — colons in the date, and nothing else like it.
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    // MARK: - Thumbnails

    /// A small JPEG of `data`, base64-encoded without a `data:` prefix — what Drive's upload
    /// endpoint takes as `thumbnail_b64`.
    ///
    /// JPEG because `set_cover_thumbnail` records the type as `image/jpeg` whatever is sent, so
    /// anything else would be stored under a lie. Transparency is lost, which is the right trade
    /// for a preview; the stored picture keeps its own format.
    ///
    /// Answers nil rather than throwing — a picture whose preview could not be made is still a
    /// picture worth uploading.
    ///
    /// The rendering itself lives in ``RenditionGenerator``, which is where the other two steps of
    /// the ladder are made; this is the one that has to come out as base64 because it travels as a
    /// multipart *field* rather than as a file.
    static func thumbnailBase64(from data: Data) -> String? {
        RenditionGenerator.jpeg(from: data, rendition: .thumbnail)?.base64EncodedString()
    }
}
