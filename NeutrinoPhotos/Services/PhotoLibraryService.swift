import Foundation
import os.log

// MARK: - PhotoLibraryService

/// The library itself: what is in it, and the small set of facts the app can change about an item.
///
/// Backed by Neutrino's Photos API (`/api/v1/photos`) rather than by raw Drive listings. Drive
/// holds the bytes and can list image files, but only the photo record carries what a library is
/// actually organised by — the capture date, the favorite and archived flags, and the id that
/// albums, faces, and edits all address. A picture uploaded straight into Drive by another app is
/// therefore not in the library until something registers it, which is correct: an image attached
/// to a document is not a photograph in somebody's timeline.
///
/// Mutations are optimistic — the local model changes first and is rolled back if the server
/// refuses — because a favourite that waits for a round trip feels broken on a phone.
@MainActor
final class PhotoLibraryService: ObservableObject {

    // MARK: - Published State

    /// Every live item, archived ones included. Filtering for the timeline happens in
    /// ``timeline(showingArchived:)`` so toggling the setting does not need a refetch.
    @Published private(set) var allItems: [MediaItem] = []

    /// `GET /api/v1/photos/trash` — Recently Deleted.
    @Published private(set) var trashItems: [MediaItem] = []

    @Published var isLoading = false
    @Published var error: String?

    /// When the library was last read from the server, for the timeline's status line.
    @Published private(set) var lastLoadedAt: Date?

    // MARK: - Dependencies

