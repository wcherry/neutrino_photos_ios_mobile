import SwiftUI

// MARK: - LibraryImportView

/// The full-library import: what is there, what has been done, and the one button that matters.
///
/// The screen is deliberately a progress report rather than a control panel. A user importing
/// twenty thousand photographs wants to know three things — how far along it is, when it will be
/// done, and that stopping is safe — and every one of the controls here answers one of those.
struct LibraryImportView: View {

    @EnvironmentObject private var importer: LibraryImportService
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary
    @EnvironmentObject private var ledger: ImportLedger
    @EnvironmentObject private var settings: AppSettings

    @State private var showsCancelConfirmation = false

    /// Redraws the ETA and the elapsed-time line without anything else having changed. One second
    /// is the resolution the numbers are shown at; anything faster would be a busier view for a
    /// figure that is rounded to the minute anyway.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Written by the timer and read by nothing: changing it is what invalidates the body, and the
    /// figures themselves are computed from `Date()` where they are drawn.
    @State private var now = Date()

    // MARK: - Body

    var body: some View {
        List {
            statusSection
            if !importer.counts.isEmpty {
                progressSection
            }
            if !importer.failures.isEmpty {
                failuresSection
            }
            albumsSection
            explanationSection
        }
        .navigationTitle("Import Library")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { now = $0 }
        .task {
            deviceLibrary.refresh()
            deviceLibrary.refreshItemCount()
        }
        .confirmationDialog("Discard this import queue?", isPresented: $showsCancelConfirmation,
                            titleVisibility: .visible) {
            Button("Discard Queue", role: .destructive) {
                Task { await importer.cancelRun() }
            }
        } message: {
            Text("Photos already imported stay in your library. The rest can be queued again by scanning.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("On this device",
                           value: deviceLibrary.itemCount.map(String.init) ?? "—")
            LabeledContent("Already imported", value: "\(ledger.count)")
            if let scanned = importer.lastScannedAt {
                LabeledContent("Last scan", value: scanned.formatted(date: .abbreviated,
                                                                     time: .shortened))
            }
            primaryAction
        } header: {
            Text("Your Photo Library")
        } footer: {
            Text(statusFooter)
        }
    }

    /// One button, whose meaning follows the phase. Two buttons that are each right half the time
    /// is how somebody taps Start on a run that is already going.
    @ViewBuilder
    private var primaryAction: some View {
        switch importer.phase {
        case .idle, .finished:
            Button(importer.counts.hasWorkLeft ? "Resume Import" : "Scan and Import") {
                Task { await importer.scanAndStart() }
            }
            .disabled(!deviceLibrary.access.isUsable)
        case .scanning(let found):
            HStack {
                ProgressView()
                Text(found == 0 ? "Scanning your library…" : "Scanning… \(found) found")
                    .foregroundStyle(.secondary)
            }
        case .running, .waiting:
            Button("Pause") { importer.pause() }
        case .paused, .interrupted:
            Button(importer.counts.hasWorkLeft ? "Resume Import" : "Scan and Import") {
                if importer.counts.hasWorkLeft {
                    importer.start()
                } else {
                    Task { await importer.scanAndStart() }
                }
            }
            .disabled(!deviceLibrary.access.isUsable)
        }
    }

    private var statusFooter: String {
        switch importer.phase {
        case .interrupted:
            return """
                   An import was interrupted with \(importer.counts.pending) item(s) left. Nothing \
                   was lost — resuming carries on from where it stopped.
                   """
        case .paused(let reason?):
            return reason
        case .waiting(let reason):
            return reason
        case .finished where importer.counts.isEmpty:
            return "Everything on this device is already in your library."
        case .finished:
            return "Import finished. Run it again any time — only new photos are uploaded."
        default:
            if !deviceLibrary.access.isUsable {
                return """
                       Importing your whole library needs photo-library access. Grant it in \
                       Settings › This Device's Photos.
                       """
            }
            return """
                   Scanning finds everything this device holds and queues what isn't in your \
                   account yet. Photos you've already imported are skipped.
                   """
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: importer.counts.fraction)
                HStack {
                    Text("\(importer.counts.finished) of \(importer.counts.total)")
                        .font(.footnote.weight(.medium))
                    Spacer()
                    if let remaining = ImportRate.formatted(remaining: importer.estimatedTimeRemaining) {
                        Text("about \(remaining) left")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let name = importer.currentName, importer.isBusy {
                    ProgressView(value: importer.currentFraction)
                        .tint(.secondary)
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)

            LabeledContent("Imported", value: "\(importer.counts.done)")
            if importer.counts.skipped > 0 {
                LabeledContent("Already in your library", value: "\(importer.counts.skipped)")
            }
            if importer.counts.pending > 0 {
                LabeledContent("Remaining", value: "\(importer.counts.pending)")
            }
            LabeledContent("Data", value: bytesDescription)
            if importer.counts.total > importer.counts.finished {
                Button("Discard Queue", role: .destructive) { showsCancelConfirmation = true }
            }
        } header: {
            Text("This Run")
        } footer: {
            Text("""
                 Sizes are estimated from each item's dimensions — the Photos framework doesn't \
                 publish a file's byte count — so the total moves a little as real files go past.
                 """)
        }
    }

    private var bytesDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let done = formatter.string(fromByteCount: importer.counts.finishedBytes)
        let total = formatter.string(fromByteCount: importer.counts.totalBytes)
        return "\(done) of \(total)"
    }

    // MARK: - Failures

    private var failuresSection: some View {
        Section {
            ForEach(importer.failures) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.isVideo ? "Video" : "Photo")
                        .font(.subheadline)
                    Text(item.lastError ?? "Unknown error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Retry Failed Items") {
                Task { await importer.retryFailed() }
            }
        } header: {
            Text("\(importer.counts.failed) Failed")
        } footer: {
            Text("""
                 A failed item is retried a few times on its own before it lands here, and the rest \
                 of the queue keeps going around it. Nothing on your device was changed.
                 """)
        }
    }

    // MARK: - Albums

    private var albumsSection: some View {
        Section {
            LabeledContent("Albums", value: FeatureFlags.albums ? "Recreated" : "Not in this build")
            Toggle("Upload over Wi-Fi only", isOn: $settings.wifiOnlyUploads)
        } header: {
            Text("What Comes Across")
        } footer: {
            Text("""
                 Your albums are recreated by name and their photos added to them. Smart albums \
                 (Recently Added, Selfies, Screenshots) are not — they're views over your library \
                 rather than albums you made, and copies of them would never update again. Hidden \
                 items are never imported.
                 """)
        }
    }

    // MARK: - Explanation

    private var explanationSection: some View {
        Section {
            row("arrow.triangle.2.circlepath", "Running it twice is safe", """
                Every item this device has uploaded is remembered, by both its identity in Apple \
                Photos and a hash of its bytes. A second run imports only what's new.
                """)
            row("pause.circle", "Stopping is safe", """
                The queue is stored on this device. Pausing, backgrounding, or force-quitting the \
                app loses at most the item in flight, and resuming carries on from there.
                """)
            row("bolt.slash", "It needs the app open", """
                Uploading in the background, without opening the app, is automatic backup — that's \
                not in this build yet.
                """)
            row("thermometer.medium", "It backs off when your phone gets warm", """
                A sustained import is the workload that heats a phone. This one slows down on its \
                own rather than pushing it into throttling.
                """)
        } header: {
            Text("How This Works")
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
