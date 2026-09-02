import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os.log
import NeutrinoCore
import NeutrinoCrypto

// MARK: - PhotoImportService

/// Imports items chosen in the system photo picker: prepare, encrypt, upload, register.
///
/// The upload itself, the duplicate check, and everything that follows a successful item belong to
/// ``MediaImportPipeline``, which ``LibraryImportService`` shares — see that type for why. What is
/// left here is the picker's half: turning a `PhotosPickerItem` into bytes, and reporting a run.
///
/// ## Why one at a time
///
/// An original is held in memory twice while it is being sent — the plaintext and its ciphertext —
/// so a phone importing five 48-megapixel photographs in parallel is a phone the OS kills. A serial
/// queue also gives honest progress ("3 of 40", with a byte count for the one in flight) instead of
/// five bars that each stall.
///
/// ## Selection, not permission
///
/// `PhotosPicker` runs out of process and hands back only what the user picked, so this needs no
/// photo-library authorization and the app never sees the rest of the roll. That is also why this
/// cannot yet *watch* for new photographs: automatic backup needs `PHPhotoLibrary` and its
/// permission prompt, which is `FeatureFlags.automaticBackup`.
///
/// ## What library access adds, when it has been granted
///
/// A picker item is bytes; a photo library is more than bytes. When ``DevicePhotoLibrary`` can see
/// the asset an item came from — `PhotosPickerItem.itemIdentifier` is its `localIdentifier` — the
/// import is enriched with the things no image file carries:
///
/// - the **real capture date**, so a screenshot or an edited export files itself under the day it
///   was taken rather than the day it was uploaded;
/// - its **favourite** flag, so a starred library arrives starred;
/// - its **coordinates**, for the pictures an editor stripped the GPS block out of;
/// - a Live Photo's **paired video**, uploaded beside the still so the motion is not silently lost;
/// - a **RAW original**, fetched as the resource the camera wrote rather than as the compatible
///   JPEG the picker would otherwise hand over.
///
/// Every one of those degrades rather than breaks. With no access the import runs exactly as it did
/// before, on what the file itself says.
@MainActor
final class PhotoImportService: ObservableObject {

