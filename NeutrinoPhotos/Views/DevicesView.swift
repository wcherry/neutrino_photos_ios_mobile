import SwiftUI
import NeutrinoAuth

// MARK: - DevicesView

/// The devices signed in to this account, and the date each of them registered.
///
/// Registration is a property of signing in rather than a call of its own — a device names itself in
/// `X-Device-Name` and the server records that on the session row. So "registered" here is honestly
/// labelled as when this device signed in, which is the same moment.
struct DevicesView: View {

    @EnvironmentObject private var devices: DeviceSessionService

    @State private var pendingRevocation: DeviceSession?

    // MARK: - Body

    var body: some View {
        List {
            if let error = devices.error {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if devices.sessions.isEmpty && !devices.isLoading {
                    Text("No devices to show.")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices.sessions) { session in
                    row(for: session)
                }
            } footer: {
                Text("""
                     Revoking signs that device out. It cannot delete the encryption key already on \
                     it — nothing can reach across and do that — but the device stops being able to \
                     fetch anything new.
                     """)
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if devices.isLoading && devices.sessions.isEmpty {
                ProgressView()
            }
        }
        .task { await devices.load() }
        .refreshable { await devices.load() }
        .confirmationDialog("Sign this device out?",
                            isPresented: .init(get: { pendingRevocation != nil },
                                               set: { if !$0 { pendingRevocation = nil } }),
                            titleVisibility: .visible) {
            Button("Sign Out Device", role: .destructive) {
                guard let session = pendingRevocation else { return }
                pendingRevocation = nil
                Task { await devices.revoke(id: session.id) }
            }
        } message: {
            Text(pendingRevocation.map { session in
                devices.isCurrentDevice(session)
                    ? "This looks like the device you're using. Signing it out will sign you out here."
                    : "\(session.displayName) will have to sign in again."
            } ?? "")
        }
    }

    // MARK: - Row

    private func row(for session: DeviceSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.displayName)
                    .font(.body)
                if devices.isCurrentDevice(session) {
                    Text("This device")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            Text("Registered \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lastUsed = session.lastUsedAt {
                Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let ip = session.ipAddress {
                // Already anonymised by the server — the last octet is dropped before it is sent.
                Text(ip)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions {
            Button("Sign Out", role: .destructive) { pendingRevocation = session }
        }
    }
}
