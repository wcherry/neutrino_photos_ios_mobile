import CryptoKit
import Foundation
import os.log

// MARK: - MediaImportPipeline

/// One item's journey from bytes on this device to a photograph in the account.
///
/// Everything both importers do identically lives here: the duplicate check, the upload, the
/// registration, and the three best-effort steps that follow a successful one — the favourite flag,
/// a Live Photo's motion, and the metadata index.
///
/// It exists because there are now two callers. ``PhotoImportService`` imports what somebody picked
/// in the system picker; ``LibraryImportService`` imports a whole photo library. They differ in
/// where the bytes come from, how failures are reported, and nothing else — and if they each owned
/// their own copy of this, the first divergence would be a photograph that arrives with its EXIF on
/// one route and without it on the other, which is the sort of bug nobody finds for a year.
///
/// ## Best effort, after the picture is safe
///
/// Everything past `register` is deliberately swallowed. The photograph is in the account by then,
/// and none of what follows is the photograph — failing an import because a *flag* would not set,
/// or because the metadata index refused, would trade the thing that matters for the thing that
/// does not.
@MainActor
final class MediaImportPipeline {

    // MARK: - Outcome

    /// What happened to one item.
    struct Outcome {
        /// The registered photograph, or nil when nothing was uploaded.
        let item: MediaItem?
        /// True when the item was already in the account and was deliberately not sent again.
        let wasDuplicate: Bool
    }

    // MARK: - Dependencies

    private let content: MediaContentService
    private let library: PhotoLibraryService
    private let settings: AppSettings
    let ledger: ImportLedger

