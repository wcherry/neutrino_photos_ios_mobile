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
    /// Where the grid's picture is fetched from — a relative path such as
    /// `/api/v1/drive/files/<id>/thumbnail?v=<updatedAt millis>` — or nil when the item has no
    /// thumbnail at all: a video, or a file whose uploader sent none.
    ///
    /// A URL rather than base64 bytes since issue #175, which moved the thumbnail out of the Drive
    /// row and out of every listing that quoted it. The `v` is a cache token that moves when the
    /// thumbnail does, and the request carries the account's bearer token like any other read —
    /// see ``ThumbnailCache``, which is the only thing that should be dereferencing this.
    let thumbnailURL: String?
    var isStarred: Bool
    var isArchived: Bool
    /// When the picture was taken, where that is known — from EXIF at upload time. Nil for an item
    /// whose uploader never supplied one.
    let captureDate: Date?
    let createdAt: Date
    var updatedAt: Date
    /// When the item was moved to Recently Deleted, or nil while it is live.
    ///
    /// `var` because a restore clears it and a delete sets it, and both happen optimistically on the
    /// device before the server has answered — see ``PhotoLibraryService``. It is what
    /// ``TrashRetention`` counts from, so an item whose server copy predates this field simply shows
    /// no countdown rather than a wrong one.
    var deletedAt: Date?
    /// Dimensions, EXIF, and what the device library knew — see ``MediaMetadata``. `var` because
    /// this app writes it: an end-to-end encrypted upload is one the server cannot read, so the
    /// importing device is the only thing that can extract it, and it attaches it to the record it
    /// has just registered.
    var metadata: MediaMetadata?

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

    /// The file name without its extension — what the viewer shows as a title.
    var displayName: String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }

    /// "4.2 MB".
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// "4032 × 3024", once something has extracted it.
    var formattedDimensions: String? {
        guard let width = metadata?.width, let height = metadata?.height else { return nil }
        return "\(width) × \(height)"
    }

    /// A photograph with motion beside it, imported from the device library.
    ///
    /// Stored rather than rendered: the paired video is uploaded and its Drive file id travels in
    /// ``MediaDeviceFacts/liveVideoFileID``, so it can be saved back to Apple Photos as a Live Photo
    /// today and played in place when v1.1 gets round to it.
    var isLivePhoto: Bool { metadata?.device?.isLivePhoto == true }

    /// A camera original the device wrote as RAW — a DNG, in practice. Uploaded untranscoded.
    var isRAW: Bool { metadata?.device?.isRAW == true }

    /// The paired video's Drive file, for a Live Photo whose motion this account holds.
    var liveVideoFileID: String? { metadata?.device?.liveVideoFileID }

    // MARK: - Init

    init(id: String, fileID: String, fileName: String, mimeType: String, sizeBytes: Int64,
         thumbnailURL: String? = nil,
         isStarred: Bool = false, isArchived: Bool = false, captureDate: Date? = nil,
         createdAt: Date, updatedAt: Date, deletedAt: Date? = nil,
         metadata: MediaMetadata? = nil) {
        self.id = id
        self.fileID = fileID
        self.fileName = fileName
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.thumbnailURL = thumbnailURL
        self.isStarred = isStarred
        self.isArchived = isArchived
        self.captureDate = captureDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.metadata = metadata
    }
}

// MARK: - TrashRetention

/// How long a deleted item stays in Recently Deleted before it is gone.
///
/// One type rather than a `30` written into each of the four places that mention it — the bulk
/// delete confirmation, the viewer's delete, the trash view's countdown, and the empty-trash
/// warning — because a promise the app makes in four voices is one that eventually disagrees with
/// itself.
///
/// **This number is half of a pair.** The server sweeps expired trash on the same window —
/// `PhotosService::TRASH_RETENTION_DAYS` in the `neutrino` repository, run hourly from `main` — and
/// that sweep is what makes the countdown a fact rather than a statement of policy. The two
/// constants are not shared by any mechanism, so changing one without the other makes the app count
/// down to a moment nothing happens at, or purge photographs it promised to keep. Change both.
enum TrashRetention {

    /// The window the app promises, in days. Must match the server's `TRASH_RETENTION_DAYS`.
    static let days = 30

    /// Days left before `item` is due to be purged, or nil when it is not in the trash or arrived
    /// from a server too old to say when it was deleted.
    ///
    /// Clamped at zero rather than going negative: "0 days left" is a thing to show a user and
    /// "-3 days left" is a bug report.
    static func daysRemaining(for item: MediaItem,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> Int? {
        guard let deletedAt = item.deletedAt else { return nil }
        guard let due = calendar.date(byAdding: .day, value: days, to: deletedAt) else { return nil }
        // Counted between the *start of each day* rather than between the two instants, so an item
        // deleted at 11pm does not report a day fewer than one deleted the same morning.
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: due)
        let remaining = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return max(0, remaining)
    }