    private let api: APIClient

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "PhotoLibraryService")

    /// No key-decoding strategy: the Photos endpoints already serialize camelCase
    /// (`#[serde(rename_all = "camelCase")]`). Timestamps arrive as RFC 3339 from `to_rfc3339()`,
    /// which `DriveDate` reads alongside Drive's zone-less shape.
    static let decoder: JSONDecoder = {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                            category: "PhotoLibraryService")
        return DriveDate.makeDecoder { raw in
            logger.error("date decode failed: unexpected value=\(raw, privacy: .public)")
        }
    }()

    // MARK: - Init

    init(api: APIClient) {
        self.api = api
    }

    #if DEBUG
    /// Seeds state for unit tests and previews.
    convenience init(api: APIClient, items: [MediaItem], trash: [MediaItem] = []) {
        self.init(api: api)
        self.allItems = items
        self.trashItems = trash
    }
    #endif

    // MARK: - Queries

    /// The items the timeline should show, newest first.
    func timeline(showingArchived: Bool) -> [MediaItem] {
        allItems
            .filter { showingArchived || !$0.isArchived }
            .sorted { $0.timelineDate > $1.timelineDate }
    }

    /// Favorites, newest first. The flag lives on the photo record, exactly as it does for the web
    /// app, rather than in a list of its own.
    var favorites: [MediaItem] {
        allItems.filter { $0.isStarred }.sorted { $0.timelineDate > $1.timelineDate }
    }

    var archived: [MediaItem] {
        allItems.filter { $0.isArchived }.sorted { $0.timelineDate > $1.timelineDate }
    }

    func item(id: String) -> MediaItem? {
        allItems.first { $0.id == id } ?? trashItems.first { $0.id == id }
    }

    /// Whether this Drive file has already been registered as a photo — the check that keeps a
    /// second import of the same camera roll from doubling the library.
    func containsFile(id fileID: String) -> Bool {
        allItems.contains { $0.fileID == fileID } || trashItems.contains { $0.fileID == fileID }
    }

    // MARK: - Loading

    /// Loads the whole library, archived items included.
    ///
    /// Note the query parameter's name. `archivedOnly=true` reads, in the handler, as
    /// `include_archived` — it *adds* archived photographs to the listing rather than restricting
    /// it to them (`list_photos` in `src/photos/photos/repository.rs`). Everything is fetched once
    /// and filtered on the device, so the Archive view and the Show Archived setting are both free.
    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let response: APIListPhotosResponse =
                try await api.get("/api/v1/photos?archivedOnly=true", decoder: Self.decoder)
            allItems = response.photos
            lastLoadedAt = Date()
            logger.debug("load succeeded: \(response.photos.count) items")
        } catch {
            logger.error("load failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func loadTrash() async {
        do {
            let response: APIListPhotosResponse =
                try await api.get("/api/v1/photos/trash", decoder: Self.decoder)
            trashItems = response.photos
            logger.debug("loadTrash succeeded: \(response.photos.count) items")
        } catch {
            logger.error("loadTrash failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Registration

    /// Registers an already-uploaded Drive file as a photo, which is what puts it in the library.
    ///
    /// - Parameter captureDate: when the picture was taken, read from its EXIF. Sent in the
    ///   server's zone-less `%Y-%m-%dT%H:%M:%S` shape — see ``DriveDate/naiveUTCString(from:)`` —
    ///   because anything else fails to parse there and the photo silently files itself under its
    ///   upload time instead.
    @discardableResult
    func register(fileID: String, captureDate: Date?) async throws -> MediaItem {
        let body = APIRegisterPhotoRequest(
            fileId: fileID,
            captureDate: captureDate.map(DriveDate.naiveUTCString(from:))
        )
        let item: MediaItem = try await api.post("/api/v1/photos", body: body, decoder: Self.decoder)
        // Inserted at the front rather than appended: the timeline sorts by date anyway, but a
        // caller reading `allItems` before that sort expects the newest first.
        allItems.insert(item, at: 0)
        logger.debug("register succeeded: id=\(item.id, privacy: .public)")
        return item
    }

    // MARK: - Favorites / Archive

    func setStarred(id: String, isStarred: Bool) {
        update(id: id, apply: { $0.isStarred = isStarred },
               body: APIUpdatePhotoRequest(isStarred: isStarred, isArchived: nil))
    }

    func setArchived(id: String, isArchived: Bool) {
        update(id: id, apply: { $0.isArchived = isArchived },
               body: APIUpdatePhotoRequest(isStarred: nil, isArchived: isArchived))
    }

    /// Applies a change locally, sends it, and puts the old value back if the server refuses.
    private func update(id: String, apply: @escaping (inout MediaItem) -> Void,
                        body: APIUpdatePhotoRequest) {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return }
        let previous = allItems[index]
        apply(&allItems[index])

        Task {
            do {
                let updated: MediaItem = try await api.patch("/api/v1/photos/\(id)", body: body,
                                                             decoder: Self.decoder)
                if let index = allItems.firstIndex(where: { $0.id == id }) {
                    allItems[index] = updated
                }
            } catch {
                logger.error("update failed: id=\(id, privacy: .public) \(error, privacy: .public)")
                if let index = allItems.firstIndex(where: { $0.id == id }) {
                    allItems[index] = previous
                }
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Trash

    /// Moves an item to Recently Deleted. The Drive file is left alone — the server only stamps
    /// `deleted_at` on the photo record — so a restore is a flag change rather than an undelete.
    func trash(id: String) {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return }
        let item = allItems.remove(at: index)
        trashItems.insert(item, at: 0)

        Task {
            do {
                _ = try await api.send(method: "DELETE", path: "/api/v1/photos/\(id)")
                logger.debug("trash succeeded: id=\(id, privacy: .public)")
            } catch {
                logger.error("trash failed: id=\(id, privacy: .public) \(error, privacy: .public)")
                trashItems.removeAll { $0.id == id }
                allItems.append(item)
                self.error = error.localizedDescription
            }
        }
    }

    func restore(id: String) {
        guard let index = trashItems.firstIndex(where: { $0.id == id }) else { return }
        let item = trashItems.remove(at: index)
        allItems.insert(item, at: 0)

        Task {
            do {
                let restored: MediaItem = try await api.post("/api/v1/photos/\(id)/restore",
                                                             decoder: Self.decoder)
                if let index = allItems.firstIndex(where: { $0.id == id }) {
                    allItems[index] = restored
                }
                logger.debug("restore succeeded: id=\(id, privacy: .public)")
            } catch {
                logger.error("restore failed: id=\(id, privacy: .public) \(error, privacy: .public)")
                allItems.removeAll { $0.id == id }
                trashItems.append(item)
                self.error = error.localizedDescription
            }
        }
    }

    func emptyTrash() {
        let snapshot = trashItems
        trashItems = []
        Task {
            do {
                _ = try await api.send(method: "DELETE", path: "/api/v1/photos/trash")
                logger.debug("emptyTrash succeeded")
            } catch {
                logger.error("emptyTrash failed: \(error, privacy: .public)")
                trashItems = snapshot
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - API Models

private struct APIListPhotosResponse: Decodable {
    let photos: [MediaItem]
    let total: Int
}

private struct APIRegisterPhotoRequest: Encodable {
    let fileId: String
    let captureDate: String?
}

private struct APIUpdatePhotoRequest: Encodable {
    let isStarred: Bool?
    let isArchived: Bool?
}
