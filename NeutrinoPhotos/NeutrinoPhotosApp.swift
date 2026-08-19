import SwiftUI

// MARK: - NeutrinoPhotosApp

/// Composition root. Every service is constructed once here and injected into the view tree;
/// nothing reaches for a singleton.
///
/// The wiring is deliberately explicit rather than hidden behind a container. The graph is small
/// and one-directional — everything that talks to the server goes through a single `APIClient`,
/// and the import service is the only thing that needs three of the others at once — so writing it
/// out says more than a registration list would.
@main
struct NeutrinoPhotosApp: App {

    // MARK: - Services

    @StateObject private var authService = AuthService()
    @StateObject private var settings: AppSettings
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var api: APIClient
    @StateObject private var library: PhotoLibraryService
    @StateObject private var albums: AlbumService
    @StateObject private var content: MediaContentService
    @StateObject private var importer: PhotoImportService

    // MARK: - Init

    init() {
        // Built here rather than lazily inside the services so there is exactly one client, one
        // `URLSession`, and one place a test can swap the transport.
        let api = APIClient()
        let library = PhotoLibraryService(api: api)
        let content = MediaContentService(api: api)
        let settings = AppSettings()
        let monitor = NetworkMonitor()

        _api = StateObject(wrappedValue: api)
        _library = StateObject(wrappedValue: library)
        _albums = StateObject(wrappedValue: AlbumService(api: api))
        _content = StateObject(wrappedValue: content)
        _settings = StateObject(wrappedValue: settings)
        _networkMonitor = StateObject(wrappedValue: monitor)
        _importer = StateObject(wrappedValue: PhotoImportService(
            content: content, library: library, settings: settings, monitor: monitor
        ))
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(settings)
                .environmentObject(networkMonitor)
                .environmentObject(library)
                .environmentObject(albums)
                .environmentObject(content)
                .environmentObject(importer)
                .preferredColorScheme(settings.theme.colorScheme)
                .task { await configure() }
        }
    }

    // MARK: - Wiring

    @MainActor
    private func configure() async {
        // Idempotent: `.task` runs again if the scene is rebuilt, and this is a reference write.
        api.authService = authService

        if authService.isAuthenticated {
            await authService.refreshTokenIfNeeded()
            // A session restored from the Keychain has tokens but no profile — login is where the
            // other one comes from, and a relaunch doesn't go through it.
            await authService.loadProfile()
        }
    }
}

// MARK: - RootView

/// Chooses between the login screen and the app.
private struct RootView: View {

    @EnvironmentObject private var authService: AuthService

    var body: some View {
        if authService.isAuthenticated {
            ContentView()
        } else {
            LoginView()
        }
    }
}
