import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers
import os.log

// MARK: - DeviceLibraryError

enum DeviceLibraryError: LocalizedError {
    case notAuthorized
    case assetUnavailable
    case resourceUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Neutrino Photos doesn't have permission to use your photo library."
        case .assetUnavailable:
            return "That item is no longer in this device's photo library."
        case .resourceUnavailable:
            return "This device couldn't read the original file for that item."
        }
    }
}

// MARK: - DeviceAsset

/// What the device's photo library knows about one item, flattened out of `PHAsset`.
///
/// A value rather than the `PHAsset` itself, deliberately: `PHAsset` is a live object bound to the
/// Photos framework, and passing one into the import pipeline would spread `import Photos` across
/// everything it touches and make every one of those types untestable without a real photo library.
/// Everything the importer actually needs is here, and it is all `Sendable`.
struct DeviceAsset: Equatable {

    let localIdentifier: String
    /// When the photograph was taken, as Apple Photos records it.
    ///
    /// More reliable than EXIF, and the reason to want library access at all for dates: a screenshot,
    /// a screen recording, an AirDropped picture, and anything exported from an editor carry no
    /// `DateTimeOriginal` — so the EXIF path files all of them under their upload time, which is
    /// exactly the failure verification step 2 looks for.
    let creationDate: Date?
    let coordinate: (latitude: Double, longitude: Double)?
    /// Favourited in Apple Photos. Carried across so a library arrives with its stars already on.
    let isFavorite: Bool
    let isLivePhoto: Bool
    /// The device holds a RAW original for this item — a DNG from a camera or from ProRAW.
    let isRAW: Bool
    /// `PHAssetMediaSubtype` names: "panorama", "screenshot", "hdr", "portrait", "slowMotion",
    /// "timelapse". Stored now; v1.1's Screenshots and Panoramas views are what read them.
    let subtypes: [String]
    let pixelWidth: Int?
    let pixelHeight: Int?

    static func == (lhs: DeviceAsset, rhs: DeviceAsset) -> Bool {
        lhs.localIdentifier == rhs.localIdentifier
            && lhs.creationDate == rhs.creationDate
            && lhs.coordinate?.latitude == rhs.coordinate?.latitude
            && lhs.coordinate?.longitude == rhs.coordinate?.longitude
            && lhs.isFavorite == rhs.isFavorite
            && lhs.isLivePhoto == rhs.isLivePhoto
            && lhs.isRAW == rhs.isRAW
            && lhs.subtypes == rhs.subtypes
    }
}

// MARK: - DeviceOriginal

/// An untranscoded original written out of the photo library, and what it turned out to be.
struct DeviceOriginal {
    let url: URL
    let mimeType: String
    let fileExtension: String
    let originalFileName: String?
}

// MARK: - DevicePhotoLibrary

/// The device's own photo library, in both directions: reading what Apple Photos knows about an
/// item, and writing one back into it.
///
/// ## Why this exists when the picker needs no permission
///
/// `PhotosPicker` runs out of process and hands back only the items the user chose, which is why
/// importing has never needed an authorization prompt and why this app has never seen the rest of
/// the roll. That is the right default and it stays the default. But a picker item is *bytes*, and
/// a photo library is more than bytes:
///
/// | Needs `PHPhotoLibrary` | Why the picker cannot give it |
/// |---|---|
/// | The real creation date | a screenshot has no EXIF; the file says nothing about when it was taken |
/// | Favourite status | a flag on the library's record, not on the file |
/// | Live Photo motion | the paired video is a second `PHAssetResource`, not part of the still |
/// | The RAW original | the picker hands back a compatible rendering of a DNG, not the DNG |
/// | Coordinates for an edited export | editors drop the GPS block; Apple Photos keeps its own copy |
/// | Full-library and automatic import | there is no picker; the library has to be enumerated (Epics 6 and 7) |
///
/// So access is *offered* rather than demanded: everything above degrades to what the file itself
/// says, and the app works without ever prompting. ``Access/limited`` is a first-class state rather
/// than a failure — the user picked a subset, and the subset is what this reads.
///
/// ## Two permissions, not one
///
/// Reading is `.readWrite`; writing one photograph back is `.addOnly`, a separate and much smaller
/// grant that iOS asks for only when Save to Device is first used. They are tracked separately
/// because a user who declined the first should still be able to do the second.
@MainActor
final class DevicePhotoLibrary: ObservableObject {

    // MARK: - Access

    /// The authorization states, named for what the app can do rather than for the enum case.
    enum Access: Equatable {
        case notDetermined
        case authorized
        /// The user granted access to a chosen subset. Everything works, over fewer items.
        case limited
        case denied
        /// Screen Time or an MDM profile forbids it. There is no prompt and no Settings switch —
        /// which is why it is not folded into `denied`, whose advice would be wrong here.
        case restricted

        /// Whether the library can be read at all.
        var isUsable: Bool { self == .authorized || self == .limited }

        var displayName: String {
            switch self {
            case .notDetermined: return "Not requested"
            case .authorized:    return "Full access"
            case .limited:       return "Limited"
            case .denied:        return "No access"
            case .restricted:    return "Restricted"
            }
        }

