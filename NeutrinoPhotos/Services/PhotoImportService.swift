import CryptoKit
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os.log

// MARK: - PhotoImportService

/// Imports items chosen in the system photo picker: prepare, encrypt, upload, register.
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

    private let content: MediaContentService
    private let library: PhotoLibraryService
    private let settings: AppSettings
    private let monitor: NetworkMonitor

    /// Consulted only to explain *why* there is no key — "unlock" and "import a key file" are very
    /// different instructions and guessing wrong sends the user to the wrong screen. The precondition
    /// itself is still the Keychain: a key that got here by any route is a key that works.
    private weak var vault: KeyVaultService?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "PhotoImportService")

    private var task: Task<Void, Never>?

    /// SHA-256 of the bytes this device has already uploaded.
    ///
    /// Device-local by necessity: the server stores ciphertext, so it cannot compare two uploads
    /// for sameness, and nothing in the API answers "do you already have this picture?". What this
    /// does catch is the common case — the same photograph picked twice, or a second import run
    /// over a selection that overlaps the first.
    private var fingerprints: Set<String>

    private static let fingerprintsKey = "import.fingerprints"

    private let defaults: UserDefaults

    // MARK: - Init

    init(content: MediaContentService, library: PhotoLibraryService,
         settings: AppSettings, monitor: NetworkMonitor,
         vault: KeyVaultService? = nil,
         defaults: UserDefaults = .standard) {
        self.content = content
        self.library = library
        self.settings = settings
        self.monitor = monitor
        self.vault = vault
        self.defaults = defaults
        self.fingerprints = Set(defaults.stringArray(forKey: Self.fingerprintsKey) ?? [])
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
            self.persistFingerprints()
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
        if pickerItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            await importMovie(pickerItem)
            return
        }

        var name = "Photo"
        do {
            guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                throw ImagePreparation.Failure.unreadable
            }

            let prepared = try ImagePreparation.prepare(data, suggestedName: nil)
            name = ImagePreparation.fileName(from: nil, extension: prepared.fileExtension,
                                             fallbackDate: prepared.captureDate ?? Date())
            currentName = name

            let bytes = prepared.data
            let fingerprint = await Task.detached(priority: .userInitiated) {
                Self.fingerprint(of: bytes)
            }.value
            guard !fingerprints.contains(fingerprint) else {
                skipped += 1
                logger.debug("skipped a duplicate: \(name, privacy: .public)")
                return
            }

            let fileID = try await content.upload(
                data: prepared.data, fileName: name, mimeType: prepared.mimeType,
                thumbnailBase64: prepared.thumbnailBase64,
                onProgress: { [weak self] fraction in self?.currentFraction = fraction }
            )
            try await library.register(fileID: fileID, captureDate: prepared.captureDate)
            fingerprints.insert(fingerprint)
            logger.debug("imported \(name, privacy: .public) as \(fileID, privacy: .public)")
        } catch is CancellationError {
            logger.debug("import cancelled")
        } catch {
            logger.error("import failed for \(name, privacy: .public): \(error, privacy: .public)")
            failures.append(Failure(name: name, message: error.localizedDescription))
        }
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
    private func importMovie(_ pickerItem: PhotosPickerItem) async {
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
            name = ImagePreparation.fileName(from: nil, extension: ext)
            currentName = name

            let url = movie.url
            let fingerprint = try await Task.detached(priority: .userInitiated) {
                try Self.fingerprint(ofFileAt: url)
            }.value
            guard !fingerprints.contains(fingerprint) else {
                skipped += 1
                logger.debug("skipped a duplicate video: \(name, privacy: .public)")
                return
            }

            let fileID = try await content.upload(
                fileURL: movie.url, fileName: name,
                mimeType: type?.preferredMIMEType ?? "video/quicktime",
                thumbnailBase64: nil,
                onProgress: { [weak self] fraction in self?.currentFraction = fraction }
            )
            try await library.register(fileID: fileID, captureDate: nil)
            fingerprints.insert(fingerprint)
            logger.debug("imported \(name, privacy: .public) as \(fileID, privacy: .public)")
        } catch is CancellationError {
            logger.debug("import cancelled")
        } catch {
            logger.error("import failed for \(name, privacy: .public): \(error, privacy: .public)")
            failures.append(Failure(name: name, message: error.localizedDescription))
        }
    }

    // MARK: - Fingerprints

    nonisolated private static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same hash, computed a block at a time — a video cannot be read into memory to be
    /// fingerprinted any more than it can be to be encrypted.
    ///
    /// `nonisolated` so it can be called off the main actor, which is where hashing half a gigabyte
    /// belongs. `importMovie` awaits it on a detached task for that reason.
    nonisolated static func fingerprint(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func persistFingerprints() {
        defaults.set(Array(fingerprints), forKey: Self.fingerprintsKey)
    }

    /// Forgets what has been imported, so the same photographs can be uploaded again. Offered in
    /// Settings beside the duplicate explanation, because the record is a convenience rather than
    /// a constraint the user should be stuck with.
    func forgetImportHistory() {
        fingerprints = []
        defaults.removeObject(forKey: Self.fingerprintsKey)
    }

    var importedCount: Int { fingerprints.count }
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
