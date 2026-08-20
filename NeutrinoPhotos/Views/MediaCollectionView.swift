import SwiftUI

// MARK: - MediaCollectionView

/// A plain grid over a fixed list — Favorites, Recently Added, Archive, Recently Deleted.
///
/// Ungrouped on purpose: these are small, hand-made or recent sets where a run of date headings
/// would be more chrome than content. The timeline is where grouping earns its place.
struct MediaCollectionView: View {

    // MARK: - Collection

    enum Collection {
        case favorites
        case recentlyAdded
        case archive
        case trash

        var title: String {
            switch self {
            case .favorites:     return "Favorites"
            case .recentlyAdded: return "Recently Added"
            case .archive:       return "Archive"
            case .trash:         return "Recently Deleted"
            }
        }

        var symbolName: String {
            switch self {
            case .favorites:     return "heart"
            case .recentlyAdded: return "clock"
            case .archive:       return "archivebox"
            case .trash:         return "trash"
            }
        }

        var emptyMessage: String {
            switch self {
            case .favorites:
                return "Photos you favorite appear here."
            case .recentlyAdded:
                return "Photos added to your library in the last 30 days appear here."
            case .archive:
                return "Archived photos are hidden from the library but kept in your account."
            case .trash:
                return "Deleted photos stay here for \(TrashRetention.days) days."
            }
        }
    }

    let collection: Collection

    @EnvironmentObject private var library: PhotoLibraryService
    /// Held only to hand on to the viewer, which opens on a cell's cover thumbnail.
    @EnvironmentObject private var thumbnails: ThumbnailCache
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary

    @State private var viewerStart: MediaItem?
    @State private var showsEmptyConfirmation = false
    @State private var deletingPermanently: MediaItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    // MARK: - Body

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    if collection == .trash {
                        retentionNote
                    }
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(items) { item in
                            cell(for: item)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if collection == .trash && !items.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Empty", role: .destructive) { showsEmptyConfirmation = true }
                }
            }
        }
        .confirmationDialog("Delete all \(items.count) item(s) permanently?",
                            isPresented: $showsEmptyConfirmation, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { library.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The files are removed from your Neutrino storage.")
        }
        .confirmationDialog("Delete this photo permanently?",
                            isPresented: Binding(get: { deletingPermanently != nil },
                                                 set: { if !$0 { deletingPermanently = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                if let item = deletingPermanently { library.deletePermanently(id: item.id) }
                deletingPermanently = nil
            }
            Button("Cancel", role: .cancel) { deletingPermanently = nil }
        } message: {
            Text("This cannot be undone. The file is removed from your Neutrino storage.")
        }
        .task { if collection == .trash { await library.loadTrash() } }
        .fullScreenCover(item: $viewerStart) { start in
            PhotoDetailView(items: items, initialID: start.id)
                .environmentObject(thumbnails)
                .environmentObject(deviceLibrary)
        }
    }

    // MARK: - Contents

    private var items: [MediaItem] {
        switch collection {
        case .favorites:     return library.favorites
        case .recentlyAdded: return library.recentlyAdded()
        case .archive:       return library.archived
        case .trash:         return library.trashItems
        }
    }

    /// The one place the retention promise is stated in full, above the grid rather than repeated
    /// on every cell. The cells carry the countdown; this says what the countdown is counting to.
    private var retentionNote: some View {
        Text("Items are kept for \(TrashRetention.days) days after deletion.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func cell(for item: MediaItem) -> some View {
        if collection == .trash {
            // A trashed item cannot be opened: the viewer's actions (favorite, archive, add to
            // album) do not apply to something already deleted, and restoring or finishing the job
            // are the only two things worth doing to it.
            PhotoThumbnailView(item: item, showsBadges: false)
                .overlay(alignment: .bottomLeading) {
                    if let caption = TrashRetention.caption(for: item) {
                        Text(caption)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        library.restore(id: item.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .contextMenu {
                    Button {
                        library.restore(id: item.id)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        deletingPermanently = item
                    } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                }
        } else {
            Button {
                viewerStart = item
            } label: {
                PhotoThumbnailView(item: item)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: collection.symbolName)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(collection.emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
