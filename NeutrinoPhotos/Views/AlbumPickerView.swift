import SwiftUI

// MARK: - AlbumPickerView

/// Adds one or more items to an album, creating the album first if need be.
///
/// The same sheet serves the viewer's single photograph and the timeline's selection of five
/// hundred. One screen rather than two because the choice being made is identical — which album —
/// and the only thing that differs is the noun in the title and whether progress is worth showing.
///
/// Nothing here marks an album a photograph already belongs to. It could — `GET
/// /api/v1/albums/{id}/items` exists as of Epic 9 — but doing so would mean fetching every album's
/// contents to open a picker, which is a lot of thumbnails to move to grey out one row. Adding the
/// same item twice is a no-op server-side (`insert_or_ignore`), so the cost of not checking is
/// nothing, and saying so is better than implying a check that isn't happening.
struct AlbumPickerView: View {

    /// The items to add. One from the viewer, many from a timeline selection.
    let items: [MediaItem]

    /// Called when every item landed in an album, and not called otherwise.
    ///
    /// Exists so the timeline can leave multi-select mode on a successful add but leave the
    /// selection alone when the user cancels or the add half-failed — a distinction the presenting
    /// view cannot make by watching the sheet close, because both look identical from there.
    var onAdded: (() -> Void)?

    @EnvironmentObject private var albums: AlbumService
    @Environment(\.dismiss) private var dismiss

    @State private var newAlbumTitle = ""
    @State private var isWorking = false
    @State private var error: String?
    /// How far a bulk add has got, for the only case where it takes long enough to matter.
    @State private var progress: (done: Int, total: Int)?

    // MARK: - Init

    init(item: MediaItem, onAdded: (() -> Void)? = nil) {
        self.items = [item]
        self.onAdded = onAdded
    }

    init(items: [MediaItem], onAdded: (() -> Void)? = nil) {
        self.items = items
        self.onAdded = onAdded
    }

    // MARK: - Body

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
                    // Auto albums are the server's — regenerated from a person's faces — so adding
                    // to one by hand would be undone the next time it regenerates.
                    ForEach(albums.albums.filter(\.isEditable)) { album in
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

                if let progress {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Adding \(progress.done) of \(progress.total)…")
                                .font(.footnote)
                            ProgressView(value: Double(progress.done),
                                         total: Double(max(progress.total, 1)))
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
            .task { if albums.albums.isEmpty { await albums.load() } }
        }
    }

    // MARK: - Title

    private var title: String {
        items.count == 1 ? "Add to Album" : "Add \(items.count) to Album"
    }

    // MARK: - Actions

    private var trimmedTitle: String {
        newAlbumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createAndAdd() {
        guard !trimmedTitle.isEmpty else { return }
        perform { try await albums.create(title: trimmedTitle).id }
    }

    private func add(to album: Album) {
        perform { album.id }
    }

    /// Resolves an album id — creating the album if that is what was asked for — and adds every
    /// item to it.
    ///
    /// Dismisses on a complete success and stays open otherwise, so a partial run is something the
    /// user is told about rather than something they discover later by counting.
    private func perform(_ resolveAlbumID: @escaping () async throws -> String) {
        isWorking = true
        error = nil
        progress = items.count > 1 ? (done: 0, total: items.count) : nil

        Task {
            do {
                let albumID = try await resolveAlbumID()
                let result = await albums.add(photoIDs: items.map(\.id), to: albumID)
                progress = nil
                if result.isCompleteSuccess {
                    onAdded?()
                    dismiss()
                } else {
                    let failed = result.failures.count
                    error = "\(result.added.count) added. \(failed) couldn't be added."
                }
            } catch {
                progress = nil
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