        init(_ status: PHAuthorizationStatus) {
            switch status {
            case .authorized:    self = .authorized
            case .limited:       self = .limited
            case .denied:        self = .denied
            case .restricted:    self = .restricted
            case .notDetermined: self = .notDetermined
            @unknown default:    self = .notDetermined
            }
        }
    }

    // MARK: - Published State

    /// Read access to the library — what enriches an import.
    @Published private(set) var access: Access

    /// Permission to add a photograph back to the library — what Save to Device needs.
    @Published private(set) var addAccess: Access

    /// How many items the app can currently see. Nil until ``refreshItemCount()`` has counted them,
    /// which is only worth doing on a screen that shows the number.
    @Published private(set) var itemCount: Int?

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "DevicePhotoLibrary")

    /// Where paired videos and RAW originals are written on their way to an upload. Under the
    /// system temporary directory because they are large, short-lived, and must not be backed up.
    private var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("device-library",
                                                                      isDirectory: true)
    }

    // MARK: - Init

    init() {
        access = Access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        addAccess = Access(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    // MARK: - Authorization

    /// Re-reads both statuses. Cheap, and the only way to notice a change made in Settings — iOS
    /// does not notify an app that its photo permission was revoked, it simply stops answering.
    func refresh() {
        access = Access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        addAccess = Access(PHPhotoLibrary.authorizationStatus(for: .addOnly))
        if !access.isUsable { itemCount = nil }
    }

    /// Prompts for read access, if there is anything to prompt for.
    ///
    /// iOS shows the system alert exactly once per install; every call after that returns the
    /// standing answer without displaying anything, which is why a denied state has to offer
    /// Settings rather than a second Allow button.
    @discardableResult
    func requestAccess() async -> Access {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
        access = Access(status)
        logger.debug("read access: \(self.access.displayName, privacy: .public)")
        return access
    }

    /// The same, for permission to write one photograph back.
    @discardableResult
    func requestAddAccess() async -> Access {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        addAccess = Access(status)
        return addAccess
    }

    /// Reopens the "select more photos" sheet for a limited grant.
    ///
    /// The only way to widen a limited selection from inside the app — Settings offers the whole
    /// library or nothing, and iOS's own periodic prompt is suppressed by
    /// `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` so that this is the one that appears.
    func presentLimitedPicker() {
        guard access == .limited, let controller = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }

    /// Deep link to this app's page in Settings, which is where a denied grant is changed.
    static var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    /// How many photographs and videos the app can currently see.
    ///
    /// Under a limited grant this is the size of the chosen subset rather than of the library, which
    /// is the honest number: it is what a full-library import would actually find.
    func refreshItemCount() {
        guard access.isUsable else { itemCount = nil; return }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        itemCount = PHAsset.fetchAssets(with: options).count
    }

    // MARK: - Reading

    /// What the library knows about the item a picker handed back.
    ///
    /// `PhotosPickerItem.itemIdentifier` is the `PHAsset.localIdentifier`, but only for a picker
    /// built with `photoLibrary: .shared()` — which ``LibraryView``'s is. Without read access the
    /// fetch simply finds nothing, and the caller falls back to what the file itself says.
    func attributes(forLocalIdentifier identifier: String?) -> DeviceAsset? {
        guard access.isUsable, let identifier, let asset = asset(withLocalIdentifier: identifier)
        else { return nil }
        return Self.attributes(of: asset)
    }

    func asset(withLocalIdentifier identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    static func attributes(of asset: PHAsset) -> DeviceAsset {
        let coordinate = asset.location.map {
            (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        return DeviceAsset(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            coordinate: coordinate,
            isFavorite: asset.isFavorite,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isRAW: rawResource(for: asset) != nil,
            subtypes: subtypeNames(of: asset),
            pixelWidth: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            pixelHeight: asset.pixelHeight > 0 ? asset.pixelHeight : nil
        )
    }

    // MARK: - Originals

    /// Writes an item's RAW original to a temporary file, untranscoded.
    ///
    /// This is the whole of "import RAW files". The picker will happily hand back a DNG's *contents*
    /// as `Data`, but what it hands back is a compatible rendering — a JPEG — because that is what a
    /// generic image request means to `PHPickerConfiguration`. Asking the resource manager for the
    /// resource whose type conforms to `public.camera-raw-image` is the only way to get the bytes
    /// the camera actually wrote, and storing anything else under the name "original" would make the
    /// backup a lie.
    ///
    /// Answers nil when the item has no RAW resource, which is every ordinary photograph.
    func writeRAWOriginal(for identifier: String) async throws -> DeviceOriginal? {
        guard access.isUsable else { throw DeviceLibraryError.notAuthorized }
        guard let asset = asset(withLocalIdentifier: identifier) else {
            throw DeviceLibraryError.assetUnavailable
        }
        guard let resource = Self.rawResource(for: asset) else { return nil }

        let type = UTType(resource.uniformTypeIdentifier)
        let ext = type?.preferredFilenameExtension
            ?? (resource.originalFilename as NSString).pathExtension
        let url = try await write(resource, extension: ext.isEmpty ? "dng" : ext)
        return DeviceOriginal(url: url,
                              mimeType: type?.preferredMIMEType ?? "image/x-adobe-dng",
                              fileExtension: ext.isEmpty ? "dng" : ext,
                              originalFileName: resource.originalFilename)
    }

    /// Writes a Live Photo's paired video to a temporary file.
    ///
    /// A Live Photo is two files that Apple Photos presents as one: the still, which is what the
    /// picker hands over, and a short MOV that nothing about the still refers to. Uploading only the
    /// still preserves the photograph and silently discards the motion — so this fetches the second
    /// half, and ``PhotoImportService`` sends it up beside the first.
    ///
    /// Answers nil for anything that is not a Live Photo.
    func writePairedVideo(for identifier: String) async throws -> URL? {
        guard access.isUsable else { throw DeviceLibraryError.notAuthorized }
        guard let asset = asset(withLocalIdentifier: identifier),
              asset.mediaSubtypes.contains(.photoLive) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        // `.pairedVideo` is the original; `.fullSizePairedVideo` is the rendered one an edit
        // produces. Preferring the edited version matches what Apple Photos plays back.
        guard let resource = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else { return nil }
        return try await write(resource, extension: "mov")
    }

    /// Writes one `PHAssetResource` to a fresh file under ``stagingDirectory``. The caller deletes it.
    private func write(_ resource: PHAssetResource, extension ext: String) async throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory,
                                                withIntermediateDirectories: true)
        let url = stagingDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: url)

        let options = PHAssetResourceRequestOptions()
        // An item still only in iCloud Photos has no local bytes at all; without this the request
        // fails rather than fetching them, and a library that has been "optimised" is mostly those.
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url,
                                                       options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return url
    }

    // MARK: - Saving back

    /// Puts a photograph into the device's library.
    ///
    /// - Parameter pairedVideoURL: a Live Photo's motion. When it is present the item lands in
    ///   Apple Photos as a **Live Photo** rather than as a still and a stray video, which is the
    ///   whole reason the paired video was preserved on the way in.
    ///
    /// The bytes are added as a resource rather than through `creationRequestForAsset(from: UIImage)`:
    /// a `UIImage` has already been decoded and would be re-encoded on the way out, so a DNG would
    /// come back as a JPEG and every original would lose its EXIF. `addResource(with:data:)` stores
    /// the file as it is.
    func save(photo data: Data, fileName: String, pairedVideoURL: URL? = nil) async throws {
        try await authorizeAdd()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = fileName

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: options)
            if let pairedVideoURL {
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: pairedVideoURL,
                                    options: videoOptions)
            }
        }
        logger.debug("saved \(fileName, privacy: .public) to the device library")
    }

    /// The same, for a video — which is a file rather than a `Data` for the same reason it is
    /// everywhere else in this app.
    func save(videoAt url: URL, fileName: String) async throws {
        try await authorizeAdd()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = fileName
        options.shouldMoveFile = false

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url,
                                                          options: options)
        }
        logger.debug("saved \(fileName, privacy: .public) to the device library")
    }

    /// Asks for add-only permission if it has not been asked for, and refuses if the answer is no.
    private func authorizeAdd() async throws {
        if addAccess == .notDetermined { await requestAddAccess() }
        // Full read/write covers adding. A user who granted the library outright must not be asked
        // again for the smaller permission they already gave.
        guard addAccess.isUsable || access == .authorized else {
            throw DeviceLibraryError.notAuthorized
        }
    }

    /// Removes anything left in the staging directory. Called when an import run ends, so a
    /// cancelled or crashed run does not leave gigabytes of paired video behind.
    func clearStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    // MARK: - Asset inspection

    /// The asset's RAW resource, if it has one.
    ///
    /// ProRAW and a camera's DNG land differently — one as the primary `.photo` resource, the other
    /// as an `.alternatePhoto` beside a JPEG — so this asks what each resource *is* rather than
    /// where it sits.
    private static func rawResource(for asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first { resource in
            UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) == true
        }
    }

    private static func subtypeNames(of asset: PHAsset) -> [String] {
        var names: [String] = []
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.photoPanorama)     { names.append("panorama") }
        if subtypes.contains(.photoHDR)          { names.append("hdr") }
        if subtypes.contains(.photoScreenshot)   { names.append("screenshot") }
        if subtypes.contains(.photoLive)         { names.append("live") }
        if subtypes.contains(.photoDepthEffect)  { names.append("portrait") }
        if subtypes.contains(.videoHighFrameRate) { names.append("slowMotion") }
        if subtypes.contains(.videoTimelapse)    { names.append("timelapse") }
        return names
    }

    // MARK: - Presentation

    /// The view controller a system sheet should be presented from.
    ///
    /// `presentLimitedLibraryPicker(from:)` is UIKit and takes one; SwiftUI has no equivalent, and
    /// no wrapper would be less of a reach than this. Written as "the topmost controller of the
    /// foreground active scene" rather than "the root", so it still works with a sheet already up.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
