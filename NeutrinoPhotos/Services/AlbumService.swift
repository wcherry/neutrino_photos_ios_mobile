import Foundation
import os.log

// MARK: - AlbumService

/// Albums, from `/api/v1/albums`.
///
/// Everything the server offers is here — list, create, rename, delete, add a photo, remove a
/// photo. What is *not* here is opening one: there is no endpoint that returns an album's items,
/// only its count, so the Albums tab shows cards and adds to them rather than browsing into them.
/// ``photos(in:)`` marks the seam where that goes.
@MainActor
final class AlbumService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var albums: [Album] = []
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Dependencies

    private let api: APIClient

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "AlbumService")

    private var decoder: JSONDecoder { PhotoLibraryService.decoder }

    // MARK: - Init

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let response: APIListAlbumsResponse = try await api.get("/api/v1/albums", decoder: decoder)
            // Auto albums last: a person's generated album is a by-product, and the ones the user
            // made are what they came to the tab for.
            albums = response.albums.sorted { lhs, rhs in
                if lhs.isAuto != rhs.isAuto { return !lhs.isAuto }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            logger.debug("load succeeded: \(response.albums.count) albums")
        } catch {
            logger.error("load failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Mutations

    @discardableResult
    func create(title: String, description: String? = nil) async throws -> Album {
        let body = APICreateAlbumRequest(title: title, description: description)
        let album: Album = try await api.post("/api/v1/albums", body: body, decoder: decoder)
        albums.insert(album, at: 0)
        logger.debug("create succeeded: id=\(album.id, privacy: .public)")
        return album
    }

    func rename(id: String, to title: String) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let previous = albums[index]
        albums[index].title = title

        Task {
            do {
                let updated: Album = try await api.patch("/api/v1/albums/\(id)",
                                                         body: APIUpdateAlbumRequest(title: title,
                                                                                     description: nil),
                                                         decoder: decoder)
                if let index = albums.firstIndex(where: { $0.id == id }) { albums[index] = updated }
            } catch {
                logger.error("rename failed: \(error, privacy: .public)")
                if let index = albums.firstIndex(where: { $0.id == id }) { albums[index] = previous }
                self.error = error.localizedDescription
            }
        }
    }

    func delete(id: String) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let removed = albums.remove(at: index)

        Task {
            do {
                _ = try await api.send(method: "DELETE", path: "/api/v1/albums/\(id)")
                logger.debug("delete succeeded: id=\(id, privacy: .public)")
            } catch {
                logger.error("delete failed: \(error, privacy: .public)")
                albums.insert(removed, at: min(index, albums.count))
                self.error = error.localizedDescription
            }
        }
    }

    /// Adds one photograph to an album.
    ///
    /// The count is bumped locally on success rather than optimistically: an album's photo count is
    /// the only thing its card says, and showing it climb for an add the server then rejected would
    /// be the one visible lie on the screen.
    func add(photoID: String, to albumID: String) async throws {
        _ = try await api.send(method: "POST", path: "/api/v1/albums/\(albumID)/items",
                               json: APIAddPhotoRequest(photoId: photoID))
        if let index = albums.firstIndex(where: { $0.id == albumID }) {
            albums[index].photoCount += 1
        }
        logger.debug("add succeeded: album=\(albumID, privacy: .public)")
    }

    func remove(photoID: String, from albumID: String) async throws {
        _ = try await api.send(method: "DELETE", path: "/api/v1/albums/\(albumID)/items/\(photoID)")
        if let index = albums.firstIndex(where: { $0.id == albumID }) {
            albums[index].photoCount = max(0, albums[index].photoCount - 1)
        }
        logger.debug("remove succeeded: album=\(albumID, privacy: .public)")
    }

    // MARK: - Not yet available

    /// The photographs in an album.
    ///
    /// Always empty for now: the server has no `GET /api/v1/albums/{id}/items`. Kept as the one
    /// place that will change when it does, rather than leaving callers to discover the gap.
    func photos(in albumID: String) async throws -> [MediaItem] { [] }
}

// MARK: - API Models

private struct APIListAlbumsResponse: Decodable {
    let albums: [Album]
}

private struct APICreateAlbumRequest: Encodable {
    let title: String
    let description: String?
}

private struct APIUpdateAlbumRequest: Encodable {
    let title: String?
    let description: String?
}

private struct APIAddPhotoRequest: Encodable {
    let photoId: String
}
