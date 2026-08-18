import SwiftUI

// MARK: - AlbumPickerView

/// Adds one item to an album, creating the album first if need be.
///
/// Nothing here can show what is already *in* an album — the server has no endpoint for it (see
/// ``Album``) — so this cannot mark an album the photograph already belongs to. Adding the same
/// item twice is harmless server-side, and saying so is better than implying a check that isn't
/// happening.
struct AlbumPickerView: View {

    let item: MediaItem

    @EnvironmentObject private var albums: AlbumService
    @Environment(\.dismiss) private var dismiss

    @State private var newAlbumTitle = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New album", text: $newAlbumTitle)
                            .submitLabel(.done)
                            .onSubmit { createAndAdd() }
                        Button("Create", action: createAndAdd)
                            .disabled(trimmedTitle.isEmpty || isWorking)
                    }
                }

                Section("Add to") {
                    if albums.albums.isEmpty {
                        Text("No albums yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(albums.albums) { album in
                        Button {
                            add(to: album)
                        } label: {
                            HStack {
                                Label(album.title, systemImage: album.symbolName)
                                Spacer()
                                Text(album.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isWorking)
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { if albums.albums.isEmpty { await albums.load() } }
        }
    }

    // MARK: - Actions

    private var trimmedTitle: String {
        newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createAndAdd() {
        guard !trimmedTitle.isEmpty else { return }
        perform {
            let album = try await albums.create(title: trimmedTitle)
            try await albums.add(photoID: item.id, to: album.id)
        }
    }

    private func add(to album: Album) {
        perform { try await albums.add(photoID: item.id, to: album.id) }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        isWorking = true
        error = nil
        Task {
            do {
                try await work()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
