import SwiftUI

// MARK: - ContentView

/// The signed-in app shell.
///
/// Four tabs, fixed: the timeline, the collections that hang off it, search, and settings. Search
/// is present without its epic behind it — a tab that appears once a flag flips would move the
/// other three under the user's thumb, so the shell is the same shape in every build and the tab
/// says what it doesn't do yet. People, Places, and Memories are views inside these tabs when they
/// arrive, not tabs of their own — see `FeatureFlags`.
///
/// Each tab keeps its own `NavigationStack` so opening an album in one does not disturb the others.
struct ContentView: View {

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var importer: PhotoImportService
    /// Held, like ``importer``, only to know whether this device is mid-import — see
    /// ``isImporting``.
    @EnvironmentObject private var libraryImporter: LibraryImportService

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .library

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
                if FeatureFlags.albums {
                    AlbumsView()
                } else {
                    TabPlaceholderView(
                        title: "Albums aren't here yet",
                        systemImage: "rectangle.stack",
                        message: "Grouping photos into albums, and the collections beside them, arrive with the organization work."
                    )
                    .navigationTitle("Albums")
                }
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
