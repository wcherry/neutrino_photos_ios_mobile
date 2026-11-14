import SwiftUI

// MARK: - SearchView

/// The Search tab — Epic 11.
///
/// Searches the copy of the library already on this device (see ``SearchIndex``), so it answers as
/// fast with no signal as with one, and sends nothing anywhere. A query is a mix of filters and
/// text: "June 2024", "videos", "favorites", "iPhone 15 Pro", "beach 2023".
///
/// With nothing typed, the screen offers what is worth searching for in *this* library — the
/// cameras it was shot on, the years it covers — and what was searched for lately.
struct SearchView: View {

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var albums: AlbumService
    @EnvironmentObject private var settings: AppSettings
    /// Held only to hand on to the viewer.
    @EnvironmentObject private var thumbnails: ThumbnailCache
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary

    @State private var text = ""
    @StateObject private var index = SearchIndexCache()
    @State private var viewerStart: MediaItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        Group {
            if query.isEmpty {
                start
            } else {
                results
            }
        }
        .navigationTitle("Search")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Names, dates, cameras, captions")
        .searchSuggestions {
            ForEach(index.current(for: library).completions(for: text), id: \.self) { completion in
                Label(completion, systemImage: "magnifyingglass")
                    .searchCompletion(completion)
            }
        }
        .onSubmit(of: .search) { settings.recordSearch(text) }
        .fullScreenCover(item: $viewerStart) { start in
            PhotoDetailView(items: matches, initialID: start.id)
                .environmentObject(thumbnails)
                .environmentObject(deviceLibrary)
        }
    }

    // MARK: - Query

    private var query: SearchQuery {
        SearchQuery.parse(text)
    }

    private var matches: [MediaItem] {
        index.current(for: library).search(query)
    }

    /// Albums whose name contains the text — offered above the photographs, since "Italy" is as
    /// likely to be an album as a word in a caption.
    private var matchingAlbums: [Album] {
        let needle = query.text
        guard !needle.isEmpty else { return [] }
        return albums.albums.filter { $0.title.lowercased().contains(needle) }
    }

    // MARK: - Start

    private var start: some View {
        let searchIndex = index.current(for: library)
        return List {
            if !settings.recentSearches.isEmpty {
                Section {
                    ForEach(settings.recentSearches, id: \.self) { recent in
                        Button {
                            text = recent
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { settings.clearRecentSearches() }
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }

            Section("Suggestions") {
                suggestion("Videos", systemImage: "video")
                suggestion("Favorites", systemImage: "heart")
                suggestion("Screenshots", query: "screenshot", systemImage: "camera.viewfinder")
                suggestion("Live Photos", query: "live photo", systemImage: "livephoto")
                suggestion("This month", systemImage: "calendar")
                suggestion("Last week", systemImage: "calendar")
            }

            let cameras = searchIndex.cameras()
            if !cameras.isEmpty {
                Section("Cameras") {
                    ForEach(cameras, id: \.self) { camera in
                        suggestion(camera, systemImage: "camera")
                    }
                }
            }

            let years = searchIndex.years()
            if !years.isEmpty {
                Section("Years") {
                    ForEach(years.prefix(8), id: \.self) { year in
                        suggestion(String(year), systemImage: "calendar")
                    }
                }
            }
        }
    }

    private func suggestion(_ title: String, query: String? = nil,
                            systemImage: String) -> some View {
        Button {
            text = query ?? title
            settings.recordSearch(text)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        let items = matches
        let albumMatches = matchingAlbums
        if items.isEmpty && albumMatches.isEmpty {
            noResults
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !albumMatches.isEmpty {
                        albumsRow(albumMatches)
                    }
                    if !items.isEmpty {
                        Text(items.count == 1 ? "1 item" : "\(items.count) items")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(items) { item in
                                Button {
                                    settings.recordSearch(text)
                                    viewerStart = item
                                } label: {
                                    PhotoThumbnailView(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func albumsRow(_ matches: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Albums")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(matches) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            Label(album.title, systemImage: album.symbolName)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// An empty state rather than a spinner: the index is local, so an empty answer is final.
    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No results for “\(text)”")
                .font(.headline)
            Text("Try a file name, a camera, a caption, or a date like “June 2024”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SearchIndexCache

/// Holds one ``SearchIndex`` and rebuilds it only when the library has changed.
///
/// Keyed on ``PhotoLibraryService/revision`` for the same reason ``TimelineCache`` is: comparing the
/// library itself on every keystroke would cost more than the search.
@MainActor
final class SearchIndexCache: ObservableObject {

    private var index = SearchIndex(items: [])
    private var revision: Int?

    func current(for library: PhotoLibraryService) -> SearchIndex {
        if revision != library.revision {
            index = SearchIndex(items: library.allItems)
            revision = library.revision
        }
        return index
    }
}