    /// "29 days left", "1 day left", "Deleting soon" — what a trashed cell captions itself with.
    static func caption(for item: MediaItem,
                        now: Date = Date(),
                        calendar: Calendar = .current) -> String? {
        guard let remaining = daysRemaining(for: item, now: now, calendar: calendar) else {
            return nil
        }
        switch remaining {
        case 0:  return "Deleting soon"
        case 1:  return "1 day left"
        default: return "\(remaining) days left"
        }
    }
}

// MARK: - MediaMetadata

/// Dimensions, EXIF, and what the device library knew — everything about an item that is not its
/// pixels.
///
/// ## Who writes this
///
/// For a picture uploaded in the clear, the server's metadata worker: it can open the file, so it
/// reads the dimensions and EXIF itself. For anything this app uploads, **nobody can but this app** —
/// the bytes reaching the server are ciphertext and the key never leaves the device. So
/// ``MediaMetadataExtractor`` reads it here at import and
/// ``PhotoLibraryService/setMetadata(_:forPhoto:publishingLocation:)`` attaches it to the record,
/// locally always and on the server as far as the user has agreed to.
///
/// Every field is optional because the whole object is: a photograph whose metadata has not been
/// written yet has none of it, and the viewer's info panel shows what is there rather than a column
/// of blanks.
///
/// `Encodable` as well as `Decodable` because both ``LocalStore`` and `PUT /photos/{id}/metadata`
/// take it. The property names *are* the wire names — the Photos endpoints serialize camelCase — so
/// the encoded shape is the shape it arrived in, and a row written by one version decodes in the
/// next. That also means **new fields must be optional**: a device still on the old build has to be
/// able to read a record a newer one wrote.
struct MediaMetadata: Hashable, Codable {
    let width: Int?
    let height: Int?
    let format: String?
    let exif: MediaExif?
    /// What the device's photo library knew and the pixels do not say. Absent for anything the
    /// server extracted, and for an import made without photo-library access.
    var device: MediaDeviceFacts?

    init(width: Int? = nil, height: Int? = nil, format: String? = nil,
         exif: MediaExif? = nil, device: MediaDeviceFacts? = nil) {
        self.width = width
        self.height = height
        self.format = format
        self.exif = exif
        self.device = device
    }
}

// MARK: - MediaDeviceFacts

/// The facts about an item that only the device that imported it could know.
///
/// A `PHAsset` carries things no image file does — whether it was favourited in Apple Photos,
/// whether it is a Live Photo, which burst it belongs to — and an encrypted upload gives the server
/// no way to find any of it out. So the importing device records them here.
///
/// `localIdentifier` is a UUID meaningless on any other device; it is published anyway because it is
/// half of Epic 6's duplicate rule ("content hash plus `PHAsset.localIdentifier`"), and a second
/// device asking "have I already got this one?" needs to be able to read it.
struct MediaDeviceFacts: Hashable, Codable {
    /// The `PHAsset.localIdentifier` this came from.
    let localIdentifier: String?
    let isLivePhoto: Bool?
    let isRAW: Bool?
    /// `PHAssetMediaSubtype` names — "panorama", "screenshot", "hdr", "portrait", "slowMotion",
    /// "timelapse". Strings rather than a bitmask so a subtype added by a future iOS survives a
    /// round trip through a build that has never heard of it.
    let subtypes: [String]?
    /// The Drive file holding a Live Photo's paired video, when its motion was preserved.
    var liveVideoFileID: String?

    init(localIdentifier: String? = nil, isLivePhoto: Bool? = nil, isRAW: Bool? = nil,
         subtypes: [String]? = nil, liveVideoFileID: String? = nil) {
        self.localIdentifier = localIdentifier
        self.isLivePhoto = isLivePhoto
        self.isRAW = isRAW
        self.subtypes = subtypes
        self.liveVideoFileID = liveVideoFileID
    }
}

// MARK: - MediaExif

struct MediaExif: Hashable, Codable {
    let make: String?
    let model: String?
    /// "iPhone 15 Pro back triple camera 6.765mm f/1.78" — EXIF's `LensModel`. Written by this app;
    /// the server's worker does not extract it, so it is absent on anything uploaded in the clear.
    var lensModel: String?
    let exposureTime: String?
    let fNumber: Double?
    let iso: Int?
    let focalLength: Double?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
    let datetimeOriginal: String?

