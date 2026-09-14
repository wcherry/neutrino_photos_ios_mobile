import SwiftUI
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoUI

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

    @StateObject private var authService: AuthService
    @StateObject private var settings: AppSettings
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var api: APIClient
    @StateObject private var library: PhotoLibraryService
    @StateObject private var albums: AlbumService
    @StateObject private var content: MediaContentService
    @StateObject private var importer: PhotoImportService
    @StateObject private var libraryImporter: LibraryImportService
    @StateObject private var ledger: ImportLedger
    @StateObject private var vault: KeyVaultService
    @StateObject private var devices: DeviceSessionService
    @StateObject private var drive: PhotosDriveService
    @StateObject private var thumbnails: ThumbnailCache
    @StateObject private var deviceLibrary: DevicePhotoLibrary
    @StateObject private var deviceBrowser: DeviceLibraryBrowser
    @StateObject private var keyFiles: KeyFileRouter
    @StateObject private var keyProvisioning = KeyProvisioningService()

    /// The device's copy of the library. Optional because opening a database can fail — a full
    /// disk, a device the user has locked out of its own storage — and every consumer treats it as
    /// an accelerator rather than a source of truth, so "no database" degrades to the behaviour the
    /// app had before there was one.
    private let store: LocalStore?

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init() {
        // Before anything else. Every shared service resolves its Keychain namespace, OAuth client
        // id and default host through this, and `NeutrinoApp.current` traps if one is built first —
        // which is also why `authService` and `keyFiles` have no default value above: property
        // defaults are evaluated before this body runs. `nphoto.*` is what previous builds wrote,
        // so this reads the existing session and encryption key rather than starting cold.
        NeutrinoApp.configure(.photos)
        NeutrinoBrand.use(.photos)

        // Built here rather than lazily inside the services so there is exactly one client, one
        // `URLSession`, and one place a test can swap the transport.
        let api = APIClient()
        let store = try? LocalStore.makeDefault()
        let drive = PhotosDriveService(api: api, store: store)
        let thumbnails = ThumbnailCache()
        let library = PhotoLibraryService(api: api, store: store)
        let content = MediaContentService(api: api, store: store, drive: drive,
                                          thumbnails: thumbnails)
        let settings = AppSettings()
        let monitor = NetworkMonitor()
        let vault = KeyVaultService(api: api)
        // Constructed unconditionally, even with `deviceLibraryAccess` off: it reads the standing
        // authorization status and prompts for nothing until something asks it to, so building it
        // does not show the user a permission alert.
        let deviceLibrary = DevicePhotoLibrary()
        let albums = AlbumService(api: api)
        // One record of what this device has uploaded, shared by both importers. Two records would
        // mean a photograph picked in the picker and then found again by a full-library scan gets
        // uploaded twice — see `ImportLedger`.
        let ledger = ImportLedger(store: store)
        let pipeline = MediaImportPipeline(content: content, library: library, settings: settings,
                                           ledger: ledger, deviceLibrary: deviceLibrary)

        self.store = store
        _authService = StateObject(wrappedValue: AuthService())
        _keyFiles = StateObject(wrappedValue: KeyFileRouter())
        _api = StateObject(wrappedValue: api)
        _library = StateObject(wrappedValue: library)
        _albums = StateObject(wrappedValue: albums)
        _content = StateObject(wrappedValue: content)
        _ledger = StateObject(wrappedValue: ledger)
        _drive = StateObject(wrappedValue: drive)
        _thumbnails = StateObject(wrappedValue: thumbnails)
        _settings = StateObject(wrappedValue: settings)
        _networkMonitor = StateObject(wrappedValue: monitor)
        _vault = StateObject(wrappedValue: vault)
        _devices = StateObject(wrappedValue: DeviceSessionService(api: api))
        _deviceLibrary = StateObject(wrappedValue: deviceLibrary)
        // Built here rather than inside the screen that draws it, so the listing and its thumbnails
        // survive navigating away from that screen and back — walking a fifty-thousand-item library
        // is not something to redo because somebody tapped a tab. Nothing is fetched until the
        // device album is first opened.
        _deviceBrowser = StateObject(wrappedValue: DeviceLibraryBrowser(deviceLibrary: deviceLibrary))
        _importer = StateObject(wrappedValue: PhotoImportService(
            content: content, library: library, settings: settings, monitor: monitor, vault: vault,
            deviceLibrary: deviceLibrary, ledger: ledger
        ))
        _libraryImporter = StateObject(wrappedValue: LibraryImportService(
            pipeline: pipeline, deviceLibrary: deviceLibrary, settings: settings, monitor: monitor,
            albums: albums, store: store
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
                .environmentObject(libraryImporter)
                .environmentObject(ledger)
                .environmentObject(vault)
                .environmentObject(devices)
                .environmentObject(keyProvisioning)
                .environmentObject(drive)
                .environmentObject(thumbnails)
                .environmentObject(deviceLibrary)
                .environmentObject(deviceBrowser)
                .environmentObject(keyFiles)
                .preferredColorScheme(settings.theme.colorScheme)
                .task { await configure() }
                // Photo-library permission is changed in Settings, and iOS does not tell an app it
                // happened — it simply stops answering. Re-reading it on every return to the
                // foreground is the only way the screen that shows it can be right.
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    deviceLibrary.refresh()
                }
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
        KeyFileService.shared.authService = authService
        // Minting a key and restoring one from a printed kit both talk to the account's key
        // directory, so this needs the same token refresher as everything else.
        keyProvisioning.authService = authService

        guard authService.isAuthenticated else { return }

        // Top up this device's retired keys from the account's key file. Enrolment already does
        // this, so on a healthy install it finds nothing; it is here for the device enrolled before
        // the key file existed, and for the one that was offline when its key arrived. One request,
        // and a failure is not worth surfacing — the next launch tries again.
        if KeyImportService.hasStoredKeys() {
            Task { try? await KeyFileService.shared.restoreArchivedKeys() }
        }
        // Before anything else that could import: the ledger is what keeps a second run from
        // doubling the library, and an importer that started before it hydrated would have an empty
        // one. `restore()` hydrates it and reads back a queue the last launch was killed mid-way
        // through — see `LibraryImportService.restore()`.
        await libraryImporter.restore()
        await authService.refreshTokenIfNeeded()
        // A session restored from the Keychain has tokens but no profile — login is where the
        // other one comes from, and a relaunch doesn't go through it.
        await authService.loadProfile()
        // And no idea whether this device still holds the account's key. Asking is one GET, and
        // it is the only thing that notices a key left behind by a different account.
        await vault.refresh()
        // Which photographs already have a preview rendition in the cloud. One listing, and the
        // answer is what keeps the viewer from downloading originals it does not need. A device
        // that never runs this simply generates previews locally instead.
        await drive.refreshRenditionIndex()
    }
}

