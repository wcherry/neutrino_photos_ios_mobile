import PhotosUI
import SwiftUI

// MARK: - LibraryView

/// The timeline: every photograph and video in the library, grouped by day, month, or year.
struct LibraryView: View {

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var importer: PhotoImportService

    /// What the picker handed back. Cleared as soon as the import starts so picking the same
    /// photographs twice in a row still fires — an unchanged selection is not a changed binding.
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var viewerStart: MediaItem?
    @State private var hasLoaded = false

    // MARK: - Body

    var body: some View {
        Group {
            if items.isEmpty && !library.isLoading {
                emptyState
            } else {
                timeline
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .refreshable { await library.load() }
        .task {
            // Once per appearance rather than on every navigation: `refreshable` and the import
            // completion handler cover the cases where the library has actually changed.
            guard !hasLoaded else { return }
            hasLoaded = true
            await library.load()
        }
        .onChange(of: pickerSelection) { selection in
            guard !selection.isEmpty else { return }
            importer.startImport(selection)
            pickerSelection = []
        }
        .fullScreenCover(item: $viewerStart) { start in
            PhotoDetailView(items: items, initialID: start.id)
        }
    }

    // MARK: - Timeline

    private var items: [MediaItem] {
        library.timeline(showingArchived: settings.showArchived)
    }

    private var sections: [TimelineSection] {
        TimelineSection.sections(from: items, grouping: settings.timelineGrouping)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        grid(for: section)
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func grid(for section: TimelineSection) -> some View {
        // Two points of spacing rather than none: a grid of edge-to-edge photographs reads as one
        // texture, and a hairline is enough to tell where each picture ends.
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(section.items) { item in
                Button {
                    viewerStart = item
                } label: {
                    PhotoThumbnailView(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu { contextMenu(for: item) }
            }
        }
        .padding(.horizontal, 2)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2),
              count: settings.timelineGrouping.columnCount)
    }

    private func sectionHeader(_ section: TimelineSection) -> some View {
        HStack {
            Text(section.title)
                .font(.headline)
            Spacer()
            Text("\(section.items.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Opaque: a pinned header over scrolling photographs is unreadable without it.
        .background(.bar)
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        if FeatureFlags.favorites {
            Button {
                library.setStarred(id: item.id, isStarred: !item.isStarred)
            } label: {
                Label(item.isStarred ? "Remove from Favorites" : "Favorite",
                      systemImage: item.isStarred ? "heart.slash" : "heart")
            }
        }
        if FeatureFlags.archive {
            Button {
                library.setArchived(id: item.id, isArchived: !item.isArchived)
            } label: {
                Label(item.isArchived ? "Unarchive" : "Archive",
                      systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
        }
        if FeatureFlags.trash {
            Button(role: .destructive) {
                library.trash(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Menu {
                Picker("Group by", selection: $settings.timelineGrouping) {
                    ForEach(TimelineGrouping.allCases) { grouping in
                        Text(grouping.displayName).tag(grouping)
                    }
                }
                if FeatureFlags.archive {
                    Toggle("Show Archived", isOn: $settings.showArchived)
                }
            } label: {
                Label("View", systemImage: "square.grid.2x2")
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            if FeatureFlags.importFromPhotos {
                PhotosPicker(selection: $pickerSelection,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    Label("Import", systemImage: "square.and.arrow.up")
                }
                .disabled(importer.isImporting)
            }
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if importer.isImporting {
                importProgress
            }
            if let reason = importer.blockedReason {
                banner(reason, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if !importer.failures.isEmpty {
                banner("\(importer.failures.count) item(s) failed to upload.",
                       systemImage: "exclamationmark.circle", tint: .red)
            }
            if !KeyImportService.hasStoredKeys() {
                NavigationLink {
                    KeyImportView()
                } label: {
                    banner("Import your encryption key to open and upload photos.",
                           systemImage: "key", tint: .accentColor)
                }
                .buttonStyle(.plain)
            }
            if let error = library.error {
                banner(error, systemImage: "wifi.exclamationmark", tint: .red)
            }
        }
    }

    private var importProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Uploading \(importer.completed + 1) of \(importer.total)")
                    .font(.footnote.weight(.medium))
                Spacer()
                Button("Cancel") { importer.cancel() }
                    .font(.footnote)
            }
            // Two bars would be noise; the item's own byte progress is the one that moves, and the
            // count above says where the run is.
            ProgressView(value: importer.currentFraction)
            if let name = importer.currentName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Photos Yet")
                .font(.title3.weight(.semibold))
            Text("Import from your photo library and everything is encrypted on this device before it leaves it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if FeatureFlags.importFromPhotos {
                PhotosPicker(selection: $pickerSelection,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    Text("Import Photos")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
