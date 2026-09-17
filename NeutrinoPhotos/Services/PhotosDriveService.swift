import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - PhotosDriveError

enum PhotosDriveError: LocalizedError {
    case notAuthenticated
    case noRootFolder

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "You are not signed in."
        case .noRootFolder:
            // The root folder's id *is* the user id — see `driveRootID` — so failing to find one
            // means the access token has no `sub` claim, which is a broken session rather than a
            // missing folder.
            return "Could not read your Drive. Try signing out and back in."
        }
    }
}

// MARK: - PhotosDriveService

/// Drive, seen through the photo library's eyes: the files under `type=photo`, the renditions
/// folder beside them, and how much room the account has left.
///
/// ## Why this exists next to `PhotoLibraryService`
///
/// They answer different questions and neither can answer the other's. `GET /api/v1/photos` lists
/// *photo records* — the timeline, its capture dates, its favourites — and knows nothing about the
/// bytes. `GET /api/v1/drive/folders/{root}?type=photo` lists *files* — sizes, names, encrypted
/// metadata, and, crucially, images that were never registered as photographs. An image uploaded by
/// Drive on the web, or by an import that uploaded and then failed to register, exists only in the
/// second listing. Reconciling the two is what ``unregisteredPhotoFiles(knownFileIDs:)`` is for.
///
/// ## The root folder has no id
///
/// A user's Drive root is addressed by passing their own user id to the folder route — the server's
/// documented sentinel. That is why this reads the `sub` claim out of the access token rather than
/// taking a folder parameter.
@MainActor
final class PhotosDriveService: ObservableObject {

    // MARK: - Published State

    /// The account's storage usage, once ``loadQuota()`` has been round. Nil before then, and left
    /// alone by a failure — a stale number beats a blank one, and neither is worth an error banner.
    @Published private(set) var quota: DriveQuota?

    // MARK: - Configuration

    /// The Drive folder encrypted preview renditions live in.
    ///
    /// A *subfolder*, deliberately. The library listings on both the web and this app are scoped to
    /// the Drive root (`/drive/folders/{rootId}?type=photo`), so a rendition filed here is invisible
    /// to them — which is the point: it is a derived artefact, not a second copy of the photograph
    /// somebody took. Named plainly rather than hidden, because a user who finds it in Drive
    /// deserves to be able to tell what it is, and deleting it costs them nothing but a re-render.
    static let renditionsFolderName = "Photo Previews"

    /// The Drive folder holding the paired videos of imported Live Photos.
    ///
    /// A subfolder for the same reason previews get one, and for one more. A Live Photo's motion is
    /// a MOV, and a MOV in the Drive root is a *video* to `type=video` listings — so filing it there
    /// would put a two-second clip of somebody's shoes in the timeline beside the photograph it
    /// belongs to. Here it is invisible to both root-scoped listings and reachable by name.
    static let livePhotosFolderName = "Live Photos"

    /// The name a Live Photo's paired video is stored under.
    ///
    /// Unlike a rendition's name this is not an index — the file id travels in the photo record's
    /// metadata (``MediaDeviceFacts/liveVideoFileID``), so nothing has to parse it back. It exists
    /// so somebody browsing this folder in Drive can tell which photograph a clip belongs to.
    static func livePhotoVideoName(forOriginal fileID: String) -> String {
        "\(fileID).live.mov"
    }

    // MARK: - Dependencies

