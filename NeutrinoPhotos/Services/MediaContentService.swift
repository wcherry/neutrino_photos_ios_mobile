import Foundation
import Sodium
import UIKit
import os.log
import NeutrinoCore
import NeutrinoCrypto

// MARK: - MediaContentError

enum MediaContentError: LocalizedError {
    case noEncryptionKey
    /// This device holds an identity, but not the version this photo's DEK was sealed to. Named
    /// separately from `noEncryptionKey` because it sends the user somewhere else: not "import your
    /// key" but "this account rotated and this device is missing a version".
    case missingKeyVersion(Int)
    case encryptionFailed
    case decryptionFailed
    case notAuthenticated
    case undecodable
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .noEncryptionKey:
            return "No encryption key found. Import your key to open originals."
        case .missingKeyVersion(let version):
            return "This photo needs encryption key version \(version), which this device does not have. Scanning the key code again will not help \u{2014} it carries one key. On the computer that holds your key, open Settings \u{203A} Encryption and back up your older keys, then reopen this app."
        case .encryptionFailed:
            return "Failed to encrypt the photo."
        case .decryptionFailed:
            return "Failed to decrypt the photo. It may have been encrypted with a different key."
        case .notAuthenticated:
            return "You are not signed in."
        case .undecodable:
            return "That file isn't an image this app can display."
        case .cacheUnavailable:
            return "There isn't enough room on this device to open that."
        }
    }
}

// MARK: - SealedFileKey

/// A photo's DEK as the server holds it: the sealed blob, and which of the caller's identity
/// versions it was sealed to.
///
/// The two travel together everywhere because they are only meaningful together. Passing the blob
/// alone is what let a rotated account's older photos fail to open — the caller had no way to know
/// which key to reach for, so it always reached for the newest.
struct SealedFileKey: Equatable {
    let sealed: String
    let keyVersion: Int

    init(sealed: String, keyVersion: Int) {
        self.sealed = sealed
        self.keyVersion = keyVersion
    }

    /// A ref written before versioning carries no version. Read as 1, which is what the server
    /// defaults `file_key_refs.key_version` to for the same rows.
    fileprivate init(_ response: APIKeyResponse) {
        self.sealed = response.encryptedFileKey
        self.keyVersion = response.keyVersion ?? 1
    }
}

// MARK: - MediaContentService

/// The bytes: downloading and decrypting an original, and encrypting and uploading a new one.
///
/// Mirrors the E2EE protocol the web app uses for a Drive upload exactly — XChaCha20-Poly1305
/// secretstream for the content, `crypto_box_seal` for the per-file key — so a photograph imported
/// here opens on the web and vice versa.
///
/// ## The ladder
///
/// Three sizes, described in ``MediaRendition``. The grid draws the plaintext cover thumbnail that
/// rides along with the file's metadata, so nothing here is involved in scrolling a timeline. The
/// viewer opens a **preview** — 2048 px, encrypted, stored as a second Drive file — which is about a
/// tenth of an original's bytes. Only zoom and export reach for the original itself.
///
/// Every step falls back to the one below it. A photograph with no preview rendition (uploaded
/// before this existed, or one small enough that a rendition would not have paid for itself) opens
/// its original and makes a preview locally; a file with no cover thumbnail draws a symbol. Nothing
/// in the ladder is load-bearing.
///
/// ## What is held where
///
/// Decrypted bytes land in a size-capped ``DiskCache`` under `Library/Caches`, so a photograph
/// opened twice is downloaded once and a video plays from a file rather than from `Data`. Decoded
/// bitmaps sit in an `NSCache` above that, because a bitmap is twenty times its file and the right
/// response to a memory warning is to drop them rather than be killed holding them.
///
/// The cache is *decrypted*, which is a deliberate trade and not an oversight: it is written with
/// `.completeUntilFirstUserAuthentication` protection — the same accessibility class as the key that
/// produced it — excluded from iCloud backup, capped, evicted, and emptied from Settings. The
/// alternative, decrypting a 4 GB video on every play, is not one a phone can afford.
///
/// ## What is never logged
///
/// No method here logs a DEK, a sealed DEK, or plaintext. File ids and byte counts are the most
/// this will say about a photograph, because `os.log` messages persist in the system log store and
/// a key written there outlives the process that leaked it.
@MainActor
final class MediaContentService: ObservableObject {

    // MARK: - Thresholds

