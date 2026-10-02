import SwiftUI

// MARK: - StorageView

/// The storage dashboard — Epic 12. What the account holds, what this device holds, and the two
/// ways to give space back: clearing the cache, and optimizing storage.
///
/// Both actions only ever remove *copies*. Every byte this device caches came from the account or
/// was confirmed uploaded to it before it was cached, so nothing on this screen can lose a
/// photograph — the footers say so, because that is the first thing anybody wonders before tapping.
struct StorageView: View {

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var content: MediaContentService
    @EnvironmentObject private var drive: PhotosDriveService

    @State private var device: MediaContentService.StorageBreakdown?
    @State private var confirmsOptimize = false
    @State private var confirmsClear = false
    @State private var lastResult: String?

    private var cloud: CloudStorageReport {
        CloudStorageReport(items: library.allItems, trash: library.trashItems, quota: drive.quota)
    }

    var body: some View {
        List {
            accountSection
            deviceSection
            actionsSection
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog("Remove full-size originals from this device?",
                            isPresented: $confirmsOptimize, titleVisibility: .visible) {
            Button("Optimize Storage") {
                let freed = content.optimizeStorage()
                lastResult = "Freed \(Self.format(freed))."
                Task { device = await content.storageBreakdown() }
            }
        } message: {
            Text("Previews and thumbnails stay, so your library still opens quickly. Originals "
                 + "download again when you zoom in, play a video or save a photo.")
        }
        .confirmationDialog("Clear the cache?", isPresented: $confirmsClear,
                            titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                let before = device?.cached ?? 0
                content.clearCache()
                lastResult = "Freed \(Self.format(before))."
                Task { device = await content.storageBreakdown() }
            }
        } message: {
            Text("Every cached photo, preview and thumbnail is removed from this device. Nothing "
                 + "is removed from your account; photos download again as you browse.")
        }
    }

    private func refresh() async {
        async let breakdown = content.storageBreakdown()
        await drive.loadQuota()
        if library.trashItems.isEmpty { await library.loadTrash() }
        device = await breakdown
    }

    // MARK: - Account

    private var accountSection: some View {
        let report = cloud
        let segments = [
            StorageSegment(label: "Photos", bytes: report.photos, color: .blue),
            StorageSegment(label: "Videos", bytes: report.videos, color: .purple),
            StorageSegment(label: "Other library items", bytes: report.otherLibrary, color: .teal),
            StorageSegment(label: "Recently Deleted", bytes: report.recentlyDeleted, color: .orange),
            StorageSegment(label: "Other Neutrino files", bytes: report.otherNeutrino ?? 0,
                           color: .gray),
        ].filter { $0.bytes > 0 }
        return Section {
            if let used = report.usedBytes {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.quotaBytes.map { "\(Self.format(used)) of \(Self.format($0)) used" }
                         ?? "\(Self.format(used)) used")
                        .font(.headline)
                    StorageBar(segments: segments,
                               total: max(report.quotaBytes ?? used, 1))
                }
                .padding(.vertical, 4)
            } else {
                Label("Account usage isn't available offline.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(segments) { segment in
                StorageLegendRow(segment: segment)
            }
            if let free = report.freeBytes {
                LabeledContent("Available", value: Self.format(free))
            }
        } header: {
            Text("In Your Account")
        } footer: {
            Text("Other Neutrino files are your documents and Drive files, plus the previews and "
                 + "Live Photo motion stored alongside your photos. Recently Deleted counts until "
                 + "it is emptied.")
        }
    }

    // MARK: - Device

    private var deviceSection: some View {
        let breakdown = device
        let segments = [
            StorageSegment(label: "Full-size originals", bytes: breakdown?.originals ?? 0, color: .blue),
            StorageSegment(label: "Previews", bytes: breakdown?.previews ?? 0, color: .indigo),
            StorageSegment(label: "Grid thumbnails", bytes: breakdown?.thumbnails ?? 0, color: .teal),
            StorageSegment(label: "Library index", bytes: breakdown?.database ?? 0, color: .gray),
        ]
        return Section {
            if let breakdown {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Self.format(breakdown.total)) on this device")
                        .font(.headline)
                    StorageBar(segments: segments.filter { $0.bytes > 0 },
                               total: max(breakdown.total, 1))
                }
                .padding(.vertical, 4)
                ForEach(segments) { segment in
                    StorageLegendRow(segment: segment)
                }
                LabeledContent("Photo cache limit", value: Self.format(breakdown.cacheCapacity))
            } else {
                ProgressView()
            }
        } header: {
            Text("On This Device")
        } footer: {
            Text("Photos you open are kept on this device so the next look is instant. When the "
                 + "cache reaches its limit, the photos you looked at longest ago are removed "
                 + "first. The library index is what lets the timeline and search work offline.")
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            Button("Optimize Storage") { confirmsOptimize = true }
                .disabled((device?.originals ?? 0) == 0)
            Button("Clear Cache", role: .destructive) { confirmsClear = true }
                .disabled((device?.cached ?? 0) == 0)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let lastResult {
                    Text(lastResult)
                        .foregroundStyle(.primary)
                }
                Text("Optimize removes full-size originals and keeps previews. Clear removes "
                     + "everything cached. Neither removes anything from your account — every "
                     + "cached file is a copy of one that is already there.")
            }
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Pieces

private struct StorageSegment: Identifiable {
    let label: String
    let bytes: Int64
    let color: Color
    var id: String { label }
}

/// One bar, split by segment in proportion to `total`. The unfilled remainder is free space.
private struct StorageBar: View {

    let segments: [StorageSegment]
    let total: Int64

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    segment.color
                        .frame(width: max(2, proxy.size.width * CGFloat(segment.bytes) / CGFloat(total)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: 14)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private struct StorageLegendRow: View {

    let segment: StorageSegment

    var body: some View {
        HStack {
            Circle()
                .fill(segment.color)
                .frame(width: 10, height: 10)
            Text(segment.label)
            Spacer()
            Text(StorageView.format(segment.bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}
