import Foundation
import os.log

// MARK: - AlbumService

/// Albums, from `/api/v1/albums`.
///
/// List, create, rename, delete, open, add photographs, remove them. Opening an album was the one
/// thing missing until Epic 9 — the server had `album_photos` but no route that read it — and
/// ``photos(in:)`` now goes through `GET /api/v1/albums/{id}/items`, which returns full photo
/// records so an album's grid draws from the same ``MediaItem`` the timeline does.
///
/// ## What is optimistic and what is not
///
/// Renaming and deleting an album change ``albums`` before the server answers and roll back if it
/// refuses: they are instant, reversible, and the user is looking straight at the thing that
/// changed. Adding and removing a photograph do **not** — an album's count is the only number its
/// card shows, and watching it climb for an add the server then rejected is the one visible lie on
/// the screen. Those two `throw` instead, and their callers report it.
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
    /// The count is bumped locally on success rather than optimistically — see the note on the type.
    func add(photoID: String, to albumID: String) async throws {
        _ = try await api.send(method: "POST", path: "/api/v1/albums/\(albumID)/items",
                               json: APIAddPhotoRequest(photoId: photoID))
        note(added: 1, to: albumID, cover: photoID)
        logger.debug("add succeeded: album=\(albumID, privacy: .public)")
    }

    /// Adds many photographs to one album, and reports how it went.
    ///
    /// Serial rather than a `TaskGroup`: the endpoint takes one photo per call, and firing five
    /// hundred of them at once is how a bulk add turns into a rate limit or a thread explosion.
    /// Verification step 9 puts 500 items through here, and what keeps the UI alive is not
    /// concurrency but that this is `async` and the button that called it stays on the main actor.
    ///
    /// **One failure does not stop the rest.** A photograph the server refuses — deleted on another
    /// device between the selection and the tap — is counted and skipped, so the other 499 land.
    /// The count is bumped once at the end from what actually succeeded, so a partial run leaves an
    /// honest number on the card rather than the number the user asked for.
    @discardableResult
    func add(photoIDs: [String], to albumID: String) async -> BulkAddResult {
        var added: [String] = []
        var failures: [String: String] = [:]

        for photoID in photoIDs {
            do {
                _ = try await api.send(method: "POST", path: "/api/v1/albums/\(albumID)/items",
                                       json: APIAddPhotoRequest(photoId: photoID))
                added.append(photoID)
            } catch {
                failures[photoID] = error.localizedDescription
                logger.error("bulk add failed for \(photoID, privacy: .public): \(error, privacy: .public)")
            }
        }

        // `photoIDs` is in timeline order — newest first — so its first element is the newest thing
        // going in, which is the cover the server will independently settle on at the next refresh.
        note(added: added.count, to: albumID, cover: added.first)

        if !failures.isEmpty {
            error = failures.count == 1
                ? "1 photo couldn't be added."
                : "\(failures.count) photos couldn't be added."
        }
        logger.debug("bulk add: \(added.count) added, \(failures.count) failed")
        return BulkAddResult(added: added, failures: failures)
    }

    func remove(photoID: String, from albumID: String) async throws {
        _ = try await api.send(method: "DELETE", path: "/api/v1/albums/\(albumID)/items/\(photoID)")
        if let index = albums.firstIndex(where: { $0.id == albumID }) {
            albums[index].photoCount = max(0, albums[index].photoCount - 1)
            // The cover just left the album. Blanking it rather than guessing the next one keeps the
            // card honest until the next listing says what actually replaced it — the app has no way
            // to know which photograph is now the most recently *added*, only the most recently
            // taken, and the two are not the same.
            if albums[index].coverPhotoID == photoID { albums[index].coverPhotoID = nil }
        }
        logger.debug("remove succeeded: album=\(albumID, privacy: .public)")
    }

    /// Folds a successful add back into the local album record.
    private func note(added count: Int, to albumID: String, cover: String?) {
        guard count > 0, let index = albums.firstIndex(where: { $0.id == albumID }) else { return }
        albums[index].photoCount += count
        // Only when there wasn't one: an album that already has a cover keeps it until the server
        // says otherwise, so adding to an album does not reshuffle the tab under the user's thumb.
        if albums[index].coverPhotoID == nil { albums[index].coverPhotoID = cover }
    }

    // MARK: - Contents

    /// The photographs in an album, most recently added first.
    ///
    /// Not cached here. An album's contents are a screen's worth of state with a natural owner —
    /// the view showing them — and holding them in the service would mean every album ever opened
    /// stayed in memory with its thumbnails for the rest of the launch. ``AlbumDetailView`` loads
    /// this on appear and on pull-to-refresh.
    ///
    /// Trashed photographs are absent: the server filters them out of both the contents and the
    /// count, so the two agree. They keep their membership, so restoring one puts it back in the
    /// album it was in rather than only in the timeline.
    func photos(in albumID: String) async throws -> [MediaItem] {
        let response: APIListPhotosResponse =
            try await api.get("/api/v1/albums/\(albumID)/items", decoder: decoder)
        logger.debug("photos(in:) \(albumID, privacy: .public): \(response.photos.count) items")
        return response.photos
    }
}

// MARK: - BulkAddResult

/// What a bulk add actually managed.
struct BulkAddResult: Equatable {
    /// The photo ids that made it into the album.
    var added: [String] = []
    /// Photo id → why it did not, for the ones that did not.
    var failures: [String: String] = [:]

    var isCompleteSuccess: Bool { failures.isEmpty }
}

// MARK: - API Models

private struct APIListAlbumsResponse: Decodable {
    let albums: [Album]
}

/// The same shape `GET /api/v1/photos` returns — `/albums/{id}/items` answers with a photo listing
/// rather than a membership listing, so an album's grid needs no second round trip to resolve ids.
private struct APIListPhotosResponse: Decodable {
    let photos: [MediaItem]
    let total: Int
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