    /// Above this, a download spools to disk instead of into memory, and an upload is encrypted
    /// from a file rather than from `Data`.
    ///
    /// 32 MB is comfortably above every photograph — a 48-megapixel JPEG is about 15 — and
    /// comfortably below every video worth the name. Photographs therefore keep the simple path,
    /// and the memory-bounded one exists for exactly the files that need it.
    nonisolated static let streamingThreshold: Int64 = 32 << 20

    /// Above this, the content is written as a **chunked** secretstream rather than a single push.
    ///
    /// Higher than ``streamingThreshold`` on purpose, and the gap matters. A chunked file is not
    /// readable by today's web client (see ``MediaCrypto``), so this is the size at which a file
    /// stops being something anybody would open in a browser and starts being something no phone
    /// can hold in memory to decrypt. Every photograph lands below it and stays interoperable;
    /// videos land above it and stay openable.
    nonisolated static let chunkingThreshold: Int64 = 64 << 20

    /// The thresholds this instance actually uses. Injectable so a test can exercise the streaming
    /// paths against a kilobyte rather than by allocating sixty-four megabytes to prove a branch is
    /// taken — the code under test is identical either way, and a test that costs a gigabyte of
    /// simulator memory is a test somebody eventually deletes.
    private let streamingThreshold: Int64
    private let chunkingThreshold: Int64

    // MARK: - Dependencies

    private let api: APIClient

    /// Where the rendition index lives between launches. Optional throughout: a device whose
    /// database would not open still browses, uploads, and opens photographs — it just re-derives
    /// previews rather than finding the ones already in the cloud.
    private let store: LocalStore?

    /// Needed only to file a rendition: which Drive folder previews go in. Nil in tests that are
    /// not about renditions, in which case no rendition is uploaded and everything falls back.
    private weak var drive: PhotosDriveService?

    /// Decrypted originals, previews, and videos.
    private let originals: DiskCache

