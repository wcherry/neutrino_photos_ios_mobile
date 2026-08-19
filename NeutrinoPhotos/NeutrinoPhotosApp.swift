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
    @StateObject private var vault: KeyVaultService
    @StateObject private var devices: DeviceSessionService
    @StateObject private var keyFiles = KeyFileRouter()

    // MARK: - Init

    init() {
        // Built here rather than lazily inside the services so there is exactly one client, one
        // `URLSession`, and one place a test can swap the transport.
        let api = APIClient()
        let library = PhotoLibraryService(api: api)
        let content = MediaContentService(api: api)
        let settings = AppSettings()
        let monitor = NetworkMonitor()
        let vault = KeyVaultService(api: api)

        _api = StateObject(wrappedValue: api)
        _library = StateObject(wrappedValue: library)
        _albums = StateObject(wrappedValue: AlbumService(api: api))
        _content = StateObject(wrappedValue: content)
        _settings = StateObject(wrappedValue: settings)
        _networkMonitor = StateObject(wrappedValue: monitor)
        _vault = StateObject(wrappedValue: vault)
        _devices = StateObject(wrappedValue: DeviceSessionService(api: api))
        _importer = StateObject(wrappedValue: PhotoImportService(
            content: content, library: library, settings: settings, monitor: monitor, vault: vault
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
                .environmentObject(vault)
                .environmentObject(devices)
                .environmentObject(keyFiles)
                .preferredColorScheme(settings.theme.colorScheme)
                .task { await configure() }
                .onOpenURL { url in
                    // A `.json` key file AirDropped or tapped in Files. Declaring the document type
                    // in `project.yml` is what makes iOS offer this app; consuming the URL here is
                    // what makes tapping it do something.
                    _ = keyFiles.handle(url)
                }
        }
    }

    // MARK: - Wiring

    @MainActor
    private func configure() async {
        // Idempotent: `.task` runs again if the scene is rebuilt, and this is a reference write.
        api.authService = authService

        guard authService.isAuthenticated else { return }
        await authService.refreshTokenIfNeeded()
        // A session restored from the Keychain has tokens but no profile — login is where the
        // other one comes from, and a relaunch doesn't go through it.
        await authService.loadProfile()
        // And no idea whether this device still holds the account's key. Asking is one GET, and
        // it is the only thing that notices a key left behind by a different account.
        await vault.refresh()
    }
}

// MARK: - RootView

/// Chooses between the login screen and the app, and owns the two things that can interrupt either:
/// a key file opened from outside, and the first prompt to unlock the vault.
private struct RootView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var vault: KeyVaultService
    @EnvironmentObject private var keyFiles: KeyFileRouter

    @State private var showsUnlock = false
    @State private var hasOfferedUnlock = false

    var body: some View {
        Group {
            if authService.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }
        }
        .sheet(isPresented: $showsUnlock) {
            VaultUnlockView()
                .environmentObject(vault)
        }
        .alert(keyFileTitle, isPresented: keyFileAlertBinding) {
            Button("OK") { keyFiles.outcome = nil }
        } message: {
            Text(keyFileMessage)
        }
        // Prompted rather than blocked. A locked library still browses — the grid draws plaintext
        // cover thumbnails — so a hard lock screen would hide photographs the user can look at
        // perfectly well. Offered exactly once per launch; Settings and the library banner are how
        // somebody who dismissed it gets back.
        .onChange(of: vault.status) { status in
            guard status == .locked, !hasOfferedUnlock else { return }
            hasOfferedUnlock = true
            showsUnlock = true
        }
        .onChange(of: keyFiles.outcome) { outcome in
            // A key file that landed while the vault was locked unlocks it, without a round trip.
            if case .imported = outcome { vault.refreshFromKeychain() }
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            guard isAuthenticated else { return }
            hasOfferedUnlock = false
            Task { await vault.refresh() }
        }
    }

    // MARK: - Key file outcome

    private var keyFileAlertBinding: Binding<Bool> {
        Binding(get: { keyFiles.outcome != nil },
                set: { if !$0 { keyFiles.outcome = nil } })
    }

    private var keyFileTitle: String {
        if case .failed = keyFiles.outcome { return "Key File Not Imported" }
        return "Key Imported"
    }

    private var keyFileMessage: String {
        switch keyFiles.outcome {
        case .imported(let name):
            return "\(name) was imported. Your photos are available on this device."
        case .failed(let message):
            return message
        case nil:
            return ""
        }
    }
}
