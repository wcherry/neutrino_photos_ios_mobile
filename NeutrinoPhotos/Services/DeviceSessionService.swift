import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth

// MARK: - DeviceSession

/// One device signed in to the account, as `GET /api/v1/auth/sessions` reports it.
///
/// A "device" here is a refresh-token row. That is not a modelling shortcut — Neutrino has no
/// separate device registry, and a device names itself in `X-Device-Name` when it signs in (see
/// `AuthService.step1Login` and `DeviceIdentity`). So the registration date of this device *is*
/// `createdAt`, and revoking a device is deleting the session it holds.
struct DeviceSession: Decodable, Equatable, Identifiable {
    let id: String
    let deviceName: String?
    let userAgent: String?
    /// Anonymised by the server before it is sent — the last octet is dropped.
    let ipAddress: String?
    let createdAt: Date
    let lastUsedAt: Date?

    var displayName: String {
        guard let deviceName, !deviceName.isEmpty else { return "Unnamed device" }
        return deviceName
    }
}

private struct DeviceSessionListResponse: Decodable {
    let sessions: [DeviceSession]
}

// MARK: - DeviceSessionService

/// The account's devices: which ones hold a session, and revoking one that shouldn't.
///
/// Sits beside the encryption settings because that is the question it answers — "which devices can
/// reach my photographs?" — even though the mechanism is a token rather than a key. The key half of
/// that answer is the vault's enrolled unlock methods, listed from `KeyVaultService.vault`; the two
/// are shown together in ``EncryptionSettingsView`` for exactly that reason.
@MainActor
final class DeviceSessionService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    // MARK: - Dependencies

    private let api: APIClient

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "DeviceSessionService")

    /// `SessionResponse` is camelCase on the wire but its timestamps are zone-less
    /// `NaiveDateTime`, which is what `DriveDate` exists to read.
    private static let decoder = DriveDate.makeDecoder()

    // MARK: - Init

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Listing

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: DeviceSessionListResponse = try await api.get("/api/v1/auth/sessions",
                                                                        decoder: Self.decoder)
            // Most recently used first, with never-used sessions falling back to when they were
            // created, so the device in the user's hand is at the top rather than buried.
            sessions = response.sessions.sorted {
                ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
            }
            error = nil
            logger.debug("loaded \(self.sessions.count) session(s)")
        } catch where error.isCancellation {
            logger.debug("session load cancelled")
        } catch {
            self.error = error.localizedDescription
            logger.error("session load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Revoking

    /// Signs a device out. It loses its refresh token immediately and its access token at expiry.
    ///
    /// The encryption key already on that device is untouched — nothing can reach across and delete
    /// it, which is worth being honest about on screen rather than implying a revoke wipes the
    /// device. What it does stop is that device fetching anything new.
    func revoke(id: String) async {
        do {
            _ = try await api.send(method: "DELETE", path: "/api/v1/auth/sessions/\(id)")
            sessions.removeAll { $0.id == id }
            error = nil
            logger.debug("revoked session \(id, privacy: .public)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Whether a listed session is the one this app is using.
    ///
    /// Matched by name, because the sessions endpoint returns no marker for "this is you" and the
    /// token carries no session id. That makes it a heuristic: two phones the user gave the same
    /// name are indistinguishable here, so it labels rather than protects — revoking is confirmed
    /// either way.
    func isCurrentDevice(_ session: DeviceSession) -> Bool {
        session.deviceName == DeviceIdentity.deviceName
    }
}