    /// The grid's thumbnails. Held here so `clearCache()` and the storage breakdown cover
    /// everything the app has written, rather than most of it.
    let thumbnails: ThumbnailCache

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "MediaContentService")

    /// Decoded images, keyed by file id and the rendition they were decoded at.
    ///
    /// `NSCache` rather than a dictionary because it evicts under memory pressure, which is the
    /// whole point: a viewer swiped through twenty photographs holds twenty full-screen bitmaps
    /// otherwise, and the OS kills the app rather than asking.
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 128 * 1024 * 1024   // bytes of bitmap, not pixels
        return cache
    }()

    /// Drive's own endpoints, unlike the Photos ones, are not uniformly camelCase — the sibling
    /// apps all read them with snake-case conversion, and a key that is already camelCase passes
    /// through it unchanged, so this is the safe spelling for both.
    private static let driveDecoder = DriveDate.makeDecoder(convertFromSnakeCase: true)

    /// Scratch space for the streaming paths: ciphertext on its way in or out, and the multipart
    /// body wrapped around it. Everything here is deleted as soon as its transfer ends.
    private var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("staging", isDirectory: true)
    }

    // MARK: - Init

    init(api: APIClient,
         store: LocalStore? = nil,
         drive: PhotosDriveService? = nil,
         originals: DiskCache = .originals(),
         thumbnails: ThumbnailCache = ThumbnailCache(),
         streamingThreshold: Int64 = MediaContentService.streamingThreshold,
         chunkingThreshold: Int64 = MediaContentService.chunkingThreshold) {
        self.api = api
        self.store = store
        self.drive = drive
        self.originals = originals
        self.thumbnails = thumbnails
        self.streamingThreshold = streamingThreshold
        self.chunkingThreshold = chunkingThreshold
    }

    // MARK: - Reading

    /// Downloads and decrypts an item's original, or answers from the cache.
    ///
    /// A file with no key ref is returned as it stands: that is a picture uploaded before E2EE, or
    /// by something that never sealed a key, and the download already *is* the image. The web app's
    /// resolver makes the same allowance, so the two agree on which files are readable.
    func originalData(for item: MediaItem) async throws -> Data {
        let url = try await localURL(for: item)
        // Mapped rather than read: a large original is then paged in as it is used and paged out
        // under pressure, instead of being a resident copy of a file that is already on disk.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw MediaContentError.cacheUnavailable
        }
        return data
    }

    /// A local file holding the item's decrypted original — the primitive the rest of the reading
    /// side is built on, and what `AVPlayer` needs, since it plays from a URL and a video is far
    /// too large to hold as `Data`.
    ///
    /// Named for the Drive file id and the original's extension: `AVPlayer` picks its demuxer from
    /// the path extension, so a `.mov` written as `.dat` simply does not play.
    func localURL(for item: MediaItem) async throws -> URL {
        let key = Self.originalCacheKey(for: item)
        if let cached = originals.url(forKey: key) {
            logger.debug("cache hit: \(item.fileID, privacy: .public)")
            return cached
        }

        let sealedDEK = try await fetchSealedDEKIfPresent(fileID: item.fileID)
        if item.sizeBytes > streamingThreshold {
            return try await downloadStreaming(item: item, sealedDEK: sealedDEK, key: key)
        }

        let ciphertext = try await api.data(path: "/api/v1/drive/files/\(item.fileID)")
        let plaintext = try await decrypt(ciphertext, sealedDEK: sealedDEK, fileID: item.fileID)
        guard let url = originals.store(plaintext, forKey: key) else {
            throw MediaContentError.cacheUnavailable
        }
        logger.debug("downloaded \(item.fileID, privacy: .public) (\(plaintext.count) bytes)")
        return url
    }

    /// The item at viewer size: the encrypted preview rendition if there is one, the original
    /// downscaled locally if there is not.
    ///
    /// The fallback is not a failure mode — it is what happens for every photograph uploaded before
    /// renditions existed, and for every one small enough that a rendition would not have saved
    /// anything. It costs the original download once, after which the generated preview is cached
    /// like any other.
    func previewData(for item: MediaItem) async throws -> Data {
        // Refused before anything is fetched. A video has no preview until Epic 8 can decode a
        // frame from one, and falling through to the original would download several gigabytes
        // into memory in order to fail at the decode.
        guard item.kind == .photo else { throw MediaContentError.undecodable }

        let key = Self.cacheKey(for: item, rendition: .preview)
        if let cached = originals.data(forKey: key) { return cached }

        if let renditionFileID = await store?.renditionFileID(forFile: item.fileID,
                                                              rendition: .preview) {
            do {
                let data = try await downloadSmallFile(id: renditionFileID)
                originals.store(data, forKey: key)
                logger.debug("preview rendition served for \(item.fileID, privacy: .public)")
                return data
            } catch {
                // The rendition is derived data; a missing or unreadable one is worth a line in the
                // log and nothing more, because the original is still there.
                logger.error("preview rendition unusable for \(item.fileID, privacy: .public): \(error, privacy: .public)")
            }
        }

        let original = try await originalData(for: item)
        // The same rule the upload side uses to decide whether a rendition is worth *making*: a
        // picture already about the size of a preview of it — a screenshot, a web graphic — gets
        // no preview at either end. Sharing the rule is what keeps a photograph from being served
        // as a rendition here and as an original there.
        guard let preview = try await Self.offMain({
            RenditionGenerator.previewWorthUploading(for: original)
        }) else {
            return original
        }
        originals.store(preview, forKey: key)
        return preview
    }

    /// The item as a displayable image at the given step of the ladder.
    ///
    /// Decoded through ImageIO rather than `UIImage(data:)` for everything below ``MediaRendition/original``,
    /// which holds the whole picture as a bitmap to draw it: about 48 MB for a 12-megapixel
    /// photograph, none of which is needed to fill a phone screen. `.original` decodes whole,
    /// because that is what it is for — a zoom that stayed downsampled would be a blurry zoom.
    func image(for item: MediaItem, rendition: MediaRendition = .preview) async throws -> UIImage {
        let key = "\(item.fileID)@\(rendition.rawValue)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }

        let image: UIImage?
        switch rendition {
        case .thumbnail:
            image = await thumbnails.image(for: item)
        case .preview:
            let data = try await previewData(for: item)
            let maxPixels = rendition.maximumPixels ?? 2048
            image = try await Self.offMain { RenditionGenerator.image(from: data, maxPixels: maxPixels) }
        case .original:
            let data = try await originalData(for: item)
            image = try await Self.offMain { RenditionGenerator.image(from: data) }
        }

        guard let image else { throw MediaContentError.undecodable }
        imageCache.setObject(image, forKey: key, cost: RenditionGenerator.bitmapCost(of: image))
        return image
    }

    // MARK: - Streaming download

    /// Downloads a large original to disk and decrypts it there, holding one chunk at a time.
    ///
    /// The framing has to be read before anything can be decrypted: a chunked file and a
    /// single-push one are indistinguishable from their bytes, and guessing wrong fails
    /// authentication rather than reading short. So the file's *encrypted metadata* is fetched and
    /// opened first — one small request — and its `chunkSize` decides which decryptor runs.
    ///
    /// A large file that turns out to be single-push is decrypted whole, because the format leaves
    /// no choice. That is why ``chunkingThreshold`` exists: everything this app writes above it is
    /// chunked, so the only files that can land here are ones another client wrote.
    private func downloadStreaming(item: MediaItem, sealedDEK: SealedFileKey?, key: String) async throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let ciphertextURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString).enc")
        let plaintextURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString).dec")
        defer {
            try? FileManager.default.removeItem(at: ciphertextURL)
            try? FileManager.default.removeItem(at: plaintextURL)
        }

        guard let sealedDEK else {
            // No key ref: the download already is the file. Straight into the cache.
            try await api.download(path: "/api/v1/drive/files/\(item.fileID)", to: plaintextURL)
            guard let url = originals.adopt(fileAt: plaintextURL, forKey: key) else {
                throw MediaContentError.cacheUnavailable
            }
            return url
        }

        let dek = try unsealDEK(sealedDEK.sealed, keyVersion: sealedDEK.keyVersion)
        let chunkSize = try await chunkSize(forFileID: item.fileID, dek: dek)
        try await api.download(path: "/api/v1/drive/files/\(item.fileID)", to: ciphertextURL)

        try await Self.offMain {
            if let chunkSize {
                try MediaCrypto.decryptStream(from: ciphertextURL, to: plaintextURL, dek: dek,
                                              chunkSize: chunkSize)
            } else {
                let ciphertext = try Data(contentsOf: ciphertextURL, options: .mappedIfSafe)
                let plaintext = try MediaCrypto.decrypt(ciphertext, dek: dek)
                try Data(plaintext).write(to: plaintextURL, options: .atomic)
            }
        }

        guard let url = originals.adopt(fileAt: plaintextURL, forKey: key) else {
            throw MediaContentError.cacheUnavailable
        }
        logger.debug("streamed \(item.fileID, privacy: .public) to the cache")
        return url
    }

    /// The chunk framing a file's content was written with, read out of its encrypted metadata.
    /// Nil means one push covering the whole file — the common case, and what a file with no
    /// metadata blob at all is assumed to be.
    private func chunkSize(forFileID fileID: String, dek: Bytes) async throws -> Int? {
        let file: DriveFile? = try? await api.getIfPresent(
            "/api/v1/drive/files/\(fileID)/metadata", decoder: Self.driveDecoder)
        guard let encrypted = file?.encryptedMetadata else { return nil }
        return try? MediaCrypto.decryptMetadata(encrypted, dek: dek).chunkSize
    }

    /// Downloads and decrypts a file that is known to be small — a preview rendition.
    private func downloadSmallFile(id fileID: String) async throws -> Data {
        let ciphertext = try await api.data(path: "/api/v1/drive/files/\(fileID)")
        let sealedDEK = try await fetchSealedDEKIfPresent(fileID: fileID)
        return try await decrypt(ciphertext, sealedDEK: sealedDEK, fileID: fileID)
    }

    private func decrypt(_ ciphertext: Data, sealedDEK: SealedFileKey?, fileID: String) async throws -> Data {
        guard let sealedDEK else {
            logger.debug("\(fileID, privacy: .public) has no key ref, using bytes as they are")
            return ciphertext
        }
        let dek = try unsealDEK(sealedDEK.sealed, keyVersion: sealedDEK.keyVersion)
        // One push covering the whole file — what this app writes below `chunkingThreshold` and
        // what the web client writes always.
        return try await Self.offMain { Data(try MediaCrypto.decrypt(ciphertext, dek: dek)) }
    }

    // MARK: - Writing

    /// Encrypts and uploads a picture, returning the Drive file id it was stored under.
    ///
    /// Registering it as a *photo* is a separate call — see
    /// ``PhotoLibraryService/register(fileID:captureDate:)``. The split is the server's: Drive owns
    /// the bytes, the Photos service owns the library, and an upload that failed to register leaves
    /// a file rather than a half-made photograph.
    ///
    /// No `folder_id` is sent for a photograph, so it lands in the account's Drive root. That is
    /// where the web app puts an uploaded picture, and its default library listing is root-scoped
    /// (`/drive/folders/{rootId}?type=photo`) — filing pictures into a tidy subfolder here would
    /// make them invisible there. The one thing that *does* take a folder is a preview rendition,
    /// which is filed away from the root for exactly the same reason in reverse.
    ///
    /// - Parameter thumbnailBase64: the plaintext preview to store alongside the ciphertext. The
    ///   server cannot make one itself: what it receives is encrypted and the key never leaves the
    ///   device. A photograph uploaded without a preview shows as a blank icon in every grid,
    ///   including this app's.
    @discardableResult
    func upload(data: Data, fileName: String, mimeType: String, thumbnailBase64: String?,
                folderID: String? = nil,
                onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> String {
        let dek = MediaCrypto.newDEK()
        let ciphertext = try await Self.offMain { try MediaCrypto.encrypt(Bytes(data), dek: dek) }
        let encryptedMetadata = try MediaCrypto.encryptMetadata(name: fileName, mimeType: mimeType,
                                                                dek: dek)
        let sealedFileKey = try sealDEK(dek)

        var form = MultipartFormBody()
        form.appendField(name: "encrypted_metadata", value: encryptedMetadata)
        form.appendField(name: "folder_id", value: folderID)
        // Written *before* the file part: the server reads the multipart stream in order and stops
        // at the file, so a field that follows the bytes is one it never sees.
        form.appendField(name: "thumbnail_b64", value: thumbnailBase64)
        form.appendFile(name: "file", fileName: fileName, mimeType: mimeType, data: ciphertext)

        let response = try await api.upload(method: "POST", path: "/api/v1/drive/files/upload",
                                            contentType: form.contentType, body: form.finalized(),
                                            onProgress: onProgress)
        let fileID = try await finishUpload(response: response, sealedFileKey: sealedFileKey)
        logger.debug("upload succeeded: id=\(fileID, privacy: .public) (\(data.count) bytes)")

        // A library photograph, rather than a rendition of one: cache what is already in hand and
        // make the rendition the next device to open it will want.
        if folderID == nil {
            cacheAfterUpload(fileID: fileID, data: data, fileName: fileName, mimeType: mimeType,
                             thumbnailBase64: thumbnailBase64)
            await uploadPreviewRendition(forOriginal: fileID, from: data, mimeType: mimeType)
        }
        return fileID
    }

    /// The same, for an original too large to hold in memory — a video.
    ///
    /// Nothing here is ever whole: the plaintext stays in the file the picker wrote, the ciphertext
    /// is written chunk by chunk beside it, the multipart body wraps that file by copying it through
    /// a buffer, and `URLSession` streams the result off disk. Peak memory is a couple of megabytes
    /// whether the video is 30 seconds or 20 minutes, which is the property step 6 of this epic's
    /// manual verification exists to catch the loss of.
    @discardableResult
    func upload(fileURL: URL, fileName: String, mimeType: String, thumbnailBase64: String?,
                folderID: String? = nil,
                onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0

        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let ciphertextURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString).enc")
        let bodyURL = stagingDirectory.appendingPathComponent("\(UUID().uuidString).body")
        defer {
            try? FileManager.default.removeItem(at: ciphertextURL)
            try? FileManager.default.removeItem(at: bodyURL)
        }

        let dek = MediaCrypto.newDEK()
        let shouldChunk = size > chunkingThreshold
        let chunkSize: Int? = try await Self.offMain {
            guard shouldChunk else {
                // Small enough to stay in the format the web client reads. Still written to a file,
                // so the transport is the same one either way.
                let plaintext = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                try MediaCrypto.encrypt(Bytes(plaintext), dek: dek)
                    .write(to: ciphertextURL, options: .atomic)
                return nil
            }
            return try MediaCrypto.encryptStream(from: fileURL, to: ciphertextURL, dek: dek)
        }

        let encryptedMetadata = try MediaCrypto.encryptMetadata(name: fileName, mimeType: mimeType,
                                                                chunkSize: chunkSize, dek: dek)
        let sealedFileKey = try sealDEK(dek)

        var form = MultipartFormBody()
        form.appendField(name: "encrypted_metadata", value: encryptedMetadata)
        form.appendField(name: "folder_id", value: folderID)
        form.appendField(name: "thumbnail_b64", value: thumbnailBase64)
        try form.write(to: bodyURL,
                       filePart: .init(name: "file", fileName: fileName, mimeType: mimeType),
                       fileURL: ciphertextURL)

        let response = try await api.upload(method: "POST", path: "/api/v1/drive/files/upload",
                                            contentType: form.contentType, bodyFile: bodyURL,
                                            onProgress: onProgress)
        let fileID = try await finishUpload(response: response, sealedFileKey: sealedFileKey)
        logger.debug("streamed upload succeeded: id=\(fileID, privacy: .public) (\(size) bytes, chunked=\(chunkSize != nil))")
        return fileID
    }

    /// Stores the file key and reports the new file's id.
    ///
    /// The upload endpoint takes ciphertext, not the sealed key, so the key ref is a second call —
    /// and a picture whose key never stored is one nothing can ever open. Allowed to throw rather
    /// than being fire-and-forget.
    private func finishUpload(response: Data, sealedFileKey: SealedFileKey) async throws -> String {
        let created = try Self.driveDecoder.decode(APIFileResponse.self, from: response)
        // `keyVersion` is sent, not left to the server's default of 1. Omitting it on a rotated
        // account files a photo sealed to v3 under v1, and every client — this one included — then
        // reaches for the wrong key and cannot open a picture that is perfectly intact.
        _ = try await api.send(method: "PUT", path: "/api/v1/drive/files/\(created.id)/key",
                               json: APIStoreKeyRequest(encryptedFileKey: sealedFileKey.sealed,
                                                        keyVersion: sealedFileKey.keyVersion))
        return created.id
    }

    // MARK: - Renditions

    /// Generates and uploads the encrypted preview rendition for a picture just uploaded.
    ///
    /// Deliberately swallows every failure. The original is safe by the time this runs, and a
    /// rendition is derived data with a fallback — refusing an import because a *preview* would not
    /// upload would trade the thing that matters for the thing that does not.
    ///
    /// Skipped entirely for a video (there is no frame to render until Epic 8 can decode one), for
    /// anything that is not an image, and for a picture whose preview would not be meaningfully
    /// smaller than the picture — see ``RenditionGenerator/previewWorthUploading(for:)``.
    func uploadPreviewRendition(forOriginal fileID: String, from data: Data, mimeType: String) async {
        guard mimeType.hasPrefix("image/") else { return }
        guard let drive else { return }
        guard let preview = try? await Self.offMain({
            RenditionGenerator.previewWorthUploading(for: data)
        }) else {
            logger.debug("no preview rendition for \(fileID, privacy: .public): it would not be smaller")
            return
        }

        do {
            guard let folderID = try await drive.renditionsFolderID() else { return }
            let name = MediaRendition.renditionFileName(forOriginal: fileID, rendition: .preview)
            let renditionFileID = try await upload(data: preview, fileName: name,
                                                   mimeType: "image/jpeg", thumbnailBase64: nil,
                                                   folderID: folderID)
            try? await store?.setRenditionFileID(renditionFileID, forFile: fileID,
                                                 rendition: .preview)
            // Already generated, so keep it: opening the photograph just uploaded should not be a
            // download of a file this device made.
            originals.store(preview, forKey: fileID + MediaRendition.preview.cacheKeySuffix)
            logger.debug("preview rendition stored for \(fileID, privacy: .public) (\(preview.count) bytes)")
        } catch {
            logger.error("preview rendition failed for \(fileID, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Live Photos

    /// Uploads a Live Photo's paired video into the account's Live Photos folder, encrypted like
    /// everything else, and answers the Drive file id it landed under.
    ///
    /// Answers nil rather than throwing when there is nowhere to put it — no Drive service injected,
    /// or a folder that could not be resolved. A Live Photo whose motion did not upload is still a
    /// photograph; the still is already safe by the time this runs, and the record simply carries no
    /// ``MediaDeviceFacts/liveVideoFileID``.
    ///
    /// Not registered as a photo, on purpose. The clip is half of an item the library already has,
    /// and registering it would put two entries in the timeline for one thing the user photographed.
    func uploadLivePhotoVideo(forOriginal fileID: String, from url: URL) async throws -> String? {
        guard let drive else { return nil }
        guard let folderID = try await drive.livePhotosFolderID() else { return nil }

        let name = PhotosDriveService.livePhotoVideoName(forOriginal: fileID)
        // Through the streaming path even though a Live Photo's motion is a couple of seconds:
        // it is a video, the path is the one that handles videos, and "small enough today" is not
        // a property worth writing a second code path around.
        let videoFileID = try await upload(fileURL: url, fileName: name,
                                            mimeType: "video/quicktime", thumbnailBase64: nil,
                                            folderID: folderID)
        logger.debug("live photo motion stored for \(fileID, privacy: .public)")
        return videoFileID
    }

    /// A local file holding the decrypted paired video of a Live Photo.
    ///
    /// What "stored now, rendered in v1.1" cashes out to: the motion is in the account and this is
    /// how it comes back — today so that Save to Device can put a real Live Photo into Apple Photos,
    /// and later so the viewer can play it in place.
    func livePhotoVideoURL(for item: MediaItem) async throws -> URL {
        guard let videoFileID = item.liveVideoFileID else {
            throw MediaContentError.undecodable
        }
        let key = "\(videoFileID).mov"
        if let cached = originals.url(forKey: key) { return cached }

        // Deliberately the small-file path: a paired video is a few seconds at capture resolution,
        // which is megabytes rather than the gigabytes the streaming path exists for.
        let data = try await downloadSmallFile(id: videoFileID)
        guard let url = originals.store(data, forKey: key) else {
            throw MediaContentError.cacheUnavailable
        }
        return url
    }

    /// Keeps what the device already had, so the photograph just imported opens without a download.
    ///
    /// Keyed off the *file name* the upload was given, because that is the name the library will
    /// come back with and ``originalCacheKey(for:)`` derives the extension from it. Deriving it
    /// from the MIME type here instead would file a JPEG under `.jpeg` and look for it under
    /// `.jpg` — a cache that silently never hits, which is indistinguishable from a slow network.
    private func cacheAfterUpload(fileID: String, data: Data, fileName: String, mimeType: String,
                                  thumbnailBase64: String?) {
        let ext = Self.fileExtension(forFileName: fileName, mimeType: mimeType)
        originals.store(data, forKey: "\(fileID).\(ext)")
        if let thumbnailBase64, let jpeg = Data(base64Encoded: thumbnailBase64) {
            thumbnails.store(jpeg, forFileID: fileID)
        }
    }

    // MARK: - Cache

    /// What the app has written to this device, broken down for the Settings screen.
    struct StorageBreakdown: Equatable {
        let originals: Int64
        let thumbnails: Int64
        let database: Int64

        var total: Int64 { originals + thumbnails + database }
    }

    func storageBreakdown() async -> StorageBreakdown {
        StorageBreakdown(originals: originals.totalBytes(),
                         thumbnails: thumbnails.totalBytesOnDisk(),
                         database: await store?.sizeOnDisk() ?? 0)
    }

    /// Bytes of decrypted media currently held on disk.
    func cacheSizeOnDisk() -> Int64 {
        originals.totalBytes() + thumbnails.totalBytesOnDisk()
    }

    /// Empties every cache. The library database is left alone — it is the timeline, not a copy of
    /// the photographs, and clearing it would empty the grid rather than free anything worth
    /// freeing.
    func clearCache() {
        imageCache.removeAllObjects()
        originals.removeAll()
        thumbnails.clear()
        try? FileManager.default.removeItem(at: stagingDirectory)
        logger.debug("cache cleared")
    }

    // MARK: - Crypto
    //
    // The primitives themselves live in `MediaCrypto`, which has no actor and no networking so it
    // can be called off the main thread and asserted on its own. What stays here is the part that
    // needs the Keychain: which key pair a DEK is sealed to.

    /// Seals `dek` to the account's **active** Curve25519 public key (`crypto_box_seal`), and
    /// reports which version that was.
    ///
    /// The version travels with the sealed key because the server records it on the key ref, and a
    /// ref that names the wrong version is a photo nothing can open: the web client reaches for the
    /// key the ref names, not the one it was actually sealed to.
    func sealDEK(_ dek: Bytes) throws -> SealedFileKey {
        guard let publicKey = Self.storedKey(KeyImportService.publicKeyKeychainKey) else {
            throw MediaContentError.noEncryptionKey
        }
        return SealedFileKey(sealed: try MediaCrypto.seal(dek: dek, toPublicKey: publicKey),
                             keyVersion: KeyImportService.activeKeyVersion())
    }

    /// Reverses ``sealDEK(_:)``, resolving `keyVersion` against the keys this device holds.
    ///
    /// `keyVersion` defaults to 1 because key refs written before rotation existed carry no
    /// version, and the server defaults the column to 1 for the same reason.
    ///
    /// A version this device lacks is reported as `missingKeyVersion` rather than as a decrypt
    /// failure. The distinction is the whole point of the versioning: the ciphertext is fine, the
    /// DEK is fine, and what is missing is one key that can still be brought across.
    func unsealDEK(_ sealedBase64: String, keyVersion: Int = 1) throws -> Bytes {
        let publicKey: Bytes
        let secretKey: Bytes
        switch KeyImportService.keyPair(forVersion: keyVersion) {
        case .found(let publicKeyBase64, let privateKeyBase64):
            guard let decodedPublic = KeyVaultCrypto.decodeBase64URL(publicKeyBase64),
                  let decodedSecret = KeyVaultCrypto.decodeBase64URL(privateKeyBase64) else {
                logger.error("unsealDEK: the stored key is not valid Base64URL")
                throw MediaContentError.noEncryptionKey
            }
            publicKey = decodedPublic
            secretKey = decodedSecret
        case .noKey:
            logger.error("unsealDEK: this device holds no encryption key")
            throw MediaContentError.noEncryptionKey
        case .missingVersion(let version):
            logger.error("unsealDEK: no key for version \(version, privacy: .public)")
            throw MediaContentError.missingKeyVersion(version)
        }

        do {
            return try MediaCrypto.openDEK(sealedBase64, publicKey: publicKey, secretKey: secretKey)
        } catch {
            logger.error("unsealDEK: the seal was not made to key version \(keyVersion, privacy: .public)")
            throw error
        }
    }

    private static func storedKey(_ keychainKey: String) -> Bytes? {
        KeychainService.load(forKey: keychainKey).flatMap(KeyVaultCrypto.decodeBase64URL)
    }

    // MARK: - Private helpers

    /// The sealed DEK for a file, or nil when the server has none stored for this caller.
    ///
    /// `GET /files/{id}/key` answers 404 for that case (`get_file_key` in
    /// `src/drive/encryption/api.rs`), which is a fact about the file rather than a failure.
    private func fetchSealedDEKIfPresent(fileID: String) async throws -> SealedFileKey? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response: APIKeyResponse? = try await api.getIfPresent(
            "/api/v1/drive/files/\(fileID)/key", decoder: decoder)
        return response.map(SealedFileKey.init)
    }

    // MARK: - Off the main actor

    /// Runs CPU-bound work on a background task and hands the result back.
    ///
    /// Everything this wraps is arithmetic over megabytes: a secretstream push, a JPEG re-encode, a
    /// SHA-256. This service is `@MainActor` because its callers are views, which means without
    /// this every one of those would run on the thread drawing the grid — and encrypting a
    /// four-gigabyte video there is not a dropped frame, it is a watchdog kill.
    private static func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    // MARK: - Cache keys

    /// The original's key carries the file's extension, because the file *is* the value handed to
    /// `AVPlayer` and it picks its demuxer from the path.
    static func originalCacheKey(for item: MediaItem) -> String {
        "\(item.fileID).\(fileExtension(forFileName: item.fileName, mimeType: item.mimeType))"
    }

    static func cacheKey(for item: MediaItem, rendition: MediaRendition) -> String {
        switch rendition {
        case .original: return originalCacheKey(for: item)
        default:        return item.fileID + rendition.cacheKeySuffix
        }
    }

    private static func fileExtension(forFileName fileName: String?, mimeType: String) -> String {
        if let fileName, let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex {
            return String(fileName[fileName.index(after: dot)...])
        }
        // Falls back to the MIME subtype: "video/quicktime" is not a usable extension, but
        // "video/mp4" is, and either beats no extension at all.
        return mimeType.split(separator: "/").last.map(String.init) ?? "dat"
    }
}

// MARK: - API Models

private struct APIFileResponse: Decodable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let mimeType: String

    private enum CodingKeys: String, CodingKey {
        case id, name, sizeBytes, mimeType
    }
}

private struct APIKeyResponse: Decodable {
    let encryptedFileKey: String
    /// Which of the caller's identity versions the DEK is sealed to. Optional so a server that
    /// predates versioning still decodes; `SealedFileKey` reads a missing value as 1, matching the
    /// column's own default.
    let keyVersion: Int?
}

private struct APIStoreKeyRequest: Encodable {
    let encryptedFileKey: String
    let keyVersion: Int
}