    /// Only needed to fetch a Live Photo's second half. Weak and optional, like everywhere it
    /// appears: an import with no photo-library access runs on what the file itself says.
    private weak var deviceLibrary: DevicePhotoLibrary?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "MediaImportPipeline")

    // MARK: - Init

    init(content: MediaContentService, library: PhotoLibraryService, settings: AppSettings,
         ledger: ImportLedger, deviceLibrary: DevicePhotoLibrary? = nil) {
        self.content = content
        self.library = library
        self.settings = settings
        self.ledger = ledger
        self.deviceLibrary = deviceLibrary
    }

    // MARK: - Photographs

    /// Uploads a prepared picture and registers it as a photograph.
    ///
    /// - Parameter device: what the photo library knows about the item, when it is visible. This is
    ///   what supplies the capture date for a screenshot, the favourite flag, and the coordinates an
    ///   editor stripped out.
    func importPhoto(_ prepared: ImagePreparation.Prepared, fileName: String,
                     device: DeviceAsset?,
                     onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> Outcome {
        let bytes = prepared.data
        let fingerprint = await Task.detached(priority: .userInitiated) {
            Self.fingerprint(of: bytes)
        }.value
        if await isDuplicate(localIdentifier: device?.localIdentifier, fingerprint: fingerprint) {
            logger.debug("skipped a duplicate: \(fileName, privacy: .public)")
            return Outcome(item: nil, wasDuplicate: true)
        }

        let fileID = try await content.upload(data: prepared.data, fileName: fileName,
                                              mimeType: prepared.mimeType,
                                              thumbnailBase64: prepared.thumbnailBase64,
                                              onProgress: onProgress)
        // The asset's date first. EXIF is absent from screenshots, screen recordings, and anything
        // an editor exported, and every one of those would otherwise file itself under today.
        let item = try await library.register(fileID: fileID,
                                              captureDate: device?.creationDate
                                                ?? prepared.captureDate)
        await ledger.record(localIdentifier: device?.localIdentifier, fingerprint: fingerprint,
                            photoID: item.id)
        logger.debug("imported \(fileName, privacy: .public) as \(fileID, privacy: .public)")

        await finish(item: item, bytes: prepared.data, device: device)
        return Outcome(item: item, wasDuplicate: false)
    }

    // MARK: - Videos

    /// The same, for a video — which is a file rather than a `Data` throughout, because a 4K
    /// three-minute clip read into memory is half a gigabyte before a byte has been encrypted.
    func importVideo(at url: URL, fileName: String, mimeType: String, device: DeviceAsset?,
                     onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> Outcome {
        let fingerprint = try await Task.detached(priority: .userInitiated) {
            try Self.fingerprint(ofFileAt: url)
        }.value
        if await isDuplicate(localIdentifier: device?.localIdentifier, fingerprint: fingerprint) {
            logger.debug("skipped a duplicate video: \(fileName, privacy: .public)")
            return Outcome(item: nil, wasDuplicate: true)
        }

        let fileID = try await content.upload(fileURL: url, fileName: fileName, mimeType: mimeType,
                                              thumbnailBase64: nil, onProgress: onProgress)
        // A video carries no EXIF this app reads, so the asset's date is the *only* capture date it
        // will ever have — without library access every clip sorts under its upload time.
        let item = try await library.register(fileID: fileID, captureDate: device?.creationDate)
        await ledger.record(localIdentifier: device?.localIdentifier, fingerprint: fingerprint,
                            photoID: item.id)
        logger.debug("imported \(fileName, privacy: .public) as \(fileID, privacy: .public)")

        await finishVideo(item: item, device: device)
        return Outcome(item: item, wasDuplicate: false)
    }

    // MARK: - Duplicates

    /// Both keys, in the order that costs least. See ``ImportLedger`` for why there are two.
    private func isDuplicate(localIdentifier: String?, fingerprint: String) async -> Bool {
        if let localIdentifier, ledger.contains(localIdentifier: localIdentifier) { return true }
        return await ledger.contains(fingerprint: fingerprint)
    }

    // MARK: - After the original is safe

    /// The favourite flag, the Live Photo motion, and the metadata — none of which is the picture.
    private func finish(item: MediaItem, bytes: Data, device: DeviceAsset?) async {
        if device?.isFavorite == true, FeatureFlags.favorites {
            // Optimistic and fire-and-forget, exactly as the star in the viewer is.
            library.setStarred(id: item.id, isStarred: true)
        }

        var liveVideoFileID: String?
        if device?.isLivePhoto == true, settings.importsLivePhotoMotion, let device {
            liveVideoFileID = await uploadLiveMotion(for: item.fileID, device: device)
        }

        // Off the main actor: this is ImageIO parsing headers, which is fast but is not free and
        // has no business on the thread drawing the import progress bar.
        let extracted = await Task.detached(priority: .userInitiated) {
            MediaMetadataExtractor.metadata(from: bytes)
        }.value
        guard let metadata = MediaMetadataExtractor.merged(extracted, with: device,
                                                            liveVideoFileID: liveVideoFileID) else {
            return
        }
        await library.setMetadata(metadata, forPhoto: item.id,
                                  publishingLocation: settings.publishesLocationMetadata)
    }

    /// The video counterpart.
    ///
    /// Shorter because there are no bytes to read: nothing in this app parses a video container, so
    /// everything a clip's record knows comes from the asset — its dimensions, its favourite flag,
    /// where it was shot, and whether it is slow-motion or a time-lapse.
    private func finishVideo(item: MediaItem, device: DeviceAsset?) async {
        guard let device else { return }
        if device.isFavorite, FeatureFlags.favorites {
            library.setStarred(id: item.id, isStarred: true)
        }
        guard let metadata = MediaMetadataExtractor.merged(nil, with: device) else { return }
        await library.setMetadata(metadata, forPhoto: item.id,
                                  publishingLocation: settings.publishesLocationMetadata)
    }

    /// Sends a Live Photo's paired video up beside the still it belongs to.
    ///
    /// Answers the video's Drive file id, which is what ties the two together — it travels in the
    /// photo record's metadata, so any device that lists the library learns about the motion without
    /// having to go looking for it in Drive.
    private func uploadLiveMotion(for fileID: String, device: DeviceAsset) async -> String? {
        guard let deviceLibrary else { return nil }
        do {
            guard let url = try await deviceLibrary.writePairedVideo(
                for: device.localIdentifier) else { return nil }
            defer { try? FileManager.default.removeItem(at: url) }
            return try await content.uploadLivePhotoVideo(forOriginal: fileID, from: url)
        } catch {
            logger.error("live photo motion failed for \(fileID, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Fingerprints

    nonisolated static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same hash, computed a block at a time — a video cannot be read into memory to be
    /// fingerprinted any more than it can be to be encrypted.
    ///
    /// `nonisolated` so it can be called off the main actor, which is where hashing half a gigabyte
    /// belongs. Both callers await it on a detached task for that reason.
    nonisolated static func fingerprint(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
