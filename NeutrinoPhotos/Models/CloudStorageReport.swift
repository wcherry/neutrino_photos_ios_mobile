import Foundation

// MARK: - CloudStorageReport

/// Where the account's storage goes, by kind — the top half of the storage dashboard.
///
/// Built on the device from two things it already has: the library, which knows each item's size
/// and kind, and `GET /drive/quota`, which knows the account's total and its limit. The server
/// cannot break usage down by kind itself — it holds ciphertext and a MIME type, and only the photo
/// records say which files are photographs.
///
/// The difference between the two is reported rather than hidden. The account's total is every
/// Neutrino file: documents and Drive uploads as well as this library, plus the preview renditions
/// and Live Photo motion stored beside each photograph. Calling that "Other" keeps the bar adding
/// up to the figure the web app shows, which is what Epic 12's verification compares against.
struct CloudStorageReport: Equatable {

    var photos: Int64 = 0
    var videos: Int64 = 0
    /// Library items that are neither — a PDF that was registered as a photo, say.
    var otherLibrary: Int64 = 0
    /// Recently Deleted, which still counts against the quota until it is purged.
    var recentlyDeleted: Int64 = 0
    /// The account's total, when the quota has loaded.
    var usedBytes: Int64?
    /// The account's limit, or nil for none (or not loaded).
    var quotaBytes: Int64?
    /// Upload allowance per day, or nil for none.
    var dailyCapBytes: Int64?

    init(items: [MediaItem], trash: [MediaItem], quota: DriveQuota?) {
        for item in items {
            switch item.kind {
            case .photo: photos += item.sizeBytes
            case .video: videos += item.sizeBytes
            case .other: otherLibrary += item.sizeBytes
            }
        }
        recentlyDeleted = trash.reduce(0) { $0 + $1.sizeBytes }
        usedBytes = quota?.usedBytes
        quotaBytes = quota?.quotaBytes
        dailyCapBytes = quota?.dailyCapBytes
    }

    /// Everything this library accounts for.
    var libraryTotal: Int64 { photos + videos + otherLibrary + recentlyDeleted }

    /// The rest of the account: other Neutrino files, and the renditions stored beside each photo.
    /// Never negative — a listing a moment newer than the quota can briefly count more than it.
    var otherNeutrino: Int64? {
        usedBytes.map { max(0, $0 - libraryTotal) }
    }

    /// What is left, for an account with a limit.
    var freeBytes: Int64? {
        guard let quotaBytes, let usedBytes else { return nil }
        return max(0, quotaBytes - usedBytes)
    }

    /// How full the account is, 0...1, for an account with a limit.
    var fractionUsed: Double? {
        guard let quotaBytes, quotaBytes > 0, let usedBytes else { return nil }
        return min(1, Double(usedBytes) / Double(quotaBytes))
    }
}
