import SwiftUI

// MARK: - MediaInfoView

/// What is known about one item.
///
/// Deliberately shows only what the server actually holds. Dimensions and EXIF are written by a
/// background worker after upload, so a photograph imported a minute ago has none of them yet —
/// which the panel says, rather than showing a column of blanks.
struct MediaInfoView: View {

    let item: MediaItem

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// "Live Photo", "RAW", "Panorama" — what Apple Photos would call this, where it would call it
    /// anything. Read off ``MediaDeviceFacts``, so it is present only for items imported by a device
    /// that could see the library they came from.
    private var specialKindDescription: String? {
        guard let facts = item.metadata?.device else { return nil }
        var parts: [String] = []
        if facts.isLivePhoto == true {
            // Named for what is actually true today: the motion is stored, and the viewer does not
            // play it yet. Claiming "Live Photo" flat would promise a press-and-hold that does
            // nothing.
            parts.append(item.liveVideoFileID == nil
                         ? "Live Photo (motion not stored)"
                         : "Live Photo (motion stored)")
        }
        if facts.isRAW == true { parts.append("RAW") }
        for subtype in facts.subtypes ?? [] where subtype != "live" {
            parts.append(Self.subtypeNames[subtype] ?? subtype)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static let subtypeNames: [String: String] = [
        "panorama": "Panorama", "hdr": "HDR", "screenshot": "Screenshot",
        "portrait": "Portrait", "slowMotion": "Slow-motion", "timelapse": "Time-lapse",
    ]

    private var publishesLocation: Bool { settings.publishesLocationMetadata }

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
                    if let kind = specialKindDescription {
                        row("Kind", kind)
                    }
                }

                Section("Dates") {
                    if let captureDate = item.captureDate {
                        row("Taken", Self.dateFormatter.string(from: captureDate))
                    }
                    row("Uploaded", Self.dateFormatter.string(from: item.createdAt))
                    row("Modified", Self.dateFormatter.string(from: item.updatedAt))
                }

                if let exif = item.metadata?.exif, !exif.isEmpty {
                    Section("Camera") {
                        if let make = exif.make { row("Make", make) }
                        if let model = exif.model { row("Model", model) }
                        if let lens = exif.lensModel { row("Lens", lens) }
                        if let summary = exif.exposureSummary { row("Exposure", summary) }
                        if let focal = exif.focalLength {
                            row("Focal length", String(format: "%.0f mm", focal))
                        }
                    }

                    if exif.hasLocation, let lat = exif.gpsLatitude, let lon = exif.gpsLongitude {
                        Section {
                            row("Coordinates", String(format: "%.5f, %.5f", lat, lon))
                        } header: {
                            Text("Location")
                        } footer: {
                            // The one place the app can say which side of the line this photograph
                            // fell on — see `AppSettings.publishesLocationMetadata`.
                            Text(publishesLocation
                                 ? "Sent to Neutrino with this photo's index, so it appears on your other devices."
                                 : "Kept on this device only. Turn on Settings › Privacy › Include location in cloud metadata to sync it.")
                        }
                    }
                } else {
                    Section {
                        Text(item.kind == .video
                             ? "Videos carry no camera details in this build."
                             : "Camera details are read on the device that imported a photo. This one was uploaded elsewhere, or hasn't been processed yet.")
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
