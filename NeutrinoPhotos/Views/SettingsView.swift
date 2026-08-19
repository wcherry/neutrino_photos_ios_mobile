import SwiftUI

// MARK: - SettingsView

/// Preferences, the account, and the state of the encryption key.
struct SettingsView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var content: MediaContentService
    @EnvironmentObject private var importer: PhotoImportService
    @EnvironmentObject private var monitor: NetworkMonitor
    @EnvironmentObject private var vault: KeyVaultService
    @EnvironmentObject private var drive: PhotosDriveService

    @State private var deviceName = DeviceIdentity.deviceName
    @State private var showsSignOutConfirmation = false
    @State private var storage: MediaContentService.StorageBreakdown?

    // MARK: - Body

    var body: some View {
        List {
            librarySection
            uploadsSection
            encryptionSection
            storageSection
            accountSection
            aboutSection
        }
        .navigationTitle("Settings")
        .task {
            storage = await content.storageBreakdown()
            // A second chance at the account: the launch attempt is the only other one, and it
            // happens exactly when a phone is most likely to still be off the network.
            if authService.profile == nil {
                await authService.loadProfile()
            }
            if drive.quota == nil {
                await drive.loadQuota()
            }
        }
        .confirmationDialog("Sign out of Neutrino Photos?",
                            isPresented: $showsSignOutConfirmation, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { authService.logout() }
        } message: {
            Text("Your encryption key stays on this device so you don't have to import it again.")
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section("Library") {
            Picker("Group by", selection: $settings.timelineGrouping) {
                ForEach(TimelineGrouping.allCases) { grouping in
                    Text(grouping.displayName).tag(grouping)
                }
            }
            Toggle("Show archived photos", isOn: $settings.showArchived)
            Picker("Appearance", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            LabeledContent("Photos", value: "\(library.allItems.count)")
        }
    }

    // MARK: - Uploads

    private var uploadsSection: some View {
        Section {
            Toggle("Upload over Wi-Fi only", isOn: $settings.wifiOnlyUploads)
            LabeledContent("Connection", value: connectionDescription)
            Button("Forget import history") { importer.forgetImportHistory() }
                .disabled(importer.importedCount == 0)
        } header: {
            Text("Uploads")
        } footer: {
            Text("""
                 This device remembers \(importer.importedCount) uploaded item(s) so importing the \
                 same photos twice doesn't duplicate them. The record is local — the server stores \
                 only ciphertext and cannot compare two photos for sameness.
                 """)
        }
    }

    private var connectionDescription: String {
        guard monitor.isOnline else { return "Offline" }
        return monitor.isExpensive ? "Cellular" : "Wi-Fi"
    }

    // MARK: - Encryption

    private var encryptionSection: some View {
        Section {
            NavigationLink {
                EncryptionSettingsView()
            } label: {
                LabeledContent("Encryption", value: keyStateDescription)
            }
            NavigationLink("Devices") { DevicesView() }
        } header: {
            Text("Encryption")
        } footer: {
            Text("""
                 Photos are encrypted on this device before upload and the key never leaves it. \
                 Browsing the timeline works without a key — grid previews are stored unencrypted \
                 with each file — but opening an original needs one.
                 """)
        }
    }

    private var keyStateDescription: String {
        switch vault.status {
        case .unlocked:    return "Unlocked"
        case .locked:      return "Locked"
        case .noVault:     return "No key"
        case .unreachable: return KeyImportService.hasStoredKeys() ? "Unlocked" : "Unknown"
        case .unknown:     return "Checking…"
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            if let quota = drive.quota {
                LabeledContent("In your account", value: quota.formattedUsage)
            }
            LabeledContent("Photos and videos on this device", value: bytes(storage?.originals))
            LabeledContent("Grid previews", value: bytes(storage?.thumbnails))
            LabeledContent("Library index", value: bytes(storage?.database))
            Button("Clear cache") {
                content.clearCache()
                Task { storage = await content.storageBreakdown() }
            }
            .disabled((storage?.originals ?? 0) + (storage?.thumbnails ?? 0) == 0)
        } header: {
            Text("Storage")
        } footer: {
            Text("""
                 Opening a photo or playing a video keeps its decrypted copy on this device so the \
                 next look at it costs nothing. The cache is capped and the oldest items are \
                 dropped first. Clearing it frees the space immediately — nothing is lost, since \
                 every one of them is still in your account.
                 """)
        }
    }

    private func bytes(_ count: Int64?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            if let profile = authService.profile {
                LabeledContent("Signed in as", value: profile.name)
                LabeledContent("Email", value: profile.email)
            } else {
                // `GET /api/v1/auth/me` hasn't answered — a launch that never reached the server,
                // usually. The session is still valid; only the display name is missing.
                LabeledContent("Signed in as", value: "—")
            }
            HStack {
                Text("Device name")
                Spacer()
                TextField("Device name", text: $deviceName)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .onSubmit { DeviceIdentity.setDeviceName(deviceName) }
            }
            LabeledContent("Server", value: AuthService.baseURL)
            Button("Sign out", role: .destructive) { showsSignOutConfirmation = true }
        } header: {
            Text("Account")
        } footer: {
            Text("The device name identifies this session in your account's device list. It is sent when you sign in, so a change takes effect at the next sign-in.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
            NavigationLink("What's not here yet") { RoadmapView() }
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - RoadmapView

/// The roadmap, read straight off `FeatureFlags`.
///
/// A settings screen that lists what an app *cannot* do is unusual, and deliberate here: this is an
/// early build of a photo library, and somebody deciding whether to trust it with their pictures
/// should be able to see the gap between it and the roadmap without reading the source.
private struct RoadmapView: View {

    private let planned: [(String, Bool)] = [
        ("Local cache and library index", FeatureFlags.mediaPipeline),
        ("Automatic backup", FeatureFlags.automaticBackup),
        ("Offline browsing", FeatureFlags.offlineMode),
        ("Search", FeatureFlags.search),
        ("Places and map", FeatureFlags.places),
        ("People and faces", FeatureFlags.people),
        ("Memories", FeatureFlags.memories),
        ("Editing", FeatureFlags.editing),
        ("Sharing", FeatureFlags.sharing),
    ]

    var body: some View {
        List {
            Section {
                ForEach(planned, id: \.0) { name, done in
                    HStack {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(done ? .green : .secondary)
                        Text(name)
                    }
                }
            } footer: {
                Text("See agent_docs/mvp.md for the full roadmap.")
            }
        }
        .navigationTitle("Roadmap")
        .navigationBarTitleDisplayMode(.inline)
    }
}