    init(make: String? = nil, model: String? = nil, lensModel: String? = nil,
         exposureTime: String? = nil, fNumber: Double? = nil, iso: Int? = nil,
         focalLength: Double? = nil, gpsLatitude: Double? = nil, gpsLongitude: Double? = nil,
         datetimeOriginal: String? = nil) {
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.exposureTime = exposureTime
        self.fNumber = fNumber
        self.iso = iso
        self.focalLength = focalLength
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.datetimeOriginal = datetimeOriginal
    }

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

    /// True when there is anything here worth showing — so a record that extracted nothing can be
    /// dropped rather than stored and published as a row of nulls.
    var isEmpty: Bool {
        make == nil && model == nil && lensModel == nil && exposureTime == nil && fNumber == nil
            && iso == nil && focalLength == nil && datetimeOriginal == nil && !hasLocation
    }

    /// The same record with its coordinates removed.
    var withoutLocation: MediaExif {
        MediaExif(make: make, model: model, lensModel: lensModel, exposureTime: exposureTime,
                  fNumber: fNumber, iso: iso, focalLength: focalLength,
                  gpsLatitude: nil, gpsLongitude: nil, datetimeOriginal: datetimeOriginal)
    }
}

// MARK: - Redaction

extension MediaMetadata {

    /// The same record with the coordinates removed — what leaves the device when the user has not
    /// opted into publishing location.
    ///
    /// Everything else still goes: dimensions, camera, exposure. Location is singled out because it
    /// is the one field that says where somebody *was*, and because it is the one the server has a
    /// use for — `GET /api/v1/photos/map` reads exactly these two keys. Publishing it is therefore a
    /// real trade rather than a formality: it is what will make Places work, and it is plaintext on
    /// a server that can read nothing else about the picture.
    var withoutLocation: MediaMetadata {
        MediaMetadata(width: width, height: height, format: format,
                      exif: exif?.withoutLocation, device: device)
    }

    /// True when nothing was extracted, so there is no reason to write or send it.
    var isEmpty: Bool {
        width == nil && height == nil && format == nil && (exif?.isEmpty ?? true) && device == nil
    }

    /// This record as the server sent it, with anything only *this device* holds folded back in.
    ///
    /// There is exactly one way for the two to differ and it is by design: coordinates are held
    /// locally and published only if the user opted in (see
    /// ``AppSettings/publishesLocationMetadata``), so a listing that has been round the server comes
    /// back without them. Overwriting the local record with it would mean the info panel showed a
    /// location until the next refresh and then quietly stopped.
    ///
    /// Nothing else is merged the other way. The server's copy wins for everything it carries,
    /// because it is the one another device may have updated.
    func mergingDeviceOnlyFacts(from local: MediaMetadata?) -> MediaMetadata {
        guard let local else { return self }

        var exif = self.exif
        if exif?.hasLocation != true, let localExif = local.exif, localExif.hasLocation {
            exif = MediaExif(make: exif?.make ?? localExif.make,
                             model: exif?.model ?? localExif.model,
                             lensModel: exif?.lensModel ?? localExif.lensModel,
                             exposureTime: exif?.exposureTime ?? localExif.exposureTime,
                             fNumber: exif?.fNumber ?? localExif.fNumber,
                             iso: exif?.iso ?? localExif.iso,
                             focalLength: exif?.focalLength ?? localExif.focalLength,
                             gpsLatitude: localExif.gpsLatitude,
                             gpsLongitude: localExif.gpsLongitude,
                             datetimeOriginal: exif?.datetimeOriginal ?? localExif.datetimeOriginal)
        }
        return MediaMetadata(width: width ?? local.width, height: height ?? local.height,
                             format: format ?? local.format, exif: exif,
                             device: device ?? local.device)
    }
}

// MARK: - Decoding

extension MediaItem: Decodable {

    /// The Photos endpoints serialize with serde's `rename_all = "camelCase"`, so these names are
    /// the wire names and no key strategy is applied — see `PhotoLibraryService.decoder`.
    private enum CodingKeys: String, CodingKey {
        case id, fileId, fileName, mimeType, sizeBytes, thumbnailUrl
        case isStarred, isArchived, captureDate, createdAt, updatedAt, deletedAt, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileID = try container.decode(String.self, forKey: .fileId)
        fileName = try container.decode(String.self, forKey: .fileName)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        isStarred = try container.decode(Bool.self, forKey: .isStarred)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        captureDate = try container.decodeIfPresent(Date.self, forKey: .captureDate)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        metadata = try container.decodeIfPresent(MediaMetadata.self, forKey: .metadata)
    }
}
