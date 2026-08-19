import SwiftUI

// MARK: - MediaCollectionView

/// A plain grid over a fixed list — Favorites, Archive, Recently Deleted.
///
/// Ungrouped on purpose: these are small, hand-made sets where a run of date headings would be more
/// chrome than content. The timeline is where grouping earns its place.
struct MediaCollectionView: View {

    // MARK: - Collection

    enum Collection {
        case favorites
        case archive
        case trash

        var title: String {
            switch self {
            case .favorites: return "Favorites"
            case .archive:   return "Archive"
            case .trash:     return "Recently Deleted"
            }
        }

        var emptyMessage: String {
            switch self {
            case .favorites: return "Photos you favorite appear here."
            case .archive:   return "Archived photos are hidden from the library but kept in your account."
            case .trash:     return "Deleted photos stay here until you empty them."
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    // MARK: - Body

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
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
        .confirmationDialog("Delete all items permanently?",
                            isPresented: $showsEmptyConfirmation, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { library.emptyTrash() }
        } message: {
            Text("This cannot be undone.")
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
        case .favorites: return library.favorites
        case .archive:   return library.archived
        case .trash:     return library.trashItems
        }
    }

    @ViewBuilder
    private func cell(for item: MediaItem) -> some View {
        if collection == .trash {
            // A trashed item cannot be opened: the viewer's actions (favorite, archive, add to
            // album) do not apply to something already deleted, and restoring is the only thing
            // worth doing to it.
            PhotoThumbnailView(item: item, showsBadges: false)
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
            Image(systemName: collection == .trash ? "trash" :
                    (collection == .archive ? "archivebox" : "heart"))
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
