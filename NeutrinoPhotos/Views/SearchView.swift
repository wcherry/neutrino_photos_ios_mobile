import SwiftUI

// MARK: - SearchView

/// The Search tab.
///
/// Present before Epic 11 builds it: search needs a local index over the library. Until then the
/// tab exists and says so, so the shell keeps the same four tabs.
struct SearchView: View {

    @EnvironmentObject private var library: PhotoLibraryService

    var body: some View {
        TabPlaceholderView(
            title: "Search isn't here yet",
            systemImage: "magnifyingglass",
            message: """
                     Finding a photo by name, date, or camera needs an index of the library on \
                     this device. Until that exists, the timeline is the way through \
                     \(library.allItems.count) item(s).
                     """
        )
        .navigationTitle("Search")
    }
}

#Preview {
    NavigationStack {
        SearchView()
            .environmentObject(PhotoLibraryService(api: APIClient()))
    }
}
