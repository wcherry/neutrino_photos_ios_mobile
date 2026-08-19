import Foundation

// MARK: - MediaItem

/// One photograph or video in the library, as `GET /api/v1/photos` describes it.
///
/// ## Two identifiers, on purpose
///
/// `id` is the *photo record* — what the library, albums, faces, and edits endpoints address.
/// `fileID` is the *Drive file* that holds the bytes — what the download and key endpoints address.
/// They are different rows on the server and are deliberately not collapsed here: a Drive file can
/// exist without ever being registered as a photo (an image attached to a document, say), and the
/// photo record survives metadata the file does not carry, such as the capture date and the
/// archived flag.
struct MediaItem: Identifiable, Hashable {

    // MARK: - Kind

    /// What the item is, decided from its MIME type — the only classification the server gives.
    enum Kind: String {
        case photo
        case video
        case other

        /// SF Symbol shown when there is no thumbnail to draw.
        var placeholderSymbol: String {
            switch self {
            case .photo: return "photo"
            case .video: return "video"
            case .other: return "doc"
            }
        }
    }

    // MARK: - Properties

    /// The photo record's id.
    let id: String
    /// The Drive file holding the (encrypted) original.
    let fileID: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int64
    /// Drive's plaintext cover thumbnail, base64 without a `data:` prefix. Nil until the server's
    /// thumbnail job has run, or when the uploading client sent none.
    let thumbnailBase64: String?
    let thumbnailMIMEType: String?
    var isStarred: Bool
    var isArchived: Bool
    /// When the picture was taken, where that is known — from EXIF at upload time. Nil for an item
    /// whose uploader never supplied one.
    let captureDate: Date?
    let createdAt: Date
    var updatedAt: Date
    /// Dimensions and EXIF, extracted server-side. Nil until the metadata worker has run.
    let metadata: MediaMetadata?

    // MARK: - Computed

    var kind: Kind {
        if mimeType.hasPrefix("image/") { return .photo }
        if mimeType.hasPrefix("video/") { return .video }
        return .other
    }

    /// The moment the timeline files this item under: when it was taken, falling back to when it
    /// reached the server. Every grouping and sort in the app goes through this one property so a
    /// photo cannot appear under one date in the timeline and another in a section header.
    var timelineDate: Date { captureDate ?? createdAt }

    /// The decoded cover thumbnail, or nil when there is none to decode.
    var thumbnailData: Data? {
        guard let thumbnailBase64 else { return nil }
        return Data(base64Encoded: thumbnailBase64)
    }

    /// The file name without its extension — what the viewer shows as a title.
    var displayName: String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }

    /// "4.2 MB".
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// "4032 × 3024", when the metadata worker has been round.
    var formattedDimensions: String? {
        guard let width = metadata?.width, let height = metadata?.height else { return nil }
        return "\(width) × \(height)"
    }

    // MARK: - Init

    init(id: String, fileID: String, fileName: String, mimeType: String, sizeBytes: Int64,
         thumbnailBase64: String? = nil, thumbnailMIMEType: String? = nil,
         isStarred: Bool = false, isArchived: Bool = false, captureDate: Date? = nil,
         createdAt: Date, updatedAt: Date, metadata: MediaMetadata? = nil) {
        self.id = id
        self.fileID = fileID
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.thumbnailBase64 = thumbnailBase64
        self.thumbnailMIMEType = thumbnailMIMEType
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.captureDate = captureDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

// MARK: - MediaMetadata

/// Dimensions and EXIF, as the server's metadata worker stores them.
///
/// Every field is optional because the whole object is: it is written by a background job after the
/// upload, so a photograph imported a second ago has none of it. The viewer's info panel shows what
/// is there and omits what is not, rather than waiting for a complete set.
///
/// `Encodable` as well as `Decodable` only so ``LocalStore`` can keep it in a column. The property
/// names *are* the wire names — the Photos endpoints serialize camelCase — so the encoded shape is
/// the shape it arrived in, and a row written by one version decodes in the next.
struct MediaMetadata: Hashable, Codable {
    let width: Int?
    let height: Int?
    let format: String?
    let exif: MediaExif?
}

// MARK: - MediaExif

struct MediaExif: Hashable, Codable {
    let make: String?
    let model: String?
    let exposureTime: String?
    let fNumber: Double?
    let iso: Int?
    let focalLength: Double?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
    let datetimeOriginal: String?

    /// True when the photograph carries a location — what the Places view will key off, and what
    /// the info panel offers to strip.
    var hasLocation: Bool { gpsLatitude != nil && gpsLongitude != nil }

    /// "ƒ2.8 · 1/120s · ISO 200", built from whatever of the three is present.
    var exposureSummary: String? {
        var parts: [String] = []
        if let fNumber { parts.append(String(format: "ƒ%.1f", fNumber)) }
        if let exposureTime { parts.append(exposureTime) }
        if let iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Decoding

extension MediaItem: Decodable {

    /// The Photos endpoints serialize with serde's `rename_all = "camelCase"`, so these names are
    /// the wire names and no key strategy is applied — see `PhotoLibraryService.decoder`.
    private enum CodingKeys: String, CodingKey {
        case id, fileId, fileName, mimeType, sizeBytes, thumbnail, thumbnailMimeType
        case isStarred, isArchived, captureDate, createdAt, updatedAt, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileID = try container.decode(String.self, forKey: .fileId)
        fileName = try container.decode(String.self, forKey: .fileName)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        thumbnailBase64 = try container.decodeIfPresent(String.self, forKey: .thumbnail)
        thumbnailMIMEType = try container.decodeIfPresent(String.self, forKey: .thumbnailMimeType)
        isStarred = try container.decode(Bool.self, forKey: .isStarred)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        captureDate = try container.decodeIfPresent(Date.self, forKey: .captureDate)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        metadata = try container.decodeIfPresent(MediaMetadata.self, forKey: .metadata)
    }
}
