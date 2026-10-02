import SwiftUI

// MARK: - ContentView

/// The signed-in app shell.
///
/// Four tabs, fixed: the timeline, the collections that hang off it, search, and settings. People,
/// Places, and Memories are views inside these tabs when they arrive, not tabs of their own, so the
/// shell keeps the same shape as the app grows.
///
/// Each tab keeps its own `NavigationStack` so opening an album in one does not disturb the others.
struct ContentView: View {

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var importer: PhotoImportService
    /// Held, like ``importer``, only to know whether this device is mid-import — see
    /// ``isImporting``.
    @EnvironmentObject private var libraryImporter: LibraryImportService
    @EnvironmentObject private var photoLinks: PhotoLinkRouter
    /// Held only to hand on to a viewer opened from a link.
    @EnvironmentObject private var thumbnails: ThumbnailCache
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .library
    /// The photo a link opened, shown over whichever tab is up.
    @State private var linkedItem: MediaItem?
    /// Set when a link named a photo this account's library doesn't hold.
    @State private var showsLinkUnavailable = false

    enum Tab: Hashable {
        case library, albums, search, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }
            .tag(Tab.library)

            NavigationStack {
                AlbumsView()
            }
            .tabItem { Label("Albums", systemImage: "rectangle.stack") }
            .tag(Tab.albums)

            NavigationStack {
                SearchView()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
        // The badge is the one piece of import state visible from another tab: an import started
        // from the library keeps running while somebody browses albums, and a silent upload is one
        // people assume has stopped.
        .task(id: importer.isImporting) {
            guard !importer.isImporting else { return }
            await library.load()
        }
        // Issue #13: the two moments a timeline is worth looking at again, and the reason they live
        // here rather than in `LibraryView`. That view knows when it appears; it does not know that
        // the app was away for an hour, and it cannot see the tab bar it is inside. This does, and
        // it already owns the third trigger above — so all three reasons the library gets re-read
        // are in one place and throttle against each other through `refreshIfStale`.
        .onChange(of: scenePhase) { phase in
            guard phase == .active, !isImporting else { return }
            Task { await library.refreshIfStale() }
        }
        .onChange(of: selectedTab) { tab in
            guard tab == .library, !isImporting else { return }
            Task { await library.refreshIfStale() }
        }
        // A link can arrive before the library has loaded — a cold launch from a tap in Messages —
        // so it is tried when it lands and again whenever the library changes, until it resolves.
        .onChange(of: photoLinks.pendingFileID) { _ in openPendingLink() }
        .onChange(of: library.lastLoadedAt) { _ in openPendingLink() }
        .onChange(of: library.isFillingIn) { _ in openPendingLink() }
        .onAppear { openPendingLink() }
        .fullScreenCover(item: $linkedItem) { item in
            PhotoDetailView(items: [item], initialID: item.id)
                .environmentObject(thumbnails)
                .environmentObject(deviceLibrary)
        }
        .sheet(isPresented: $showsLinkUnavailable) {
            PhotoLinkUnavailableView()
        }
    }

    // MARK: - Photo links

    /// Opens the photo a `/open/photo/<file id>` link named, once the library can say whether it
    /// holds it.
    ///
    /// Resolved against the library this device already has rather than by fetching the file: a
    /// photo is only openable here if it is in this account's library, and a link to anything else
    /// — another account's photo, one since deleted — gets a plain "not available" rather than an
    /// error from deep in the download path.
    private func openPendingLink() {
        guard let fileID = photoLinks.pendingFileID else { return }
        if let item = library.allItems.first(where: { $0.fileID == fileID }) {
            _ = photoLinks.consume()
            linkedItem = item
            return
        }
        // Not found *yet* is not "not available": wait for the walk to finish before saying so.
        guard library.lastLoadedAt != nil, !library.isFillingIn, !library.isLoading else { return }
        _ = photoLinks.consume()
        showsLinkUnavailable = true
    }

    // MARK: - Importing

    /// True while this device is putting photographs into the library itself.
    ///
    /// Not merely wasted work to refresh through: a walk replaces the whole timeline with what the
    /// server said when it *started*, so an item registered while it ran would drop out of the grid
    /// until the next load. A run gets its refresh when it finishes, from the task above.
    private var isImporting: Bool {
        importer.isImporting || libraryImporter.isBusy
    }
}
