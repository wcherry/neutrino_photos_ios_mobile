import SwiftUI

// MARK: - AlbumsView

/// Albums, plus the collections that are not albums but live beside them — Favorites, Recently
/// Added, Archive, and Recently Deleted, exactly where Apple Photos keeps them.
///
/// ## Why the collections are a list and the albums are a grid
///
/// They answer different questions. The collections are a fixed, short, *named* set: the user is
/// looking for the word "Favorites", so a row with a count beside it is the fastest thing to read.
/// Albums are user-made and remembered by what is in them rather than by what they are called, so
/// they get covers — and a cover is worth the space only when there are enough of them that the
/// names blur together, which is exactly when a list stops working.
///
/// The cover itself is resolved locally: ``Album/coverPhotoID`` is an id, and the library already
/// holds every item's thumbnail. See ``Album``.
struct AlbumsView: View {

    @EnvironmentObject private var albums: AlbumService
    @EnvironmentObject private var library: PhotoLibraryService

    @State private var newAlbumTitle = ""
    @State private var showsNewAlbum = false
    @State private var renaming: Album?
    @State private var renameTitle = ""
    @State private var deleting: Album?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                collections
                albumSection
                if let error = albums.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newAlbumTitle = ""
                    showsNewAlbum = true
                } label: {
                    Label("New Album", systemImage: "plus")
                }
            }
        }
        .refreshable { await albums.load() }
        .task { await albums.load() }
        .alert("New Album", isPresented: $showsNewAlbum) {
            TextField("Name", text: $newAlbumTitle)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create() }
        }
        .alert("Rename Album", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let album = renaming {
                    let trimmed = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { albums.rename(id: album.id, to: trimmed) }
                }
                renaming = nil
            }
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil },
                                                 set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) {
                if let album = deleting { albums.delete(id: album.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            // The reassurance that makes the button safe to press, and what verification step 3
            // checks: an album is a grouping, not a container that owns its contents.
            Text("The photos in it stay in your library.")
        }
    }

    // MARK: - Collections

    @ViewBuilder
    private var collections: some View {
        VStack(spacing: 0) {
            if FeatureFlags.favorites {
                collectionRow(.favorites, count: library.favorites.count)
                divider
            }
            collectionRow(.recentlyAdded, count: library.recentlyAdded().count)
            if FeatureFlags.archive {
                divider
                collectionRow(.archive, count: library.archived.count)
            }
            if FeatureFlags.trash {
                divider
                collectionRow(.trash, count: library.trashItems.count)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
    }

    private var divider: some View {
        Divider().padding(.leading, 52)
    }

    private func collectionRow(_ collection: MediaCollectionView.Collection,
                               count: Int) -> some View {
        NavigationLink {
            MediaCollectionView(collection: collection)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: collection.symbolName)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(collection.title)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Albums

    @ViewBuilder
    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My Albums")
                .font(.title3.weight(.semibold))
                .padding(.horizontal)

            if albums.albums.isEmpty {
                Text(albums.isLoading
                     ? "Loading albums…"
                     : "No albums yet. Create one, then add photos from the viewer or by selecting several in the library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(albums.albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            card(for: album)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { albumMenu(album) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func card(for album: Album) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(for: album)
            Text(album.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(album.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The album's cover, resolved out of the library the app already holds.
    ///
    /// Three outcomes, and each is drawn differently on purpose: a cover this device knows, an
    /// album the server says has a cover this device has not synced yet, and an empty album. The
    /// middle one is the interesting case — it happens on a fresh install between the album listing
    /// and the photo listing — and it draws the album symbol rather than a broken-image state,
    /// because nothing is broken.
    @ViewBuilder
    private func cover(for album: Album) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let id = album.coverPhotoID, let item = library.item(id: id) {
                PhotoThumbnailView(item: item, showsBadges: false)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: album.symbolName)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func albumMenu(_ album: Album) -> some View {
        // An auto album belongs to the server — it is regenerated from a person's faces — so
        // neither action is offered for one. It can still be opened.
        if album.isEditable {
            Button {
                renameTitle = album.title
                renaming = album
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = album
            } label: {
                Label("Delete Album", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func create() {
        let trimmed = newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { try? await albums.create(title: trimmed) }
    }
}
