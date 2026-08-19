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
    @Published private(set) var allItems: [MediaItem] = [] {
        didSet { revision &+= 1 }
    }

    /// Bumped every time ``allItems`` changes, in any way.
    ///
    /// This exists so a view can tell "the library is the one I last looked at" without comparing
    /// the array, which is the expensive question: `[MediaItem] == [MediaItem]` over a full library
    /// walks every element and, worse, every element's base64 cover thumbnail. ``TimelineCache``
    /// keys its grouping on this integer instead, which is what keeps a body pass during a scroll
    /// or a pinch from re-bucketing and re-sorting two thousand photographs.
    ///
    /// Not `@Published`: it changes in lockstep with `allItems`, which already publishes, and a
    /// second announcement of the same change would just be a second render.
    private(set) var revision: Int = 0

    /// `GET /api/v1/photos/trash` — Recently Deleted.
    @Published private(set) var trashItems: [MediaItem] = []

    @Published var isLoading = false
    @Published var error: String?

    /// When the library was last read from the server, for the timeline's status line.
    @Published private(set) var lastLoadedAt: Date?

    /// True once the timeline has been painted from the device's own copy — so a caller can tell
    /// "there is nothing in this library" from "nothing has been read yet", which are the same
    /// empty grid and very different empty states.
    @Published private(set) var isHydrated = false

    // MARK: - Dependencies

    private let api: APIClient

    /// The device's cached copy of the library. Optional: a database that would not open is a
    /// slower app, not a broken one, and every path here treats it as an accelerator rather than as
    /// a source of truth.
    private let store: LocalStore?

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

    init(api: APIClient, store: LocalStore? = nil) {
        self.api = api
        self.store = store
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
        await hydrateIfNeeded()

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let response: APIListPhotosResponse =
                try await api.get("/api/v1/photos?archivedOnly=true", decoder: Self.decoder)
            allItems = response.photos
            lastLoadedAt = Date()
            logger.debug("load succeeded: \(response.photos.count) items")
            try? await store?.replaceLibrary(with: response.photos)
        } catch {
            logger.error("load failed: \(error, privacy: .public)")
            // A failed refresh over a library that is already on screen is a stale timeline, not an
            // empty one — the rows stay, and the error says why they are not newer. Reporting
            // nothing at all would be worse: the user would be looking at yesterday believing it
            // was today.
            self.error = error.localizedDescription
        }
    }

    func loadTrash() async {
        do {
            let response: APIListPhotosResponse =
                try await api.get("/api/v1/photos/trash", decoder: Self.decoder)
            trashItems = response.photos
            logger.debug("loadTrash succeeded: \(response.photos.count) items")
            try? await store?.replaceTrash(with: response.photos)
        } catch {
            logger.error("loadTrash failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - The device's own copy

    /// Paints the timeline from the local database before the network is asked anything.
    ///
    /// Runs once per launch and only while the library is empty, so a refresh never flickers back
    /// through the cached rows on its way to the new ones. A cold launch on a slow connection shows
    /// photographs immediately instead of a spinner; a cold launch with *no* connection shows them
    /// too, which is as far as this goes — browsing an item, queueing a change, and reconciling
    /// what happened while the phone was away are Epic 10's, and half of an offline mode is worse
    /// than none.
    func hydrateIfNeeded() async {
        guard !isHydrated, allItems.isEmpty, let store else {
            isHydrated = true
            return
        }
        isHydrated = true
        do {
            let cached = try await store.libraryItems()
            guard !cached.isEmpty, allItems.isEmpty else { return }
            allItems = cached
            logger.debug("hydrated \(cached.count) items from the local store")
        } catch {
            logger.error("hydrate failed: \(error, privacy: .public)")
        }
    }

    /// Empties the device's copy — what signing out wants, since the next account's library has
    /// nothing to do with this one's.
    func clearLocalCopy() async {
        allItems = []
        trashItems = []
        isHydrated = false
        try? await store?.clear()
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
        try? await store?.save(item)
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
                try? await store?.save(updated)
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
                try? await store?.save(item, trashed: true)
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
                try? await store?.save(restored, trashed: false)
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
                try? await store?.replaceTrash(with: [])
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
