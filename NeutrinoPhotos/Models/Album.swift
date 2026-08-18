import Foundation

// MARK: - Album

/// A user-made or automatically generated album, as `GET /api/v1/albums` describes it.
///
/// The server has no endpoint that lists an album's *contents* — only its photo count — so this app
/// can create albums, name them, and add or remove photographs, but cannot yet open one. That is a
/// gap in the API rather than in the app; `AlbumService.photos(in:)` is where it will go when
/// `GET /api/v1/albums/{id}/items` exists.
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
    let createdAt: Date
    var updatedAt: Date

    // MARK: - Computed

    var subtitle: String {
        photoCount == 1 ? "1 photo" : "\(photoCount) photos"
    }

    var symbolName: String { isAuto ? "wand.and.stars" : "rectangle.stack" }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case id, title, description, isAuto, personId, photoCount, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isAuto = try container.decode(Bool.self, forKey: .isAuto)
        personID = try container.decodeIfPresent(String.self, forKey: .personId)
        photoCount = try container.decode(Int.self, forKey: .photoCount)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    init(id: String, title: String, description: String? = nil, isAuto: Bool = false,
         personID: String? = nil, photoCount: Int = 0, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.description = description
        self.isAuto = isAuto
        self.personID = personID
        self.photoCount = photoCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
