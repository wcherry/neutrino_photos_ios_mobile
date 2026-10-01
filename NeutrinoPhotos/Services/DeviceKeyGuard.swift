import Foundation
import os.log
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - PublishedKey

/// The account's **active** identity key, as the server's key directory publishes it
/// (`GET /api/v1/auth/users/{id}/public-key`).
///
/// This is the key every other client seals to and opens with. The web keeps nothing else: its
/// keyring is exactly the directory's versions, so a DEK sealed to any other key is a photo the web
/// can never open.
struct PublishedKey: Equatable, Decodable {
    let publicKey: String
    let version: Int
}

// MARK: - DeviceKeyStatus

/// Whether the key in this device's Keychain is the one the account publishes.
enum DeviceKeyStatus: Equatable {
    /// It is. New photos may be sealed to it, filed under `version`.
    case current(version: Int)
    /// It is not. Anything sealed to it opens on this device and nowhere else.
    case stale(published: PublishedKey)
    /// The account publishes no key at all, so there is nothing to check the device's against.
    case unpublished

    /// Compares the stored public key with the published one, as bytes — a key file may carry
    /// padding the directory does not, and the same key must not read as two.
    static func of(storedPublicKey: String, published: PublishedKey?) -> DeviceKeyStatus {
        guard let published else { return .unpublished }
        guard let stored = KeyVaultCrypto.decodeBase64URL(storedPublicKey),
              let current = KeyVaultCrypto.decodeBase64URL(published.publicKey),
              stored == current else {
            return .stale(published: published)
        }
        return .current(version: published.version)
    }
}

// MARK: - DeviceKeyRewrap

/// Moves one photo's DEK from this device's stale key onto the account's published key.
///
/// Pure and static so the one step that can make a photo unreadable — what gets sealed to whom — is
/// testable without a network or a Keychain.
enum DeviceKeyRewrap {

    /// The ref to file in place of `ref`, or nil when this device's key does not open it.
    ///
    /// Nil is the common answer and not a failure: anything uploaded from the web or a healthy
    /// device was sealed to the published key, which this device (holding a different one) cannot
    /// open. Those refs are already right and are left alone.
    ///
    /// Sealing needs only the published *public* key, which is why a device that does not hold the
    /// account's current secret can still repair the photos only it can open.
    static func rewrap(_ ref: SealedFileKey, deviceKey: KeyBundle,
                       to published: PublishedKey) -> SealedFileKey? {
        guard let publicKey = KeyVaultCrypto.decodeBase64URL(deviceKey.publicKey),
              let secretKey = KeyVaultCrypto.decodeBase64URL(deviceKey.privateKey),
              let recipient = KeyVaultCrypto.decodeBase64URL(published.publicKey),
              let dek = try? MediaCrypto.openDEK(ref.sealed, publicKey: publicKey, secretKey: secretKey),
              let sealed = try? MediaCrypto.seal(dek: dek, toPublicKey: recipient) else {
            return nil
        }
        return SealedFileKey(sealed: sealed, keyVersion: published.version)
    }
}

// MARK: - DeviceKeyRepairReport

struct DeviceKeyRepairReport: Equatable {
    /// Photos whose key was moved onto the account's key. These now open everywhere.
    var rewrapped = 0
    /// Files this device's key does not open — sealed to the account's key already.
    var alreadyCorrect = 0
    /// Files with no key ref (not encrypted).
    var unencrypted = 0
    /// A read or write that failed after retries. Running the pass again picks these up.
    var failed = 0

    var examined: Int { rewrapped + alreadyCorrect + unencrypted + failed }

