import SwiftUI
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - SettingsView

/// Preferences, the account, and the state of the encryption key.
///
/// Grouped the way Epic 12 lays it out — Backup, Privacy, Storage, Account — with the library's own
/// display preferences first. Every switch here changes what the app does; a setting for a feature
/// that does not exist yet (automatic backup's conditions, say) is left out rather than shown as a
/// switch that does nothing.
struct SettingsView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var content: MediaContentService
    @EnvironmentObject private var importer: PhotoImportService
    @EnvironmentObject private var monitor: NetworkMonitor
    @EnvironmentObject private var vault: KeyVaultService
    @EnvironmentObject private var drive: PhotosDriveService
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary
    @EnvironmentObject private var ledger: ImportLedger
    @EnvironmentObject private var libraryImporter: LibraryImportService

    @State private var deviceName = DeviceIdentity.deviceName
    @State private var showsSignOutConfirmation = false
    @State private var storage: MediaContentService.StorageBreakdown?

    // MARK: - Body

    var body: some View {
        List {
            librarySection
            backupSection
            deviceLibrarySection
            privacySection
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

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            LabeledContent("Automatic backup", value: "Not available yet")
            Toggle("Upload over Wi-Fi only", isOn: $settings.wifiOnlyUploads)
            LabeledContent("Connection", value: connectionDescription)
            LabeledContent("Uploads", value: "Full resolution")
            Button("Forget import history") { importer.forgetImportHistory() }
                .disabled(ledger.count == 0)
        } header: {
            Text("Backup")
        } footer: {
            Text("""
                 Photos and videos upload at the resolution the camera wrote them; HEIC photos are \
                 stored as full-resolution JPEG so every device and browser can open them. With \
                 Wi-Fi only on, an import waits rather than using cellular data. Backing up new \
                 photos automatically — and its charging and video options — arrives with \
                 automatic backup; until then, import from the Library tab.

                 This device remembers \(ledger.count) uploaded item(s) — by their identity in \
                 Apple Photos and by a hash of their bytes — so importing the same photos twice \
                 doesn't duplicate them. The record is local: the server stores only ciphertext and \
                 cannot compare two photos for sameness.
                 """)
        }
    }

    /// What the Import library row says on its right-hand side — the state a user would want to see
    /// without opening it, which is almost always "is it still going".
    private var libraryImportSummary: String {
        switch libraryImporter.phase {
        case .scanning:                return "Scanning…"
        case .running, .waiting:       return "\(libraryImporter.counts.pending) left"
        case .interrupted:             return "Paused — \(libraryImporter.counts.pending) left"
        case .paused where libraryImporter.counts.hasWorkLeft:
            return "Paused — \(libraryImporter.counts.pending) left"
        case .finished, .paused, .idle:
            return libraryImporter.lastCompletedAt == nil ? "" : "Up to date"
        }
    }

    private var connectionDescription: String {
        guard monitor.isOnline else { return "Offline" }
        return monitor.isExpensive ? "Cellular" : "Wi-Fi"
    }

    // MARK: - Device photo library

    private var deviceLibrarySection: some View {
        Section {
            NavigationLink {
                PhotoAccessView()
            } label: {
                LabeledContent("Photo library access", value: deviceLibrary.access.displayName)
            }
            NavigationLink {
                LibraryImportView()
            } label: {
                LabeledContent("Import library", value: libraryImportSummary)
            }
            Toggle("Keep Live Photo motion", isOn: $settings.importsLivePhotoMotion)
                .disabled(!deviceLibrary.access.isUsable)
        } header: {
            Text("This Device's Photos")
        } footer: {
            Text("""
                 Importing needs no permission — the photo picker runs outside the app. Access adds \
                 what the picker can't hand over: the real capture date, favorites, Live Photo \
                 motion, and RAW originals.
                 """)
        }
    }

    // MARK: - Privacy

    /// What leaves the device that is not the photograph.
    ///
    /// Worth its own section rather than a line in Uploads: the picture is end-to-end encrypted and
    /// the server cannot read a pixel of it, so the metadata index is the only thing about somebody's
    /// library that Neutrino *can* see. Saying so, and letting the user draw the line, is the whole
    /// point of the section.
    private var privacySection: some View {
        Section {
            NavigationLink {
                EncryptionSettingsView()
            } label: {
                LabeledContent("Encryption", value: keyStateDescription)
            }
            Toggle("Include location in cloud metadata", isOn: $settings.publishesLocationMetadata)
            LabeledContent("Analytics", value: "None collected")
        } header: {
            Text("Privacy")
        } footer: {
            Text("""
                 Your photos are encrypted on this device before they upload, and the key never \
                 leaves it, so Neutrino can't read them. Grid thumbnails are stored unencrypted \
                 with each file so the timeline browses without a key; opening an original needs \
                 one.

                 The library's index — size, camera, exposure, dates, titles — is not encrypted, \
                 because the server sorts and searches it. Coordinates are held back from that \
                 index unless you turn location on; this device keeps them either way.

                 This app sends no analytics or crash reports. Reporting a bug opens a GitHub form \
                 you read and submit yourself.
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
            LabeledContent("On this device", value: bytes(storage?.total))
            NavigationLink("Manage Storage") {
                StorageView()
                    .onDisappear { Task { storage = await content.storageBreakdown() } }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("""
                 What your library uses in your account and on this device, and ways to free \
                 space here without removing anything from your account.
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
            NavigationLink("Devices and sessions") { DevicesView() }
            NavigationLink {
                EncryptionSettingsView()
            } label: {
                LabeledContent("Encryption keys", value: keyStateDescription)
            }
            if let quota = drive.quota {
                LabeledContent("Storage plan", value: Self.planDescription(quota))
                if let cap = quota.dailyCapBytes {
                    LabeledContent("Daily upload limit",
                                   value: ByteCountFormatter.string(fromByteCount: cap,
                                                                    countStyle: .file))
                }
            }
            LabeledContent("Server", value: AuthService.baseURL)
            Button("Sign out", role: .destructive) { showsSignOutConfirmation = true }
        } header: {
            Text("Account")
        } footer: {
            Text("The device name identifies this session in your account's device list. It is sent when you sign in, so a change takes effect at the next sign-in.")
        }
    }

    /// "15 GB" or "Unlimited" — the server's quota is the plan; it has no plan names.
    private static func planDescription(_ quota: DriveQuota) -> String {
        guard let limit = quota.quotaBytes else { return "Unlimited" }
        return ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}
