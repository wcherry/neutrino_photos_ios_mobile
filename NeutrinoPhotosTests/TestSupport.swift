import CryptoKit
import Foundation
import XCTest
@testable import NeutrinoPhotos

// MARK: - TestKeys

/// Installs a real X25519 key pair into the Keychain so the encryption paths can be exercised for
/// what they actually are.
///
/// The crypto is deliberately *not* mocked. The `crypto_box_seal` / secretstream round trip is the
/// part of this app most expensive to get subtly wrong, and a fake that always "decrypts" would
/// assert nothing about it. libsodium's `crypto_box` uses X25519 keys, which is exactly what
/// `Curve25519.KeyAgreement` produces, so a CryptoKit-generated pair is interchangeable with the
/// one the web app exports.
enum TestKeys {

    /// Generates a pair and stores it under the same Keychain keys the app reads.
    @discardableResult
    static func install() -> KeyBundle {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let bundle = KeyBundle(
            publicKey: base64URL(priv.publicKey.rawRepresentation),
            privateKey: base64URL(priv.rawRepresentation),
            keyVersion: "1"
        )
        KeyImportService.storeKeys(bundle)
        return bundle
    }

    static func remove() {
        KeyImportService.removeKeys()
    }

    /// A valid key-file payload, in the format the web app exports.
    static func keyFileJSON() -> Data {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let dict = [
            "public_key": base64URL(priv.publicKey.rawRepresentation),
            "private_key": base64URL(priv.rawRepresentation),
            "key_version": "1",
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - TestTokens

/// Puts an access token in the Keychain so services believe they are signed in.
enum TestTokens {

    /// Decodes to `{"alg":"none","typ":"JWT"}.{"sub":"test-user-id"}.` — a real (if unsigned) JWT
    /// shape rather than an opaque string, because `AccessToken.currentUserID()` reads the `sub`
    /// claim out of it.
    static let userId = "test-user-id"
    static let defaultAccessToken =
        "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJ0ZXN0LXVzZXItaWQifQ."

    static func install(accessToken: String = TestTokens.defaultAccessToken) {
        KeychainService.save(accessToken, forKey: AuthService.accessTokenKey)
        // Far-future expiry so `refreshTokenIfNeeded` short-circuits and no test accidentally
        // depends on a refresh round trip it did not stub.
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        KeychainService.save(expiry, forKey: AuthService.tokenExpiryKey)
    }

    static func remove() {
        KeychainService.delete(forKey: AuthService.accessTokenKey)
        KeychainService.delete(forKey: AuthService.refreshTokenKey)
        KeychainService.delete(forKey: AuthService.tokenExpiryKey)
    }
}

// MARK: - TestServer

/// Points the app at a fixed host so assertions on request URLs are stable.
enum TestServer {
    static let host = "https://test.neutrino.local"

    static func use() {
        UserDefaults.standard.set(host, forKey: AuthService.serverHostKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: AuthService.serverHostKey)
    }
}

// MARK: - Fixtures

enum Fixture {

    /// A library item with sensible defaults, so a test only states what it cares about.
    static func item(id: String = "photo-1",
                     fileID: String = "file-1",
                     fileName: String = "IMG_0001.jpg",
                     mimeType: String = "image/jpeg",
                     sizeBytes: Int64 = 2_400_000,
                     thumbnailBase64: String? = nil,
                     isStarred: Bool = false,
                     isArchived: Bool = false,
                     captureDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
                     createdAt: Date = Date(timeIntervalSince1970: 1_700_100_000),
                     metadata: MediaMetadata? = nil) -> MediaItem {
        MediaItem(id: id, fileID: fileID, fileName: fileName, mimeType: mimeType,
                  sizeBytes: sizeBytes, thumbnailBase64: thumbnailBase64,
                  thumbnailMIMEType: thumbnailBase64 == nil ? nil : "image/jpeg",
                  isStarred: isStarred, isArchived: isArchived, captureDate: captureDate,
                  createdAt: createdAt, updatedAt: createdAt, metadata: metadata)
    }

    /// The RFC 3339 shape the Photos endpoints emit (`chrono`'s `to_rfc3339()`).
    static func rfc3339(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSXXXXX"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// One `PhotoResponse`, as the server serializes it.
    static func photoJSON(id: String = "photo-1",
                          fileID: String = "file-1",
                          fileName: String = "IMG_0001.jpg",
                          mimeType: String = "image/jpeg",
                          sizeBytes: Int = 2_400_000,
                          thumbnail: String? = nil,
                          isStarred: Bool = false,
                          isArchived: Bool = false,
                          captureDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
                          createdAt: Date = Date(timeIntervalSince1970: 1_700_100_000)) -> String {
        let thumbnailField = thumbnail.map { "\"\($0)\"" } ?? "null"
        let thumbnailMIME = thumbnail == nil ? "null" : "\"image/jpeg\""
        let capture = captureDate.map { "\"\(rfc3339($0))\"" } ?? "null"
        return """
        {"id":"\(id)","fileId":"\(fileID)","fileName":"\(fileName)","mimeType":"\(mimeType)",
         "sizeBytes":\(sizeBytes),"contentUrl":"/api/v1/drive/files/\(fileID)",
         "thumbnail":\(thumbnailField),"thumbnailMimeType":\(thumbnailMIME),
         "isStarred":\(isStarred),"isArchived":\(isArchived),"captureDate":\(capture),
         "createdAt":"\(rfc3339(createdAt))","updatedAt":"\(rfc3339(createdAt))","metadata":null}
        """
    }

    static func listingJSON(_ photos: [String]) -> Data {
        Data("""
        {"photos":[\(photos.joined(separator: ","))],"total":\(photos.count)}
        """.utf8)
    }

    /// One `AlbumResponse`.
    static func albumJSON(id: String = "album-1",
                          title: String = "Trip",
                          isAuto: Bool = false,
                          photoCount: Int = 0,
                          createdAt: Date = Date(timeIntervalSince1970: 1_700_100_000)) -> String {
        """
        {"id":"\(id)","title":"\(title)","description":null,"isAuto":\(isAuto),"personId":null,
         "photoCount":\(photoCount),"createdAt":"\(rfc3339(createdAt))",
         "updatedAt":"\(rfc3339(createdAt))"}
        """
    }
}

// MARK: - Temp directories

extension XCTestCase {

    /// A unique empty directory, removed when the test finishes.
    func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NeutrinoPhotosTests-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            XCTFail("Could not create temp directory: \(error)", file: file, line: line)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// A `UserDefaults` suite of its own, removed when the test finishes, so a settings test cannot
    /// disturb the simulator's real preferences or another test's.
    func makeTemporaryDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let name = "NeutrinoPhotosTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            XCTFail("Could not create UserDefaults suite", file: file, line: line)
            return .standard
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
