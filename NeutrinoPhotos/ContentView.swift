import SwiftUI

// MARK: - ContentView

/// The signed-in app shell.
///
/// Three tabs, which is what the app currently does: the timeline, the collections that hang off
/// it, and settings. Search, People, Places, and Memories are tabs in the roadmap and are
/// deliberately absent rather than present-and-empty — see `FeatureFlags`.
///
/// Each tab keeps its own `NavigationStack` so opening an album in one does not disturb the others.
struct ContentView: View {

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var importer: PhotoImportService

    @State private var selectedTab: Tab = .library

    enum Tab: Hashable {
        case library, albums, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }
            .tag(Tab.library)

            if FeatureFlags.albums {
                NavigationStack {
                    AlbumsView()
                }
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }
                .tag(Tab.albums)
            }

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
    }
}
