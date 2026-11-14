import SwiftUI
import UIKit

// MARK: - ShareTarget

/// Photographs on their way to the Share Sheet. Its own identity, as `AlbumTarget` has in the
/// library, so `sheet(item:)` can present it and a library refresh cannot change what is being
/// shared mid-export.
struct ShareTarget: Identifiable {
    let id = UUID()
    let items: [MediaItem]
}

// MARK: - ShareExportSheet

/// Decrypts the chosen photographs, then hands them to the iOS Share Sheet.
///
/// Presented as a sheet of its own so the wait is visible: decrypting ten originals is a few
/// seconds, and a Share Sheet that took that long to appear would look like a tap that missed.
/// Once the files are ready the Share Sheet replaces the progress in place, and when it closes the
/// decrypted files are deleted — see ``PhotoExporter``.
struct ShareExportSheet: View {

    let items: [MediaItem]

    @EnvironmentObject private var content: MediaContentService
    @Environment(\.dismiss) private var dismiss

    @State private var exporter: PhotoExporter?
    @State private var done = 0
    @State private var result: PhotoExporter.Result?

    var body: some View {
        Group {
            if let result, !result.urls.isEmpty {
                VStack(spacing: 0) {
                    if result.failedCount > 0 {
                        Label(result.failedCount == 1
                              ? "1 item couldn't be prepared and was left out."
                              : "\(result.failedCount) items couldn't be prepared and were left out.",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(12)
                    }
                    ActivityView(items: result.urls) {
                        finish()
                    }
                    .ignoresSafeArea()
                }
            } else if let result {
                failure(result)
            } else {
                progress
            }
        }
        .task { await export() }
        .onDisappear { exporter?.cleanUp() }
    }

    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(done), total: Double(max(items.count, 1)))
                .frame(maxWidth: 240)
            Text(items.count == 1 ? "Preparing photo…" : "Preparing \(done) of \(items.count)…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { finish() }
        }
        .padding(32)
        .presentationDetents([.height(200)])
    }

    private func failure(_ result: PhotoExporter.Result) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(items.count == 1 ? "This photo couldn't be prepared." : "These photos couldn't be prepared.")
                .font(.headline)
            if let reason = result.firstError {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("OK") { finish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .presentationDetents([.medium])
    }

    private func export() async {
        let content = content
        let exporter = PhotoExporter { item in
            // A video is decrypted to a file by the content service already; reading it into
            // memory just to write it out again would hold a whole film in RAM.
            if item.kind == .video {
                return .file(try await content.localURL(for: item))
            }
            return .data(try await content.originalData(for: item))
        }
        self.exporter = exporter
        let result = await exporter.export(items) { done = $0 }
        guard !Task.isCancelled else { return }
        self.result = result
    }

    private func finish() {
        exporter?.cleanUp()
        dismiss()
    }
}

// MARK: - ActivityView

/// `UIActivityViewController`, for SwiftUI. iOS 16's `ShareLink` wants the items up front, and these
/// do not exist until they have been decrypted.
private struct ActivityView: UIViewControllerRepresentable {

    let items: [URL]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
