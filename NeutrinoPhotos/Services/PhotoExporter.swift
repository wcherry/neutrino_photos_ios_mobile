import Foundation

// MARK: - PhotoExporter

/// Decrypts photographs into plain files for the iOS Share Sheet — Epic 13's export.
///
/// The Share Sheet can only hand on files it can read, and what this account holds is ciphertext,
/// so each item is decrypted to a file of its own under a private temporary directory, named as the
/// user named it. What leaves is the original — the resolution and format that were uploaded,
/// including whatever EXIF it carries — because a photo sent to someone should be the photo, not a
/// screen-sized copy of it.
///
/// The directory is the exporter's alone and is deleted by ``cleanUp()`` once the Share Sheet
/// closes: decrypted photographs do not get to linger in `tmp` until the system gets round to it.
///
/// ## Partial failure
///
/// Ten photographs where one will not decrypt — its key is on another device, say — shares nine and
/// says one was left out. Failing the whole share over one item would leave the user with nothing
/// and no way to tell which photograph was the problem.
@MainActor
final class PhotoExporter {

    /// Where an item's bytes come from: decrypted bytes in memory, or a decrypted file already on
    /// disk (a video, which is never held in memory whole).
    enum Source {
        case data(Data)
        case file(URL)
    }

    typealias Fetch = @MainActor (MediaItem) async throws -> Source

    /// What an export produced.
    struct Result {
        let urls: [URL]
        /// Items that could not be exported, with the reason for the first of them.
        let failedCount: Int
        let firstError: String?
    }

    let directory: URL
    private let fetch: Fetch

    init(directory: URL = PhotoExporter.makeDirectory(), fetch: @escaping Fetch) {
        self.directory = directory
        self.fetch = fetch
    }

    nonisolated static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Share-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Exporting

    /// Writes each item to its own file, in order, calling `progress` with the count done so far.
    func export(_ items: [MediaItem], progress: (Int) -> Void = { _ in }) async -> Result {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var taken = Set<String>()
        var urls: [URL] = []
        var failed = 0
        var firstError: String?

        for (offset, item) in items.enumerated() {
            if Task.isCancelled { break }
            do {
                let name = Self.uniqueName(for: item.fileName, taken: &taken)
                let destination = directory.appendingPathComponent(name)
                switch try await fetch(item) {
                case .data(let data):
                    try data.write(to: destination, options: .completeFileProtection)
                case .file(let source):
                    // Copied, not moved: the source is the viewer's cache, which still wants it.
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                urls.append(destination)
            } catch where error.isCancellation {
                break
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
            progress(offset + 1)
        }
        return Result(urls: urls, failedCount: failed, firstError: firstError)
    }

    /// Removes every file this exporter wrote.
    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Naming

    /// The item's own file name, made safe for a path and unique within one share — two cameras
    /// both writing `IMG_0001.JPG` must not overwrite each other on the way out.
    static func uniqueName(for fileName: String, taken: inout Set<String>) -> String {
        let cleaned = fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty || cleaned.hasPrefix(".") ? "Photo" + cleaned : cleaned

        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var candidate = base
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}