// MARK: - RootView

/// Chooses between the login screen and the app, and owns the two things that can interrupt either:
/// a key file opened from outside, and the first prompt to unlock the vault.
private struct RootView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var vault: KeyVaultService
    @EnvironmentObject private var keyFiles: KeyFileRouter
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var content: MediaContentService
    @EnvironmentObject private var libraryImporter: LibraryImportService
    @EnvironmentObject private var deviceBrowser: DeviceLibraryBrowser

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
            guard isAuthenticated else {
                // Signing out has to empty the device's copy of the library, not just the screen.
                // The next account to sign in here would otherwise hydrate the previous one's
                // timeline from the local database and draw somebody else's photographs until the
                // first listing came back — and, worse, find an import ledger claiming their whole
                // camera roll was already uploaded.
                Task {
                    await libraryImporter.reset()
                    await library.clearLocalCopy()
                    content.clearCache()
                }
                // Not the user's photographs leaking between accounts — the device library is the
                // same roll whoever is signed in. It is the "already uploaded" marks drawn over it,
                // which are read from a ledger that has just been emptied, plus a listing and tens
                // of megabytes of thumbnails that nothing on the login screen is going to look at.
                deviceBrowser.clear()
                return
            }
            hasOfferedUnlock = false
            Task {
                await vault.refresh()
                // The launch-time call in `configure()` is skipped for a signed-out start, so this
                // is the only one a fresh sign-in gets. Without it the ledger stays empty and the
                // first import re-uploads whatever this device sent before.
                await libraryImporter.restore()
            }
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
