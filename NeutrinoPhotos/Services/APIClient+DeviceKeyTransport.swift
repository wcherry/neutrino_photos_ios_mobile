import Foundation
import NeutrinoAuth
import NeutrinoCrypto

// MARK: - DeviceKeyTransport

/// The requests the shared device-key check and repair make (`DeviceKeyCheck`,
/// `DeviceKeyRepairService` in NeutrinoCrypto), through this client's token refresh and session.
extension APIClient: DeviceKeyTransport {

    /// The account's active published key, or nil when it publishes none.
    func publishedKey() async throws -> PublishedKey? {
        guard let userID = AccessToken.currentUserID() else { throw APIError.notAuthenticated }
        return try await getIfPresent("/api/v1/auth/users/\(userID)/public-key", decoder: JSONDecoder())
    }

    /// Every file the caller owns, whatever folder — photographs go to the Drive root, previews to
    /// their own folder, and both were sealed by this device.
    func fileIDsPage(limit: Int, offset: Int) async throws -> [String] {
        let page: FileIDPage = try await get(
            "/api/v1/drive/files?limit=\(limit)&offset=\(offset)&orderBy=createdAt&direction=asc",
            decoder: JSONDecoder())
        return page.files.map(\.id)
    }

    func fileKey(fileID: String) async throws -> (sealed: String, keyVersion: Int)? {
        let ref: KeyRef? = try await getIfPresent("/api/v1/drive/files/\(fileID)/key", decoder: JSONDecoder())
        return ref.map { ($0.encryptedFileKey, $0.keyVersion ?? 1) }
    }

    /// Touches no one else's row — the server keys `PUT /files/{id}/key` on the caller.
    func setFileKey(fileID: String, sealed: String, keyVersion: Int) async throws {
        _ = try await send(method: "PUT", path: "/api/v1/drive/files/\(fileID)/key",
                           json: KeyRefBody(encryptedFileKey: sealed, keyVersion: keyVersion))
    }

    /// A transport error, 408, 429 or 5xx describes a moment rather than the request.
    nonisolated func isRetryable(_ error: Error) -> Bool {
        switch error as? APIError {
        case .network:          return true
        case .server(let code): return code == 408 || code == 429 || code >= 500
        default:                return false
        }
    }
}

private struct FileIDPage: Decodable {
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
