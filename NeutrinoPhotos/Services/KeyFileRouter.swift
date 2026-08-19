import Foundation
import os.log

// MARK: - KeyFileRouter

/// Consumes a `.json` key file the system hands the app — AirDropped, tapped in Files, or opened
/// from Mail.
///
/// The app declares `com.neutrino.photos.keyfile` (conforming to `public.json`) in `project.yml`, so
/// iOS offers Neutrino Photos in the share sheet for one. Declaring the type is only half of it: a
/// URL still arrives at `onOpenURL` and is dropped unless something consumes it, which is what this
/// is. It parks the parsed result and the UI presents it — routing and importing stay separate so
/// the decision of *where* to show the outcome belongs to the view layer.
///
/// The file is validated before anything is stored, so a mismatched pair is reported here rather
/// than discovered later as a photograph nobody can decrypt.
@MainActor
final class KeyFileRouter: ObservableObject {

    // MARK: - Outcome

    enum Outcome: Equatable {
        case imported(String)
        case failed(String)
    }

    // MARK: - Published state

    /// Set when a key file has been opened and the user has not dismissed the result yet.
    @Published var outcome: Outcome?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "KeyFileRouter")

    // MARK: - Routing

    /// True when `url` is something this router should consume, so `onOpenURL` can leave anything
    /// else — a Universal Link, say — for whatever handles it next.
    static func canHandle(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "json"
    }

    /// Imports the key file at `url` and records what happened.
    ///
    /// - Returns: true when the URL was consumed, whether or not the import succeeded. A malformed
    ///   key file is still this router's business — dropping it would leave the user tapping a file
    ///   that appears to do nothing.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard Self.canHandle(url) else { return false }

        // A file handed over by another app arrives as a security-scoped URL. Without this the read
        // fails with a permission error that reads to the user like a corrupt file.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        do {
            let bundle = try KeyImportService.importKey(from: try Data(contentsOf: url))
            KeyImportService.storeKeys(bundle)
            outcome = .imported(url.lastPathComponent)
            logger.info("imported a key file opened from outside the app")
        } catch {
            // The file name, never the contents: a key file's bytes are the private key.
            outcome = .failed(error.localizedDescription)
            logger.error("key file import failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}
