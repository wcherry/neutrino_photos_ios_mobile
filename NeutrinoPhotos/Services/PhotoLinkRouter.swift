import Foundation
import os.log
import NeutrinoCore

// MARK: - PhotoLinkRouter

/// Holds the photograph an inbound Universal Link asked for until the app can open it — Epic 13.
///
/// `https://www.getneutrino.app/open/photo/<file id>` names a photo by its **Drive file id**, as
/// every `/open/<kind>/<id>` link does: the id the web app and the other Neutrino apps already
/// have in hand. Only the id travels — never the photograph and never a key — and this device
/// opens it from the library it already holds, so permissions stay with the server and a link to
/// somebody else's photo opens nothing.
///
/// A link can land at any moment, including a cold launch onto the sign-in screen. The router just
/// remembers the destination; ``ContentView`` opens it once the library can answer.
///
/// ## Why `photo` is parsed here and not in `NeutrinoAppLink`
///
/// The shared vocabulary in `NeutrinoCore` has no `photo` kind yet, and adding a case to that
/// public enum breaks every exhaustive `switch` over it in the other six apps. This parses the one
/// path this app owns, with the same rules (`https`, a Neutrino host, `/open/<kind>/<id>`), until
/// the kind is added there alongside the web app's `photo` route and the
/// `apple-app-site-association` entry that makes iOS deliver these links here at all — see
/// `neutrino/agent_docs/photo-sharing.md`.
@MainActor
final class PhotoLinkRouter: ObservableObject {

    /// The kind segment this app owns.
    static let kind = "photo"

    /// The Drive file id waiting to be opened, if any.
    @Published private(set) var pendingFileID: String?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "PhotoLinkRouter")

    init(pendingFileID: String? = nil) {
        self.pendingFileID = pendingFileID
    }

    /// Records `url` if it is a photo link. False for anything else — a key file, another app's
    /// link — so the caller can try its other handlers.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let fileID = Self.fileID(from: url) else { return false }
        logger.debug("accepted photo link file=\(fileID, privacy: .public)")
        pendingFileID = fileID
        return true
    }

    /// The pending id, cleared, so a photo already being opened is not opened twice.
    func consume() -> String? {
        defer { pendingFileID = nil }
        return pendingFileID
    }

    // MARK: - Parsing

    /// The file id in a `/open/photo/<id>` link on a Neutrino host, or nil. A malformed link is
    /// dropped rather than guessed at: the only thing a guess can do is open the wrong photo.
    static func fileID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else { return nil }
        let host = components.host?.lowercased() ?? ""
        guard host == NeutrinoAppLink.host || NeutrinoAppLink.alternateHosts.contains(host) else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count == 3,
              segments[0] == NeutrinoAppLink.pathPrefix,
              segments[1] == kind else { return nil }
        let id = segments[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// The link that opens `fileID` here — or in the web app, on a device without this one.
    static func url(forFileID fileID: String) -> URL? {
        let id = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = NeutrinoAppLink.host
        components.path = "/\(NeutrinoAppLink.pathPrefix)/\(kind)/\(id)"
        return components.url
    }
}
