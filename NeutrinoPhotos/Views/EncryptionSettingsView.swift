import SwiftUI

// MARK: - EncryptionSettingsView

/// Everything about the account's encryption key in one screen: whether this device holds it, how it
/// can be recovered, and which devices are signed in.
///
/// The two halves are deliberately together. "Which devices can reach my photographs?" is one
/// question with two answers — a device needs a session *and* the key — and a screen that showed only
/// one of them would be quietly misleading.
struct EncryptionSettingsView: View {

    @EnvironmentObject private var vault: KeyVaultService

    @State private var showsUnlock = false
    @State private var showsLockConfirmation = false

    // MARK: - Body

    var body: some View {
        List {
            statusSection
            if !vault.availableMethods.isEmpty { unlockMethodsSection }
            keyFileSection
            devicesSection
        }
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vault.refresh() }
        .refreshable { await vault.refresh() }
        .sheet(isPresented: $showsUnlock) {
            VaultUnlockView()
                .environmentObject(vault)
        }
        .confirmationDialog("Remove the encryption key from this device?",
                            isPresented: $showsLockConfirmation, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { vault.lock() }
        } message: {
            Text("""
                 Photos already uploaded stay encrypted and unreadable on this device until you \
                 unlock again. Nothing is deleted from your account.
                 """)
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                Label(statusText, systemImage: statusSymbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(statusTint)
            }

            if vault.keyBelongsToAnotherAccount {
                Label("""
                      The key on this device belongs to a different account. Unlock to replace it.
                      """, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            switch vault.status {
            case .unlocked:
                Button("Remove key from this device", role: .destructive) {
                    showsLockConfirmation = true
                }
            case .locked, .noVault, .unreachable, .unknown:
                Button("Unlock") { showsUnlock = true }
            }
        } header: {
            Text("This device")
        } footer: {
            Text(statusFooter)
        }
    }

    private var statusText: String {
        switch vault.status {
        case .unlocked:    return "Unlocked"
        case .locked:      return "Locked"
        case .noVault:     return "No key"
        case .unreachable: return "Unknown"
        case .unknown:     return "Checking…"
        }
    }

    private var statusSymbol: String {
        switch vault.status {
        case .unlocked:    return "lock.open.fill"
        case .locked:      return "lock.fill"
        case .noVault:     return "key.slash"
        case .unreachable: return "wifi.exclamationmark"
        case .unknown:     return "hourglass"
        }
    }

    private var statusTint: Color {
        switch vault.status {
        case .unlocked:                       return .green
        case .locked, .noVault:               return .orange
        case .unreachable, .unknown:          return .secondary
        }
    }

    private var statusFooter: String {
        switch vault.status {
        case .unlocked:
            return """
                   Photos are encrypted on this device before upload, and the key never leaves it. \
                   Browsing the timeline works either way — grid previews are stored unencrypted \
                   with each file — but opening an original needs the key.
                   """
        case .locked:
            return """
                   Your account has an encryption key and this device does not hold it. The timeline \
                   still browses; opening an original or uploading a new photo needs an unlock.
                   """
        case .noVault:
            return """
                   This account has no encryption vault. Create one in Neutrino on the web, or \
                   import a key file below.
                   """
        case .unreachable:
            return "Your account's key vault could not be reached. Check your connection and pull to refresh."
        case .unknown:
            return "Checking your account's key vault."
        }
    }

    // MARK: - Unlock methods

    private var unlockMethodsSection: some View {
        Section {
            ForEach(vault.availableMethods) { method in
                VStack(alignment: .leading, spacing: 2) {
                    Label(Self.methodName(method.method), systemImage: Self.methodSymbol(method.method))
                    if !method.label.isEmpty {
                        Text(method.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let lastUsed = method.lastUsedAt {
                        Text("Last used \(Self.shortDate(lastUsed))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Ways to unlock")
        } footer: {
            Text("""
                 Each one holds its own encrypted copy of the same key. They are enrolled in \
                 Neutrino on the web; this app opens them but does not add or remove them.
                 """)
        }
    }

    private static func methodName(_ method: String) -> String {
        switch method {
        case "password": return "Encryption password"
        case "recovery": return "Recovery code"
        case "passkey":  return "Passkey"
        default:         return method.capitalized
        }
    }

    private static func methodSymbol(_ method: String) -> String {
        switch method {
        case "password": return "key"
        case "recovery": return "lifepreserver"
        case "passkey":  return "person.badge.key"
        default:         return "questionmark.key.filled"
        }
    }

    /// The vault endpoints return RFC 3339 strings rather than the shapes `DriveDate` decodes into
    /// `Date`, and these are only ever displayed — so they are parsed here rather than in the model.
    private static func shortDate(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) ?? DriveDate.date(from: raw) else {
            return raw
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Key file

    private var keyFileSection: some View {
        Section {
            NavigationLink(KeyImportService.hasStoredKeys() ? "Replace with a key file"
                                                            : "Import a key file") {
                KeyImportView()
            }
        } header: {
            Text("Key file")
        } footer: {
            Text("""
                 The JSON file Neutrino exports on the web. Tapping one that has been AirDropped or \
                 saved to Files opens it here too.
                 """)
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        Section {
            NavigationLink("Devices") { DevicesView() }
        } footer: {
            Text("Every device signed in to this account, and when each of them registered.")
        }
    }
}