    // MARK: - Failure

    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let message: String
    }

    // MARK: - Published State

    @Published private(set) var isImporting = false
    /// How many items the current run was asked for, and how many it has finished.
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    /// Items skipped because this device has already uploaded those exact bytes.
    @Published private(set) var skipped = 0
    /// Fraction of the item currently in flight, 0 to 1.
    @Published private(set) var currentFraction: Double = 0
    @Published private(set) var currentName: String?
    @Published private(set) var failures: [Failure] = []
    /// Set when the whole run could not start — no key imported, or waiting for Wi-Fi.
    @Published var blockedReason: String?

    // MARK: - Dependencies

    /// Upload, register, de-duplicate, enrich. Shared with the full-library importer.
    private let pipeline: MediaImportPipeline

    private let settings: AppSettings
    private let monitor: NetworkMonitor

    /// The device's own photo library, when the user has let the app see it. Optional throughout —
    /// nil in tests and in a build with ``FeatureFlags/deviceLibraryAccess`` off — and every use of
    /// it is a `?` followed by a fallback, because an import that *required* photo access would
    /// have thrown away the one property that makes the picker path worth having.
    private weak var deviceLibrary: DevicePhotoLibrary?

    /// Consulted only to explain *why* there is no key — "unlock" and "import a key file" are very
    /// different instructions and guessing wrong sends the user to the wrong screen. The precondition
    /// itself is still the Keychain: a key that got here by any route is a key that works.
    private weak var vault: KeyVaultService?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "PhotoImportService")

    private var task: Task<Void, Never>?

    // MARK: - Init

    init(content: MediaContentService, library: PhotoLibraryService,
         settings: AppSettings, monitor: NetworkMonitor,
         vault: KeyVaultService? = nil,
         deviceLibrary: DevicePhotoLibrary? = nil,
         ledger: ImportLedger? = nil,
         defaults: UserDefaults = .standard) {
        self.settings = settings
        self.monitor = monitor
        self.vault = vault
        self.deviceLibrary = deviceLibrary
        self.pipeline = MediaImportPipeline(
            content: content, library: library, settings: settings,
            ledger: ledger ?? ImportLedger(defaults: defaults), deviceLibrary: deviceLibrary
        )
    }

    // MARK: - Importing

    /// Starts importing `pickerItems`. A second call while a run is in flight is ignored rather
    /// than queued — the picker is modal, so there is no way to make one without seeing the first.
    func startImport(_ pickerItems: [PhotosPickerItem]) {
        guard !isImporting, !pickerItems.isEmpty else { return }

        blockedReason = nil
        guard KeyImportService.hasStoredKeys() else {
            // Refused rather than attempted: an upload without a key would store bytes nothing can
            // ever decrypt, which is worse than not uploading them.
            blockedReason = missingKeyReason
            return
        }
        guard monitor.shouldUpload(wifiOnly: settings.wifiOnlyUploads) else {
            blockedReason = monitor.isOnline
                ? "Waiting for Wi-Fi. Turn off “Upload over Wi-Fi only” in Settings to use cellular."
                : "You're offline. Photos will upload when you're back on a network."
            return
        }

        isImporting = true
        total = pickerItems.count
        completed = 0
        skipped = 0
        failures = []
        currentFraction = 0

        task = Task { [weak self] in
            guard let self else { return }
            for pickerItem in pickerItems {
                if Task.isCancelled { break }
                await self.importOne(pickerItem)
                self.completed += 1
                self.currentFraction = 0
            }
            self.currentName = nil
            self.isImporting = false
            self.task = nil
            // Paired videos and RAW originals are written to disk on the way through. A cancelled
            // run leaves the one it was holding, and a library of Live Photos is gigabytes of them.
            self.deviceLibrary?.clearStaging()
        }
    }

    /// Why an import cannot start, worded for the route back.
    ///
    /// An account with a vault is one unlock away; an account without one needs a key file, and
    /// telling somebody to "unlock" when there is nothing to unlock sends them looking for a
    /// password that does not exist.
    var missingKeyReason: String {
        switch vault?.status {
        case .locked, .unknown, .unreachable, .none:
            return "Unlock your encryption key before uploading photos."
        case .noVault, .unlocked:
            return "Import your encryption key before uploading photos."
        }
    }

    /// Stops after the item in flight — `URLSession` propagates the cancellation, and Drive only
    /// records a file for a request that carried its bytes, so an interrupted upload leaves nothing
    /// behind to clean up.
    func cancel() {
        task?.cancel()
    }

    // MARK: - One item

    private func importOne(_ pickerItem: PhotosPickerItem) async {
        // Looked up once, before anything else: it decides which bytes to ask for, what date to
        // file the item under, and whether there is a second half to send. Nil whenever the app has
        // no photo-library access, which is the ordinary case and not a failure.
        let device = deviceAttributes(for: pickerItem)

        if pickerItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            await importMovie(pickerItem, device: device)
            return
        }

        var name = "Photo"
        /// The RAW original written out of the photo library, if this is one. Deleted below whatever
        /// happens — a DNG is tens of megabytes and there may be a thousand of them in a run.
        var staged: URL?
        defer { staged.map { try? FileManager.default.removeItem(at: $0) } }

        do {
            let prepared: ImagePreparation.Prepared
            if let raw = await rawOriginal(for: device) {
                staged = raw.original.url
                prepared = raw.prepared
                name = ImagePreparation.fileName(
                    from: raw.original.originalFileName, extension: raw.original.fileExtension,
                    fallbackDate: device?.creationDate ?? prepared.captureDate ?? Date())
            } else {
                guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                    throw ImagePreparation.Failure.unreadable
                }
                prepared = try ImagePreparation.prepare(data, suggestedName: nil)
                name = ImagePreparation.fileName(
                    from: nil, extension: prepared.fileExtension,
                    fallbackDate: device?.creationDate ?? prepared.captureDate ?? Date())
            }
            currentName = name

            let outcome = try await pipeline.importPhoto(
                prepared, fileName: name, device: device,
                onProgress: { [weak self] fraction in self?.currentFraction = fraction }
            )
            if outcome.wasDuplicate { skipped += 1 }
        } catch is CancellationError {
            logger.debug("import cancelled")
        } catch {
            logger.error("import failed for \(name, privacy: .public): \(error, privacy: .public)")
            failures.append(Failure(name: name, message: error.localizedDescription))
        }
    }

    // MARK: - RAW

    /// The camera's own file for a RAW item, prepared for upload, or nil for everything else.
    ///
    /// Read as a *mapped* `Data`: a 60 MB DNG paged in as the encryptor walks it, rather than 60 MB
    /// resident before a byte has been sealed. The ciphertext beside it is still whole, which is why
    /// a RAW import is the heaviest single item this app handles and why the queue is serial.
    /// Every failure here falls through to the picker's rendering rather than propagating. The
    /// permission can have been revoked between the fetch and now, the asset can be an iCloud stub
    /// the device declined to download, the file can be unreadable — and in every one of those the
    /// right answer is the photograph in a lesser format, not no photograph at all.
    private func rawOriginal(for device: DeviceAsset?) async
        -> (original: DeviceOriginal, prepared: ImagePreparation.Prepared)? {
        guard let device, device.isRAW, let deviceLibrary else { return nil }
        do {
            guard let original = try await deviceLibrary.writeRAWOriginal(
                for: device.localIdentifier) else { return nil }
            do {
                let bytes = try Data(contentsOf: original.url, options: .mappedIfSafe)
                return (original, ImagePreparation.prepareOriginal(
                    bytes, mimeType: original.mimeType, fileExtension: original.fileExtension))
            } catch {
                try? FileManager.default.removeItem(at: original.url)
                throw error
            }
        } catch {
            logger.error("RAW original unavailable, falling back to the picker's rendering: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - The device's record of an item

    private func deviceAttributes(for pickerItem: PhotosPickerItem) -> DeviceAsset? {
        guard FeatureFlags.deviceLibraryAccess else { return nil }
        return deviceLibrary?.attributes(forLocalIdentifier: pickerItem.itemIdentifier)
    }

    // MARK: - Videos

    /// Imports a video without ever holding it.
    ///
    /// The difference from a photograph is one word — `URL` rather than `Data` — and it is the
    /// whole epic's memory story. `loadTransferable(type: Data.self)` on a 4K three-minute clip is
    /// half a gigabyte of `Data` before a single byte is encrypted; asking for the file instead
    /// leaves it on disk, and ``MediaContentService/upload(fileURL:fileName:mimeType:thumbnailBase64:onProgress:)``
    /// encrypts and sends it a chunk at a time from there.
    ///
    /// A video still uploads without the cover thumbnail a picture gets — decoding a poster frame is
    /// Epic 8 — so it shows a film symbol in the grid rather than a still.
    private func importMovie(_ pickerItem: PhotosPickerItem, device: DeviceAsset?) async {
        var name = "Video"
        do {
            guard let movie = try await pickerItem.loadTransferable(type: PickedMovie.self) else {
                throw ImagePreparation.Failure.unreadable
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }

            let type = pickerItem.supportedContentTypes.first { $0.conforms(to: .movie) }
            let ext = movie.url.pathExtension.isEmpty
                ? (type?.preferredFilenameExtension ?? "mov")
                : movie.url.pathExtension
            name = ImagePreparation.fileName(from: nil, extension: ext,
                                             fallbackDate: device?.creationDate ?? Date())
            currentName = name

            let outcome = try await pipeline.importVideo(
                at: movie.url, fileName: name,
                mimeType: type?.preferredMIMEType ?? "video/quicktime", device: device,
                onProgress: { [weak self] fraction in self?.currentFraction = fraction }
            )
            if outcome.wasDuplicate { skipped += 1 }
        } catch is CancellationError {
            logger.debug("import cancelled")
        } catch {
            logger.error("import failed for \(name, privacy: .public): \(error, privacy: .public)")
            failures.append(Failure(name: name, message: error.localizedDescription))
        }
    }

    // MARK: - Import history

    /// The shared record of what this device has uploaded. Exposed so Settings can explain it and
    /// the full-library importer can consult the same one — see ``ImportLedger``.
    var ledger: ImportLedger { pipeline.ledger }

    /// Forgets what has been imported, so the same photographs can be uploaded again.
    func forgetImportHistory() {
        Task { await pipeline.ledger.forget() }
    }

    var importedCount: Int { pipeline.ledger.count }
}

// MARK: - PickedMovie

/// A video from the picker, as a file rather than as bytes.
///
/// `PhotosPickerItem` will hand over a `Data` for anything, which is the wrong shape for a video and
/// the right shape for nothing else this app imports. A `FileRepresentation` gets the URL instead —
/// but the file it points at is the *picker's*, deleted the moment the transfer's closure returns,
/// so it has to be copied somewhere this app owns before that happens. Hence the copy: it is not
/// belt and braces, it is the only reason the URL is still valid when the upload reads it.
///
/// The caller deletes the copy when the upload finishes.
struct PickedMovie: Transferable {

    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("import", isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let copy = destination.appendingPathComponent(
                UUID().uuidString + "." + received.file.pathExtension)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
