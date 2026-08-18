import SwiftUI

// MARK: - AlbumsView

/// Albums, plus the collections that are not albums but live beside them — Favorites, Archive, and
/// Recently Deleted, exactly where Apple Photos keeps them.
///
/// An album card shows its name and count and cannot be opened: the server has no endpoint that
/// lists an album's contents. Rather than a dead tap, the card says so.
struct AlbumsView: View {

    @EnvironmentObject private var albums: AlbumService
    @EnvironmentObject private var library: PhotoLibraryService

    @State private var newAlbumTitle = ""
    @State private var showsNewAlbum = false
    @State private var renaming: Album?
    @State private var renameTitle = ""

    var body: some View {
        List {
            Section("Collections") {
                if FeatureFlags.favorites {
                    NavigationLink {
                        MediaCollectionView(collection: .favorites)
                    } label: {
                        collectionRow("Favorites", systemImage: "heart", count: library.favorites.count)
                    }
                }
                if FeatureFlags.archive {
                    NavigationLink {
                        MediaCollectionView(collection: .archive)
                    } label: {
                        collectionRow("Archive", systemImage: "archivebox", count: library.archived.count)
                    }
                }
                if FeatureFlags.trash {
                    NavigationLink {
                        MediaCollectionView(collection: .trash)
                    } label: {
                        collectionRow("Recently Deleted", systemImage: "trash",
                                      count: library.trashItems.count)
                    }
                }
            }

            Section {
                if albums.albums.isEmpty && !albums.isLoading {
                    Text("No albums yet. Create one, then add photos to it from the viewer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(albums.albums) { album in
                    albumRow(album)
                }
            } header: {
                Text("My Albums")
            } footer: {
                Text("Opening an album isn't available yet — the Neutrino API has no endpoint that lists an album's contents.")
                    .font(.caption)
            }

            if let error = albums.error {
                Section { Text(error).foregroundStyle(.red) }
            }
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
    }

    // MARK: - Rows

    private func collectionRow(_ title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
    }

    private func albumRow(_ album: Album) -> some View {
        HStack {
            Image(systemName: album.symbolName)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                Text(album.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .swipeActions(edge: .trailing) {
            // An auto album belongs to the server — it is regenerated from a person's faces — so
            // neither action is offered for one.
            if !album.isAuto {
                Button(role: .destructive) {
                    albums.delete(id: album.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    renameTitle = album.title
                    renaming = album
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.indigo)
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
