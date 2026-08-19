import Foundation

// MARK: - DriveFile

/// A file as Drive describes it, which is not the same thing as a photograph.
///
/// ``MediaItem`` is the *photo record*: capture date, favourite, archived, and the id albums and
/// faces address. This is the row underneath it — the bytes, their name, their size, and the
/// encrypted metadata blob that says how they were framed. Most of the app wants the former; the
/// things that reconcile the two, or that store something which is not a photograph (a preview
/// rendition), want this.
struct DriveFile: Identifiable, Hashable, Decodable {

    let id: String
    let name: String
    let sizeBytes: Int64
    let mimeType: String
    /// Nil for a file in the account's Drive root, which is where every uploaded photograph goes.
    let folderID: String?
    let createdAt: Date
    let updatedAt: Date
    /// The plaintext cover thumbnail, base64 without a `data:` prefix.
    let coverThumbnail: String?
    /// Base64url XChaCha20-Poly1305 ciphertext of `{ name, mimeType, chunkSize? }`. Present only
    /// for E2EE files — and the only place the chunk framing of the content is recorded, which is
    /// what a streaming download has to read before it can decrypt anything.
    let encryptedMetadata: String?

    // MARK: - Computed

    var isImage: Bool { mimeType.hasPrefix("image/") }

    // MARK: - Decoding

    /// Drive serializes camelCase (`#[serde(rename_all = "camelCase")]`), but its decoder in this
    /// app is configured for snake case as well — a camelCase key passes through that strategy
    /// unchanged, so these names work under either.
    private enum CodingKeys: String, CodingKey {
        case id, name, sizeBytes, mimeType, folderId, createdAt, updatedAt
        case coverThumbnail, encryptedMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? "application/octet-stream"
        folderID = try container.decodeIfPresent(String.self, forKey: .folderId)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        coverThumbnail = try container.decodeIfPresent(String.self, forKey: .coverThumbnail)
        encryptedMetadata = try container.decodeIfPresent(String.self, forKey: .encryptedMetadata)
    }

    init(id: String, name: String, sizeBytes: Int64 = 0, mimeType: String = "image/jpeg",
         folderID: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
         coverThumbnail: String? = nil, encryptedMetadata: String? = nil) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.mimeType = mimeType
        self.folderID = folderID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.coverThumbnail = coverThumbnail
        self.encryptedMetadata = encryptedMetadata
    }
}

// MARK: - DriveFolder

struct DriveFolder: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
    let parentID: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, parentId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentId)
    }

    init(id: String, name: String, parentID: String? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

// MARK: - DriveQuota

/// `GET /api/v1/drive/quota`. A nil limit means the account has none, which is not the same as zero
/// and must never be rendered as "0 bytes free".
struct DriveQuota: Hashable, Decodable {
    let usedBytes: Int64
    let quotaBytes: Int64?
    let dailyUploadBytes: Int64
    let dailyCapBytes: Int64?

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
    }

    /// "3.4 GB of 15 GB", or just "3.4 GB" for an unlimited account.
    var formattedUsage: String {
        guard let quotaBytes else { return formattedUsed }
        let total = ByteCountFormatter.string(fromByteCount: quotaBytes, countStyle: .file)
        return "\(formattedUsed) of \(total)"
    }
}