    var summary: String {
        var parts = ["\(rewrapped) repaired"]
        if failed > 0 { parts.append("\(failed) failed — run again to retry") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - DeviceKeyRepairState

enum DeviceKeyRepairState: Equatable {
    case unknown
    /// This device's key is the account's key. Nothing to do.
    case current
    /// It is not, and the repair pass has not run (or is about to).
    case stale
    case running(examined: Int, rewrapped: Int)
    /// The pass finished. The device is still stale — it needs the account's current key — but
    /// nothing it uploaded is unreadable elsewhere any more.
    case repaired(DeviceKeyRepairReport)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// True while photos exist that only this device's key opens. Removing the key then destroys
    /// them, so the UI holds the "remove key" action back.
    var keyMustBeKept: Bool {
        switch self {
        case .stale, .running, .failed: return true
        case .repaired(let report):     return report.failed > 0
        case .unknown, .current:        return false
        }
    }
}

// MARK: - DeviceKeyGuard

/// Answers "is this device's key still the account's key?" before anything is sealed to it, and
/// repairs what was sealed to it when it is not.
///
/// ## Why this exists
///
/// Uploads sealed to whatever public key was in the Keychain and asked nothing — unless the account
/// had a key vault, which accounts set up since the client-only key architecture do not. When an
/// account's key was replaced from another device, a device that kept its old key went on sealing
/// every photo to it, and recording the ref under the number the new key has. Nothing failed here;
/// every other client got "this file's key does not open with any encryption key this device
/// holds". Neutrino Drive did exactly this to 374 photos over two weeks.
///
/// ## The check
///
/// One small GET, cached for ``cacheLifetime`` against the exact public key it checked, so a
/// library import of a thousand photos costs one request rather than a thousand — and a key
/// imported mid-import is checked afresh.
///
/// ## The repair
///
/// A photo sealed to this device's old key can be opened by exactly one secret in the world: the
/// one in this device's Keychain. So the repair can only happen here, and only *before* that key is
/// replaced. It walks every file the caller owns and, for each ref the device's key opens, re-seals
/// the same DEK to the published key. Ciphertext untouched, only the caller's own ref, and a ref the
/// device's key does not open is left alone — so an interrupted or repeated pass leaves every photo
/// readable by at least the key it was readable by before.
@MainActor
final class DeviceKeyGuard: ObservableObject {

    @Published private(set) var state: DeviceKeyRepairState = .unknown

    /// How long a `.current` answer is trusted. Short: a key replaced on another device should stop
    /// this one sealing within minutes, not at the next launch.
    static let cacheLifetime: TimeInterval = 10 * 60
    static let pageSize = 200
    /// Key reads in flight at once. One ref per file in the drive is the better part of an hour in
    /// series on a large library.
    static let concurrency = 6
    static let backoff: [TimeInterval] = [1, 4, 16]

    private let api: APIClient
    private var verified: (publicKey: String, version: Int, at: Date)?
    private var inFlight = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "DeviceKeyGuard")

    init(api: APIClient) {
        self.api = api
    }

    // MARK: - Sealing

    /// The version to file a new photo's key under — the account's number for the key this device
    /// holds — or a throw when this device's key is not the account's.
    ///
    /// - Throws: `MediaContentError.noEncryptionKey` with no key stored,
    ///   `MediaContentError.staleEncryptionKey` when the key is not the published one (or the
    ///   account publishes none), and the transport's error when the directory cannot be asked —
    ///   which an import treats as retryable, like any other network failure.
    func sealingVersion() async throws -> Int {
        guard let stored = KeyImportService.storedKeys() else {
            throw MediaContentError.noEncryptionKey
        }
        if let verified, verified.publicKey == stored.publicKey,
           Date().timeIntervalSince(verified.at) < Self.cacheLifetime {
            return verified.version
        }
        let status = DeviceKeyStatus.of(storedPublicKey: stored.publicKey,
                                        published: try await fetchPublished())
        guard case .current(let version) = status else {
            verified = nil
            if state == .unknown || state == .current { state = .stale }
            logger.error("sealingVersion: device key is not the account's key; refusing to seal")
            throw MediaContentError.staleEncryptionKey
        }
        verified = (stored.publicKey, version, Date())
        return version
    }

    /// Forgets a cached answer. Called when the stored key changes, and by tests.
    func forget() {
        verified = nil
    }

    // MARK: - Repair

    /// Checks this device's key against the account's, and repairs straight away if it is stale.
    func checkAndRepair() async {
        // Launch and the first foreground both ask; the flag is set before the first await so the
        // second caller cannot start a second pass while the first is still reading the key.
        guard !inFlight, let stored = KeyImportService.storedKeys() else { return }
        inFlight = true
        defer { inFlight = false }

        let published: PublishedKey?
        do {
            published = try await fetchPublished()
        } catch {
            // Offline, most likely. Uploads check for themselves; the next foreground asks again.
            logger.error("checkAndRepair: could not read the account's key: \(error.localizedDescription, privacy: .public)")
            return
        }

        switch DeviceKeyStatus.of(storedPublicKey: stored.publicKey, published: published) {
        case .current(let version):
            verified = (stored.publicKey, version, Date())
            state = .current
        case .unpublished:
            verified = nil
            state = .stale
        case .stale(let published):
            verified = nil
            state = .stale
            await repair(to: published, deviceKey: stored)
        }
    }

    private func repair(to published: PublishedKey, deviceKey: KeyBundle) async {
        logger.info("repair: device key is stale; re-sealing its photos to account key v\(published.version, privacy: .public)")
        var report = DeviceKeyRepairReport()
        state = .running(examined: 0, rewrapped: 0)
        var offset = 0

        while true {
            let ids: [String]
            do {
                let path = "/api/v1/drive/files?limit=\(Self.pageSize)&offset=\(offset)&orderBy=createdAt&direction=asc"
                let page: FileListPage = try await withBackoff {
                    try await self.api.get(path, decoder: JSONDecoder())
                }
                ids = page.files.map(\.id)
            } catch {
                logger.error("repair: listing failed at offset \(offset): \(error.localizedDescription, privacy: .public)")
                state = .failed("Could not list your files: \(error.localizedDescription)")
                return
            }
            if ids.isEmpty { break }

            for chunk in stride(from: 0, to: ids.count, by: Self.concurrency) {
                let slice = ids[chunk..<min(chunk + Self.concurrency, ids.count)]
                let outcomes = await withTaskGroup(of: Outcome.self) { group in
                    for id in slice {
                        group.addTask { await self.repairOne(fileID: id, published: published, deviceKey: deviceKey) }
                    }
                    var all: [Outcome] = []
                    for await outcome in group { all.append(outcome) }
                    return all
                }
                for outcome in outcomes {
                    switch outcome {
                    case .rewrapped:      report.rewrapped += 1
                    case .alreadyCorrect: report.alreadyCorrect += 1
                    case .unencrypted:    report.unencrypted += 1
                    case .failed:         report.failed += 1
                    }
                }
                state = .running(examined: report.examined, rewrapped: report.rewrapped)
            }

            // Oldest first, so photos uploaded while the pass runs land after the cursor rather
            // than shifting the pages under it.
            if ids.count < Self.pageSize { break }
            offset += Self.pageSize
        }

        logger.info("repair: finished — \(report.rewrapped) re-sealed, \(report.alreadyCorrect) already right, \(report.failed) failed")
        state = .repaired(report)
    }

    private enum Outcome { case rewrapped, alreadyCorrect, unencrypted, failed }

    private func repairOne(fileID: String, published: PublishedKey, deviceKey: KeyBundle) async -> Outcome {
        let ref: KeyRef?
        do {
            ref = try await withBackoff {
                try await self.api.getIfPresent("/api/v1/drive/files/\(fileID)/key", decoder: JSONDecoder())
            }
        } catch {
            logger.error("repair: reading key for \(fileID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        guard let ref else { return .unencrypted }
        guard let rewrapped = DeviceKeyRewrap.rewrap(
            SealedFileKey(sealed: ref.encryptedFileKey, keyVersion: ref.keyVersion ?? 1),
            deviceKey: deviceKey, to: published
        ) else {
            return .alreadyCorrect
        }
        do {
            _ = try await withBackoff {
                try await self.api.send(method: "PUT", path: "/api/v1/drive/files/\(fileID)/key",
                                        json: KeyRefBody(encryptedFileKey: rewrapped.sealed,
                                                         keyVersion: rewrapped.keyVersion))
            }
            return .rewrapped
        } catch {
            logger.error("repair: writing key for \(fileID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    // MARK: - Network

    /// The account's active key, or nil when it publishes none.
    private func fetchPublished() async throws -> PublishedKey? {
        guard let userID = AccessToken.currentUserID() else { throw MediaContentError.notAuthenticated }
        return try await api.getIfPresent("/api/v1/auth/users/\(userID)/public-key", decoder: JSONDecoder())
    }

    /// Retries what describes a moment rather than a request: a transport error, 408, 429, 5xx.
    private func withBackoff<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < Self.backoff.count, Self.isRetryable(error) else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(Self.backoff[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }

    nonisolated static func isRetryable(_ error: Error) -> Bool {
        switch error as? APIError {
        case .network:                return true
        case .server(let code):       return code == 408 || code == 429 || code >= 500
        default:                      return false
        }
    }

    private struct FileListPage: Decodable {
        struct File: Decodable { let id: String }
        let files: [File]
    }

    private struct KeyRef: Decodable {
        let encryptedFileKey: String
        let keyVersion: Int?
    }

    private struct KeyRefBody: Encodable {
        let encryptedFileKey: String
        let keyVersion: Int
    }
}
