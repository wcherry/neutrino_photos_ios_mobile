import Foundation
import os.log
import NeutrinoCore

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

    /// What has arrived in the library lately, newest arrival first.
    ///
    /// Ordered and filtered by `createdAt` — when the item reached the account — rather than by
    /// ``MediaItem/timelineDate``, and that is the whole point of the view. The timeline already
    /// answers "what did I take recently"; this answers "what did I just import", which for a
    /// scanned shoebox of 1998 photographs is a completely different set and the only place they
    /// are findable without scrolling to 1998.
    ///
    /// Archived items are excluded: archiving is the user saying "keep this out of the way", and a
    /// second view that shows it anyway would undo that for a month.
    func recentlyAdded(within days: Int = 30, now: Date = Date(),
                       calendar: Calendar = .current) -> [MediaItem] {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        return allItems
            .filter { !$0.isArchived && $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
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
            let merged = mergingDeviceOnlyMetadata(into: response.photos)
            allItems = merged
            lastLoadedAt = Date()
            logger.debug("load succeeded: \(response.photos.count) items")
            try? await store?.replaceLibrary(with: merged)
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

    // MARK: - Metadata

    /// Attaches the metadata this device extracted from a picture to its photo record.
    ///
    /// ## Why the app writes this at all
    ///
    /// The server has a worker that reads dimensions and EXIF off an uploaded file, and for a file
    /// uploaded in the clear that is the right place for it. Nothing this app uploads is in the
    /// clear: what reaches Neutrino is ciphertext and the key never leaves the phone, so an
    /// encrypted photograph's metadata is extractable in exactly one place — the importing device,
    /// while it still has the plaintext. Without this, `metadata` is nil forever for every item this
    /// app has ever imported.
    ///
    /// ## What is sent, and what is not
    ///
    /// Both, always, locally: the full record goes into ``allItems`` and into ``LocalStore``, so the
    /// info panel is complete and offline the moment the import finishes.
    ///
    /// Only the non-locating half leaves the device unless the user has said otherwise —
    /// see ``AppSettings/publishesLocationMetadata``. `PUT /api/v1/photos/{id}/metadata` stores a
    /// plaintext JSON blob, and `GET /api/v1/photos/map` reads exactly the two GPS keys out of it,
    /// so publishing coordinates is what makes Places work *and* is a list of where somebody has
    /// been sitting beside a library the server otherwise cannot open.
    ///
    /// A failure to publish is logged and swallowed. The photograph is uploaded and registered by
    /// the time this runs, the local record is already written, and failing an import over its
    /// index entry would trade the thing that matters for the thing that does not.
    func setMetadata(_ metadata: MediaMetadata, forPhoto id: String,
                     publishingLocation: Bool) async {
        guard !metadata.isEmpty else { return }

        if let index = allItems.firstIndex(where: { $0.id == id }) {
            allItems[index].metadata = metadata
            try? await store?.save(allItems[index])
        }

        let published = publishingLocation ? metadata : metadata.withoutLocation
        do {
            _ = try await api.send(method: "PUT", path: "/api/v1/photos/\(id)/metadata",
                                   json: published)
            logger.debug("metadata published for \(id, privacy: .public) (location=\(publishingLocation))")
        } catch {
            logger.error("metadata publish failed for \(id, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Puts a single server copy of an item back into ``allItems``, keeping the metadata only this
    /// device holds. Answers what was actually stored, or nil if the item has since left the library.
    ///
    /// The case this exists for is narrow and easy to miss. Importing a favourited photograph fires
    /// two writes at once: a `PATCH` setting the star, and a `PUT` attaching the metadata. The
    /// `PATCH` response carries `metadata: null` — the server has not been told yet — so whichever
    /// of the two lands second wins, and half the time that is the one that blanks the record the
    /// other just wrote. Merging rather than assigning makes the order stop mattering.
    @discardableResult
    private func replaceKeepingLocalMetadata(with updated: MediaItem) -> MediaItem? {
        guard let index = allItems.firstIndex(where: { $0.id == updated.id }) else { return nil }
        var updated = updated
        updated.metadata = updated.metadata?.mergingDeviceOnlyFacts(from: allItems[index].metadata)
            ?? allItems[index].metadata
        allItems[index] = updated
        return updated
    }

    /// Folds what only this device knows back into a listing that has been round the server.
    ///
    /// Coordinates held back from publication are the one thing that can be in the local copy and
    /// not in the server's — see ``setMetadata(_:forPhoto:publishingLocation:)``. Without this, a
    /// pull to refresh would blank the location on every photograph the user chose not to publish.
    private func mergingDeviceOnlyMetadata(into incoming: [MediaItem]) -> [MediaItem] {
        guard !allItems.isEmpty else { return incoming }
        let local = Dictionary(allItems.map { ($0.id, $0.metadata) }, uniquingKeysWith: { first, _ in first })
        return incoming.map { item in
            guard let localMetadata = local[item.id] ?? nil else { return item }
            var item = item
            item.metadata = item.metadata?.mergingDeviceOnlyFacts(from: localMetadata)
                ?? localMetadata
            return item
        }
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
                if let merged = replaceKeepingLocalMetadata(with: updated) {
                    try? await store?.save(merged)
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
        var item = allItems.remove(at: index)
        // Stamped here rather than waiting for the server's copy, because `DELETE /photos/{id}`
        // answers 204 with no body — there is nothing to read it back from. The next `loadTrash()`
        // replaces this with the server's timestamp; until then a countdown from the moment the
        // user tapped Delete is right to within a round trip.
        let deletedAt = Date()
        item.deletedAt = deletedAt
        trashItems.insert(item, at: 0)

        Task {
            do {
                _ = try await api.send(method: "DELETE", path: "/api/v1/photos/\(id)")
                try? await store?.save(item, trashed: true)
                logger.debug("trash succeeded: id=\(id, privacy: .public)")
            } catch {
                logger.error("trash failed: id=\(id, privacy: .public) \(error, privacy: .public)")
                trashItems.removeAll { $0.id == id }
                var restored = item
                restored.deletedAt = nil
                allItems.append(restored)
                self.error = error.localizedDescription
            }
        }
    }

    func restore(id: String) {
        guard let index = trashItems.firstIndex(where: { $0.id == id }) else { return }
        let trashed = trashItems.remove(at: index)
        var item = trashed
        // Cleared on the way out, or a restored photograph would sit in the timeline still claiming
        // a date of deletion — and `recentlyAdded` and the trash view would both count it.
        item.deletedAt = nil
        allItems.insert(item, at: 0)

        Task {
            do {
                let restored: MediaItem = try await api.post("/api/v1/photos/\(id)/restore",
                                                             decoder: Self.decoder)
                let merged = replaceKeepingLocalMetadata(with: restored) ?? restored
                try? await store?.save(merged, trashed: false)
                logger.debug("restore succeeded: id=\(id, privacy: .public)")
            } catch {
                logger.error("restore failed: id=\(id, privacy: .public) \(error, privacy: .public)")
                allItems.removeAll { $0.id == id }
                trashItems.append(trashed)
                self.error = error.localizedDescription
            }
        }
    }

    /// Deletes one trashed item for good — the record and the Drive file behind it.
    ///
    /// Only from the trash. `DELETE /api/v1/photos/{id}/permanent` refuses a live photograph, and
    /// this refuses to call it for one, so the two-step path through Recently Deleted cannot be
    /// short-circuited into an unrecoverable delete one tap deep.
    func deletePermanently(id: String) {
        guard let index = trashItems.firstIndex(where: { $0.id == id }) else { return }
        let item = trashItems.remove(at: index)

        Task {
            do {
                _ = try await api.send(method: "DELETE", path: "/api/v1/photos/\(id)/permanent")
                try? await store?.delete(id: id)
                logger.debug("deletePermanently succeeded: id=\(id, privacy: .public)")
            } catch {
                logger.error("deletePermanently failed: id=\(id, privacy: .public) \(error, privacy: .public)")
                trashItems.insert(item, at: min(index, trashItems.count))
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
