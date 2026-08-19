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
        var name = "Photo"
        do {
            guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                throw ImagePreparation.Failure.unreadable
            }

            let prepared = try prepare(data, for: pickerItem)
            name = ImagePreparation.fileName(from: nil, extension: prepared.fileExtension,
                                             fallbackDate: prepared.captureDate ?? Date())
            currentName = name

            let fingerprint = Self.fingerprint(of: prepared.data)
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

    /// Photographs go through ``ImagePreparation``; videos are stored exactly as they came.
    ///
    /// There is no transcoding and no poster frame for a video yet, so it uploads without the
    /// preview a picture gets and shows a film icon in the grid until this app can decode a frame
    /// from one.
    private func prepare(_ data: Data, for pickerItem: PhotosPickerItem) throws
    -> ImagePreparation.Prepared {
        let movieType = pickerItem.supportedContentTypes.first { $0.conforms(to: .movie) }
        guard let movieType else {
            return try ImagePreparation.prepare(data, suggestedName: nil)
        }
        return ImagePreparation.Prepared(
            data: data,
            mimeType: movieType.preferredMIMEType ?? "video/quicktime",
            fileExtension: movieType.preferredFilenameExtension ?? "mov",
            thumbnailBase64: nil,
            captureDate: nil
        )
    }

    // MARK: - Fingerprints

    private static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