    private let api: APIClient
    private let store: LocalStore?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "PhotosDriveService")

    /// Drive's payloads are snake_case in places and camelCase in others; a camelCase key survives
    /// the conversion strategy unchanged, so this spelling reads both.
    private static let decoder = DriveDate.makeDecoder(convertFromSnakeCase: true)

    /// Resolved once per launch, keyed by the meta key each folder is remembered under. The folders
    /// do not move, and finding one is a listing.
    private var cachedFolderIDs: [String: String] = [:]

    // MARK: - Init

    init(api: APIClient, store: LocalStore? = nil) {
        self.api = api
        self.store = store
    }

    // MARK: - Listing

    /// The account's image files, newest first.
    ///
    /// Scoped to the Drive root and to `type=photo`, which the server matches as `image/%` — so this
    /// is pictures, not videos. ``photoFiles(limit:offset:)`` and the video listing are separate
    /// calls because the server's filter takes one type at a time.
    func photoFiles(limit: Int = 200, offset: Int = 0) async throws -> [DriveFile] {
        try await files(ofType: "photo", limit: limit, offset: offset)
    }

    func videoFiles(limit: Int = 200, offset: Int = 0) async throws -> [DriveFile] {
        try await files(ofType: "video", limit: limit, offset: offset)
    }

    private func files(ofType type: String, limit: Int, offset: Int) async throws -> [DriveFile] {
        let root = try driveRootID()
        let path = "/api/v1/drive/folders/\(root)?type=\(type)&limit=\(limit)&offset=\(offset)"
        let contents: APIFolderContents = try await api.get(path, decoder: Self.decoder)
        return contents.files
    }

    /// One file's record, including the `encryptedMetadata` a streaming download needs.
    func file(id: String) async throws -> DriveFile {
        try await api.get("/api/v1/drive/files/\(id)/metadata", decoder: Self.decoder)
    }

    /// The same, answering nil for a file that is gone rather than throwing — the shape a cache
    /// refresh wants, since a deleted file is a fact and not a failure.
    func fileIfPresent(id: String) async throws -> DriveFile? {
        try await api.getIfPresent("/api/v1/drive/files/\(id)/metadata", decoder: Self.decoder)
    }

    // MARK: - Reconciliation

    /// Image files in Drive that the Photos library has no record of.
    ///
    /// Those are real and they are not an error: a picture uploaded through Drive on the web, or an
    /// import that stored its bytes and then lost the network before registering them. The second
    /// case is the one that matters here, because the bytes are already paid for — Epic 6's
    /// duplicate detection is where this turns into "register it" rather than "upload it again".
    func unregisteredPhotoFiles(knownFileIDs: Set<String>) async throws -> [DriveFile] {
        try await photoFiles().filter { !knownFileIDs.contains($0.id) }
    }

    // MARK: - Mutation

    /// Renames a Drive file. The photo record's `fileName` follows it, since that is where the
    /// library reads the name from.
    @discardableResult
    func rename(fileID: String, to name: String) async throws -> DriveFile {
        try await api.patch("/api/v1/drive/files/\(fileID)",
                            body: APIUpdateFileRequest(name: name), decoder: Self.decoder)
    }

    /// Moves a Drive file to Drive's trash.
    ///
    /// Not what deleting a photograph does — ``PhotoLibraryService/trash(id:)`` stamps the *photo
    /// record* and deliberately leaves the file alone, so a restore is a flag rather than an
    /// undelete. This is for the files that are not photographs: an orphaned rendition, an upload
    /// that was never registered.
    func delete(fileID: String) async throws {
        _ = try await api.send(method: "DELETE", path: "/api/v1/drive/files/\(fileID)")
    }

    // MARK: - Quota

    func loadQuota() async {
        do {
            quota = try await api.get("/api/v1/drive/quota", decoder: Self.decoder)
        } catch {
            logger.error("loadQuota failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Renditions

    /// The renditions folder, creating it if this account has none yet.
    ///
    /// Resolved by name rather than by a stored id wherever possible: an id cached on one device is
    /// meaningless on another, and a user who deleted the folder in Drive should get a new one
    /// rather than an error. The id *is* cached — in memory and in ``LocalStore`` — because the
    /// resolution is a listing and an upload should not pay for it every time.
    func renditionsFolderID(creatingIfNeeded: Bool = true) async throws -> String? {
        try await folderID(named: Self.renditionsFolderName,
                           rememberedAs: LocalStore.MetaKey.renditionsFolderID,
                           creatingIfNeeded: creatingIfNeeded)
    }

    /// The Live Photos folder, creating it if this account has none yet. Same contract as
    /// ``renditionsFolderID(creatingIfNeeded:)`` — see ``livePhotosFolderName`` for why it is not
    /// the root.
    func livePhotosFolderID(creatingIfNeeded: Bool = true) async throws -> String? {
        try await folderID(named: Self.livePhotosFolderName,
                           rememberedAs: LocalStore.MetaKey.livePhotosFolderID,
                           creatingIfNeeded: creatingIfNeeded)
    }

    /// Finds one of this app's own Drive folders by name, creating it if asked to.
    ///
    /// By name rather than by a stored id wherever possible: an id cached on one device is
    /// meaningless on another, and a user who deleted the folder in Drive should get a new one
    /// rather than an error. The id *is* cached — in memory and in ``LocalStore`` — because the
    /// resolution is a listing and an upload should not pay for one every time.
    private func folderID(named name: String, rememberedAs key: String,
                          creatingIfNeeded: Bool) async throws -> String? {
        if let cached = cachedFolderIDs[key] { return cached }
        if let stored = await store?.string(forKey: key) {
            cachedFolderIDs[key] = stored
            return stored
        }

        if let existing = try await findFolder(named: name) {
            await rememberFolder(existing, as: key)
            return existing
        }
        guard creatingIfNeeded else { return nil }

        let created: DriveFolder = try await api.post(
            "/api/v1/drive/folders",
            body: APICreateFolderRequest(name: name, parentId: nil),
            decoder: Self.decoder)
        logger.debug("created the \(name, privacy: .public) folder: \(created.id, privacy: .public)")
        await rememberFolder(created.id, as: key)
        return created.id
    }

    /// Looks for one of this app's folders among the root's subfolders, a page at a time.
    ///
    /// ## Why this is paged for a question about *folders*
    ///
    /// Because the endpoint that answers it also returns the root's **files**, and with no `limit`
    /// the server reads that as `i64::MAX` (`SqlPage::from_query`). Every photograph this app
    /// uploads lands in the Drive root, so asking this question unpaged on an account with a
    /// camera roll in it means pulling every file in the account — id, name, mime type, timestamps
    /// and `encryptedMetadata` per row — to find a folder by name.
    ///
    /// That is issue #3 again, in the *upload* path rather than the listing one: the request was
    /// the first thing an import did after sending a photograph's bytes (via
    /// ``renditionsFolderID(creatingIfNeeded:)``), it took minutes or timed out on a large
    /// account, and because it happens before the queue row is marked done the whole import sat at
    /// "0 of N" with nothing failing and so nothing logged. The decode made it worse: `APIClient`
    /// is `@MainActor`, so tens of megabytes of JSON were parsed on the thread drawing the
    /// progress bar.
    ///
    /// `limit` applies to the folder query and the file query separately — see
    /// `list_subfolders` and `list_files_in_folder` — so a page of 200 bounds both. For any real
    /// account this is one request that stops at the first page.
    private func findFolder(named name: String) async throws -> String? {
        let root = try driveRootID()
        for page in 0..<Self.maxFolderPages {
            let path = """
                /api/v1/drive/folders/\(root)?limit=\(Self.folderPageSize)\
                &offset=\(page * Self.folderPageSize)
                """
            let contents: APIFolderContents = try await api.get(path, decoder: Self.decoder)
            if let match = contents.folders.first(where: { $0.name == name }) { return match.id }
            // A short page means the subfolders have run out, whatever the files did.
            if contents.folders.count < Self.folderPageSize { return nil }
        }
        // Answering nil here would make the caller create a second folder of the same name, so say
        // so: ten thousand folders in one Drive root is a broken account rather than a big one.
        logger.error("gave up looking for the \(name, privacy: .public) folder after \(Self.maxFolderPages) pages")
        return nil
    }

    /// Subfolders per page while resolving one by name — the same 200 the photo listing pages by,
    /// so the two put the same shape of load on the server.
    private static let folderPageSize = 200

    /// A stop on the walk, not a limit on the account: a server that keeps answering full pages
    /// must not be able to hold an import in a loop that never ends.
    private static let maxFolderPages = 50

    /// Reads the renditions folder and records what is in it: original file id → rendition file id.
    ///
    /// Needed because nothing on a photo record can point at a rendition. The device that uploaded
    /// one knows its id immediately; every *other* device learns it from this listing, by reading
    /// the names — which is why ``MediaRendition/renditionFileName(forOriginal:rendition:)`` is a
    /// format rather than a convention.
    @discardableResult
    func refreshRenditionIndex() async -> [String: String] {
        do {
            guard let folderID = try await renditionsFolderID(creatingIfNeeded: false) else {
                return [:]
            }
            let contents: APIFolderContents = try await api.get(
                "/api/v1/drive/folders/\(folderID)?type=photo&limit=1000", decoder: Self.decoder)

            var index: [String: String] = [:]
            for file in contents.files {
                guard let parsed = MediaRendition.originalFileID(fromRenditionName: file.name),
                      parsed.rendition == .preview else { continue }
                index[parsed.fileID] = file.id
            }
            try await store?.replaceRenditions(with: index, rendition: .preview)
            try await store?.setString(DriveDate.naiveUTCString(from: Date()),
                                       forKey: LocalStore.MetaKey.renditionsSyncedAt)
            logger.debug("rendition index: \(index.count) preview(s)")
            return index
        } catch {
            // A missing index costs speed, not correctness: every read falls back to the original.
            logger.error("refreshRenditionIndex failed: \(error, privacy: .public)")
            return [:]
        }
    }

    private func rememberFolder(_ id: String, as key: String) async {
        cachedFolderIDs[key] = id
        try? await store?.setString(id, forKey: key)
    }

    // MARK: - Root

    /// The Drive root's id, which is the signed-in user's own id.
    ///
    /// The folder route documents this as its sentinel: "Pass the caller's own user id to list the
    /// drive root — a user's root folder has no id of its own."
    func driveRootID() throws -> String {
        guard let userID = AccessToken.currentUserID() else {
            throw PhotosDriveError.notAuthenticated
        }
        return userID
    }
}

// MARK: - API Models

private struct APIFolderContents: Decodable {
    let folders: [DriveFolder]
    let files: [DriveFile]
}

private struct APIUpdateFileRequest: Encodable {
    let name: String
}

private struct APICreateFolderRequest: Encodable {
    let name: String
    let parentId: String?
}
