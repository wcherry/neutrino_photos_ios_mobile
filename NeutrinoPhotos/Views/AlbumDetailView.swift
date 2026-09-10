import SwiftUI

// MARK: - AlbumDetailView

/// One album's contents.
///
/// The screen Epic 9 existed to build. Until it, `GET /api/v1/albums/{id}/items` did not exist and
/// the Albums tab was a list of cards that could not be opened — the count was the only thing an
/// album could say about itself.
///
/// ## Why the contents are loaded here rather than held in the service
///
/// An album's grid is a screen's worth of state with a natural owner, and caching it in
/// ``AlbumService`` would keep every album ever opened — thumbnails and all — in memory for the
/// rest of the launch. This loads on appear and on pull-to-refresh, and the ``ThumbnailCache``
/// underneath means the second visit decodes nothing it decoded the first time.
///
/// ## Removing is not deleting
///
/// The single most important thing on this screen is that "Remove from Album" and "Delete" are
/// different actions with different words, different icons, and different confirmations. Removing
/// takes the photograph out of the album and leaves it in the library; deleting moves it to
/// Recently Deleted, where it drops out of *every* album at once. Conflating the two is how a user
/// tidying an album loses a photograph.
struct AlbumDetailView: View {

    let album: Album

    @EnvironmentObject private var albums: AlbumService
    @EnvironmentObject private var library: PhotoLibraryService
    /// Held only to hand on to the viewer, which opens on a cell's cover thumbnail.
    @EnvironmentObject private var thumbnails: ThumbnailCache
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary

    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    /// Nil until the first load finishes, so an empty album and an unread one draw differently.
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var viewerStart: MediaItem?
    @State private var removing: MediaItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    // MARK: - Body

    var body: some View {
        Group {
            if items.isEmpty && hasLoaded && !isLoading {
                emptyState
            } else if items.isEmpty && isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(album.title)
                        .font(.headline)
                        .lineLimit(1)
                    // The live count rather than `album.photoCount`: a removal has to be reflected
                    // here immediately, and the card's copy is only refreshed by a listing.
                    Text(countLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .fullScreenCover(item: $viewerStart) { start in
            PhotoDetailView(items: items, initialID: start.id)
                .environmentObject(thumbnails)
                .environmentObject(deviceLibrary)
        }
        .confirmationDialog("Remove from “\(album.title)”?",
                            isPresented: Binding(get: { removing != nil },
                                                 set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from Album") {
                if let item = removing { remove(item) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            // Spelled out because it is the exact thing verification step 2 checks, and the exact
            // thing a user is afraid of when they tap it.
            Text("The photo stays in your library.")
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
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
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        if FeatureFlags.favorites {
            Button {
                library.setStarred(id: item.id, isStarred: !item.isStarred)
                // The album's own copy is what this grid draws, so it has to be updated too — the
                // library's change does not reach an array this view owns.
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].isStarred.toggle()
                }
            } label: {
                Label(item.isStarred ? "Remove from Favorites" : "Favorite",
                      systemImage: item.isStarred ? "heart.slash" : "heart")
            }
        }
        if album.isEditable {
            Button {
                removing = item
            } label: {
                // Not destructive, and deliberately: the photograph is not going anywhere. The red
                // is spent on Delete below, which is the action that actually loses something.
                Label("Remove from Album", systemImage: "minus.circle")
            }
        }
        if FeatureFlags.trash {
            Button(role: .destructive) {
                library.trash(id: item.id)
                items.removeAll { $0.id == item.id }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private var countLabel: String {
        items.count == 1 ? "1 photo" : "\(items.count) photos"
    }

    private func load() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            items = try await albums.photos(in: album.id)
        } catch where error.isCancellation {
            // Navigated away before the listing came back. Nothing to say about a request nobody
            // is waiting for.
        } catch {
            // The grid stays on screen if there was one — a failed refresh is stale contents, not
            // an empty album, and blanking it would read as "everything was removed".
            self.error = error.localizedDescription
        }
    }

    private func remove(_ item: MediaItem) {
        // Optimistic here, unlike the add: the row is the thing the user is looking at, and putting
        // it back on failure is a visible, correct undo.
        let index = items.firstIndex(where: { $0.id == item.id })
        items.removeAll { $0.id == item.id }
        error = nil

        Task {
            do {
                try await albums.remove(photoID: item.id, from: album.id)
            } catch {
                if let index, index <= items.count {
                    items.insert(item, at: index)
                } else {
                    items.append(item)
                }
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: album.symbolName)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(album.isAuto
                 ? "This album is generated automatically and has nothing in it yet."
                 : "No photos in this album yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if album.isEditable {
                Text("Add photos from the viewer, or select several in the library.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
