import Foundation

// MARK: - Album

/// A user-made or automatically generated album, as `GET /api/v1/albums` describes it.
///
/// ## The cover is an id, not an image
///
/// `coverPhotoID` names the album's most recently added live photograph; the picture itself is not
/// in this response. That is deliberate on both sides: the app already holds every item's cover
/// thumbnail in ``PhotoLibraryService/allItems``, so resolving an id costs nothing, while sending
/// one base64 image per album would put a picture in every row of a list that mostly shows text.
/// ``AlbumsView`` does the lookup, and an album whose cover is not in the local library — added on
/// another device since the last refresh — draws the placeholder rather than nothing.
struct Album: Identifiable, Hashable, Decodable {

    // MARK: - Properties

    let id: String
    var title: String
    var description: String?
    /// True for albums the server generates — a person's smart album, for instance — which are not
    /// the user's to rename or delete.
    let isAuto: Bool
    /// Set on an album generated for a recognised person.
    let personID: String?
    var photoCount: Int
    /// The photo record to draw as this album's cover, or nil when the album is empty.
    var coverPhotoID: String?
    let createdAt: Date
    var updatedAt: Date

    // MARK: - Computed

    var subtitle: String {
        photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    }

    var symbolName: String { isAuto ? "wand.and.stars" : "rectangle.stack" }

    /// An auto album is the server's — regenerated from a person's faces — so it cannot be renamed,
    /// deleted, or added to by hand. One property rather than `!isAuto` repeated at each of those
    /// four call sites.
    var isEditable: Bool { !isAuto }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case id, title, description, isAuto, personId, photoCount, coverPhotoId
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isAuto = try container.decode(Bool.self, forKey: .isAuto)
        personID = try container.decodeIfPresent(String.self, forKey: .personId)
        photoCount = try container.decode(Int.self, forKey: .photoCount)
        coverPhotoID = try container.decodeIfPresent(String.self, forKey: .coverPhotoId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    init(id: String, title: String, description: String? = nil, isAuto: Bool = false,
         personID: String? = nil, photoCount: Int = 0, coverPhotoID: String? = nil,
         createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.description = description
        self.isAuto = isAuto
        self.personID = personID
        self.photoCount = photoCount
        self.coverPhotoID = coverPhotoID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
