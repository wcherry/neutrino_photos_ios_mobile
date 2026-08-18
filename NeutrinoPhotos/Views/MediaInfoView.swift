import SwiftUI

// MARK: - MediaInfoView

/// What is known about one item.
///
/// Deliberately shows only what the server actually holds. Dimensions and EXIF are written by a
/// background worker after upload, so a photograph imported a minute ago has none of them yet —
/// which the panel says, rather than showing a column of blanks.
struct MediaInfoView: View {

    let item: MediaItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    row("Name", item.fileName)
                    row("Type", item.mimeType)
                    row("Size", item.formattedSize)
                    if let dimensions = item.formattedDimensions {
                        row("Dimensions", dimensions)
                    }
                }

                Section("Dates") {
                    if let captureDate = item.captureDate {
                        row("Taken", Self.dateFormatter.string(from: captureDate))
                    }
                    row("Uploaded", Self.dateFormatter.string(from: item.createdAt))
                    row("Modified", Self.dateFormatter.string(from: item.updatedAt))
                }

                if let exif = item.metadata?.exif {
                    Section("Camera") {
                        if let make = exif.make { row("Make", make) }
                        if let model = exif.model { row("Model", model) }
                        if let summary = exif.exposureSummary { row("Exposure", summary) }
                        if let focal = exif.focalLength {
                            row("Focal length", String(format: "%.0f mm", focal))
                        }
                    }

                    if exif.hasLocation, let lat = exif.gpsLatitude, let lon = exif.gpsLongitude {
                        Section("Location") {
                            row("Coordinates", String(format: "%.5f, %.5f", lat, lon))
                        }
                    }
                } else {
                    Section {
                        Text("Camera details appear once the server has finished processing this item.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Identifiers") {
                    row("Photo", item.id)
                    row("Drive file", item.fileID)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                // Long values (a UUID, a full path-like name) wrap rather than being truncated:
                // an identifier that cannot be read whole is an identifier nobody can use.
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
