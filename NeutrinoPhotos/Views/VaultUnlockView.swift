import SwiftUI

// MARK: - VaultUnlockView

/// Recovers the account's encryption key from the server-side vault, using the encryption password
/// (or recovery code, or passkey) the user set up on the web.
///
/// This is the replacement for carrying a key file between devices: same account, same secret, no
/// file transfer. `KeyImportView` stays available beneath it for accounts created before the vault
/// existed, and for anyone who would rather move the file themselves.
///
/// The sheet is dismissible on purpose. A locked library still browses — the grid draws plaintext
/// cover thumbnails — so blocking the whole app behind this would hide photographs the user can
/// perfectly well look at. What the dismissed state gets is a banner, and a clear message anywhere
/// an original is needed.
struct VaultUnlockView: View {

    /// Called once the key is in the Keychain, so the caller can retry whatever was blocked on it.
    var onUnlocked: (() -> Void)?

    @EnvironmentObject private var vault: KeyVaultService

    @Environment(\.dismiss) private var dismiss

    @State private var secret = ""
    @State private var mode: Mode = .password
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var didUnlock = false

    private enum Mode {
        case password, recovery
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    if vault.status == .noVault {
                        noVaultGuidance
                    } else {
                        secretField
                        unlockButton
                        if hasPasskey { passkeyButton }
                        modeToggle
                    }

                    if didUnlock {
                        Label("Unlocked — your photos are available", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    footer
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Unlock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .task {
                // The unlock methods drive what this screen offers, and a sheet opened straight
                // from a banner may be the first thing that asks for them.
                if vault.vault == nil { await vault.refresh() }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.rectangle.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Unlock Your Photos")
                .font(.title3.weight(.semibold))
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var explanation: String {
        switch mode {
        case .password:
            return """
                   Enter your encryption password — the one that protects your key, not the password \
                   you sign in with.
                   """
        case .recovery:
            return "Enter the recovery code you saved when you set up encryption."
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var secretField: some View {
        Group {
            if mode == .recovery {
                TextField("Recovery code", text: $secret)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            } else {
                SecureField("Encryption password", text: $secret)
                    .textContentType(.password)
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(isWorking)
        .onSubmit { Task { await unlockWithSecret() } }
    }

    private var unlockButton: some View {
        Button {
            Task { await unlockWithSecret() }
        } label: {
            Group {
                if isWorking {
                    // Argon2id is deliberately expensive — around a second on an older phone — so
                    // the wait gets a name rather than an unexplained spinner.
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Unlocking…")
                    }
                } else {
                    Text("Unlock")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isWorking || secret.isEmpty)
    }

    private var hasPasskey: Bool {
        vault.availableMethods.contains { $0.method == "passkey" }
    }

    private var passkeyButton: some View {
        Button {
            Task { await unlockWithPasskey() }
        } label: {
            Label("Unlock with Passkey", systemImage: "person.badge.key")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
    }

    private var modeToggle: some View {
        Button(mode == .recovery ? "Use my encryption password instead"
                                 : "Use a recovery code instead") {
            mode = mode == .recovery ? .password : .recovery
            secret = ""
            errorMessage = nil
        }
        .font(.footnote)
        .disabled(isWorking)
    }

    // MARK: - No vault

    private var noVaultGuidance: some View {
        VStack(spacing: 14) {
            Text("""
                 This account has no encryption vault. Set one up in Neutrino on the web — \
                 Settings › Encryption — and unlock here afterwards.
                 """)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            NavigationLink {
                KeyImportView()
            } label: {
                Label("Import a key file instead", systemImage: "doc.badge.plus")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            if vault.status != .noVault {
                NavigationLink {
                    KeyImportView()
                } label: {
                    Text("Import a key file instead")
                        .font(.footnote)
                }
            }
            Text("""
                 Your password never leaves this device. It unwraps a key stored encrypted in your \
                 account, and the unwrapped key is kept in this device's Keychain — never carried \
                 to another device in an iCloud backup, and never sent to Neutrino.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func unlockWithSecret() async {
        guard !secret.isEmpty, !isWorking else { return }
        await run {
            switch mode {
            case .password: try await vault.unlock(password: secret)
            case .recovery: try await vault.unlock(recoveryCode: secret)
            }
        }
    }

    private func unlockWithPasskey() async {
        guard !isWorking else { return }
        await run { try await vault.unlockWithPasskey() }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await work()
            secret = ""
            didUnlock = true
            onUnlocked?()
            // A beat on the confirmation, so the unlock is visibly acknowledged rather than the
            // sheet simply vanishing.
            try? await Task.sleep(nanoseconds: 700_000_000)
            dismiss()
        } catch is CancellationError {
            // The user backed out of the passkey sheet; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
