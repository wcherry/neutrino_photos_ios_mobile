import Foundation
import Photos
import UIKit
import os.log

// MARK: - DeviceLibraryBrowser

/// The device's own photo library, as something to look at.
///
/// ## Why this is not ``DevicePhotoLibrary``
///
/// That type reads *one item at a time*, on behalf of an import: what Apple Photos knows about an
/// asset, and the bytes behind it. This one answers a different question — "what is on this phone,
/// in order, with a picture for each" — and the two have opposite cost profiles. An import walks the
/// library once and never draws it; a grid draws forty cells at a time, scrolls, and must never
/// stall. So this holds the two things a grid needs and an importer has no use for: the
/// `PHFetchResult` the cells index into, and a thumbnail request path with a cache in front of it.
///
/// ## What is held, and what is not
///
/// The listing is held as ``ScannedAsset`` values — the same small record the full-library scan
/// builds, for the same reason it exists: everything a cell draws is already in `PHAsset` without a
/// trip across the Photos XPC boundary, and the expensive questions (is there a RAW resource? a
/// paired video?) are asked once, at the moment an item is actually imported.
///
/// The `PHFetchResult` is held beside it, and the array index *is* the fetch-result index — the
/// fetch predicate excludes everything this app cannot store, so nothing is filtered afterwards and
/// the two cannot drift. ``positions`` maps an identifier back to that index, which is what lets a
/// cell ask for its picture by identity rather than by position.
///
/// ## Staying current
///
/// Registered as a `PHPhotoLibraryChangeObserver`, so a photograph taken while the grid is open
/// appears in it, and widening a limited grant through "Select More Photos" shows the newly shared
/// items rather than requiring a relaunch. The change is applied by re-fetching rather than by
/// walking the `PHChange` diff: this is a flat, newest-first listing with no per-row animation to
/// preserve, and a re-fetch cannot get out of step with the fetch result the way an incrementally
/// patched copy can.
@MainActor
final class DeviceLibraryBrowser: NSObject, ObservableObject {

    // MARK: - Published State

    /// Everything on this device that this app could store, newest first.
    @Published private(set) var assets: [ScannedAsset] = []

    /// Bumped every time the listing is rebuilt.
    ///
    /// Stands in for the array wherever it would otherwise be *compared* — a `.onChange` on the
    /// listing, or a cache key over it. `assets` is tens of thousands of structs, SwiftUI compares
    /// an `onChange` value on every view update, and a view that also draws an upload progress bar
    /// updates many times a second. The same trick, for the same reason, as
    /// ``PhotoLibraryService/revision``.
    @Published private(set) var revision = 0

    @Published private(set) var isLoading = false

    /// Why the listing is empty, when it is empty for a reason worth saying.
    @Published private(set) var error: String?

    /// Whether a listing has ever been built. Distinguishes "no photographs on this device" from
    /// "not asked yet", which the empty state has to draw differently.
    @Published private(set) var hasLoaded = false

    // MARK: - Dependencies

    /// Consulted for the authorization state only. The fetch itself goes straight to `PHAsset`:
    /// asking an unauthorized library returns an empty result rather than failing, and the screen
    /// above turns that into a prompt.
    private let deviceLibrary: DevicePhotoLibrary

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "DeviceLibraryBrowser")

    private var fetchResult: PHFetchResult<PHAsset>?

    /// Identifier → its index in ``assets`` and in ``fetchResult``, which are the same index.
    private var positions: [String: Int] = [:]

    private var isObserving = false

    /// `PHCachingImageManager` rather than `PHImageManager.default()`: it is the one that can be
    /// told what is about to come on screen, and it is a drop-in for the shared manager otherwise.
    private let imageManager = PHCachingImageManager()

    /// Decoded thumbnails, dropped wholesale under memory pressure — the same bargain
    /// ``ThumbnailCache`` makes, and for the same reason: a grid that re-requests every cell it
    /// scrolls back to is a grid that stutters, and twenty thousand decoded thumbnails is a
    /// termination.
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    // MARK: - Init

    init(deviceLibrary: DevicePhotoLibrary) {
        self.deviceLibrary = deviceLibrary
        super.init()
    }

    deinit {
        // Not `isObserving`-guarded: `deinit` is nonisolated and cannot read main-actor state, and
        // unregistering something that was never registered is a no-op.
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - Loading

    /// Builds the listing, unless one is already there.
    ///
    /// Called from the grid's `.task`, which runs on every appearance — so the default is to keep
    /// what is already loaded rather than to re-walk the library each time somebody navigates back
    /// to it. The change observer is what keeps that copy honest.
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await load()
    }

    /// Walks the library and replaces the listing.
    func load() async {
        guard !isLoading else { return }
        guard deviceLibrary.access.isUsable else {
            assets = []
            positions = [:]
            fetchResult = nil
            error = DeviceLibraryError.notAuthorized.errorDescription
            hasLoaded = false
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        // Off the main actor: `enumerateObjects` over a fifty-thousand-item library is tens of
        // thousands of trips across the Photos XPC boundary, and doing that on the thread drawing
        // the grid means the grid does not draw. `PHFetchResult` is an immutable snapshot, so
        // reading it from another thread is safe.
        let listing = await Task.detached(priority: .userInitiated) {
            Self.fetch()
        }.value

        fetchResult = listing.result
        assets = listing.assets
        positions = listing.positions
        revision &+= 1
        hasLoaded = true
        startObserving()
        logger.debug("listed \(listing.assets.count) item(s) on this device")
    }

    /// One listing: the fetch result, the values drawn from it, and the index of each.
    private struct Listing: @unchecked Sendable {
        let result: PHFetchResult<PHAsset>
        let assets: [ScannedAsset]
        let positions: [String: Int]
    }

    /// The fetch itself. `nonisolated` and `static` so it can run anywhere but the main actor.
    nonisolated private static func fetch() -> Listing {
        let options = PHFetchOptions()
        // Hidden items are hidden — the same rule the full-library scan follows, and for the same
        // reason: showing somebody's Hidden album inside a backup app is the worst possible reading
        // of "the photos on this phone".
        options.includeHiddenAssets = false
        // Filtered here rather than after the walk, which is what keeps the array index and the
        // fetch-result index the same number. `.audio` and `.unknown` are the cases this excludes;
        // there is nothing in this app that could show one.
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(with: options)
        var assets: [ScannedAsset] = []
        var positions: [String: Int] = [:]
        assets.reserveCapacity(result.count)
        positions.reserveCapacity(result.count)

        result.enumerateObjects { asset, index, _ in
            assets.append(ScannedAsset(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                isVideo: asset.mediaType == .video,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration
            ))
            positions[asset.localIdentifier] = index
        }
        return Listing(result: result, assets: assets, positions: positions)
    }

    // MARK: - Reading

    func asset(for identifier: String) -> ScannedAsset? {
        guard let index = positions[identifier], assets.indices.contains(index) else { return nil }
        return assets[index]
    }

    /// The selected identifiers as listing records, in the order the grid shows them.
    ///
    /// Order matters: it is the order they will be uploaded in, and "newest first" is the same
    /// promise the full-library import makes — an upload interrupted halfway has sent the pictures
    /// somebody took this month rather than the ones from 2009.
    func resolve(_ identifiers: Set<String>) -> [ScannedAsset] {
        assets.filter { identifiers.contains($0.localIdentifier) }
    }

    // MARK: - Thumbnails

    /// One cell's picture.
    ///
    /// Answers nil rather than throwing for everything that can go wrong here — the asset was
    /// deleted between the listing and the request, the permission was narrowed, Photos declined —
    /// because a cell's response to every one of those is the same placeholder square.
    func thumbnail(for identifier: String, targetSize: CGSize) async -> UIImage? {
        let key = Self.key(for: identifier, size: targetSize) as NSString
        if let cached = memory.object(forKey: key) { return cached }
        guard let index = positions[identifier],
              let asset = fetchResult?.object(at: index) else { return nil }

        let options = PHImageRequestOptions()
        // Exactly one callback, which is what an `async` wrapper needs — `.opportunistic` calls the
        // handler twice (degraded, then full) and a continuation may only be resumed once.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        // No network. Photos keeps a local thumbnail even for an asset whose original has been
        // evicted to iCloud, so this costs nothing at grid size — and a grid that waited on the
        // network per cell would be unusable on a library that has been "optimised".
        options.isNetworkAccessAllowed = false

        let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            imageManager.requestImage(for: asset, targetSize: targetSize,
                                      contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }

        guard let image else { return nil }
        memory.setObject(image, forKey: key, cost: RenditionGenerator.bitmapCost(of: image))
        return image
    }

    private static func key(for identifier: String, size: CGSize) -> String {
        // The size is part of the key: the same asset is requested at one size by the grid and at
        // another by an iPad's wider one, and handing back the smaller of the two would draw a
        // blurred cell that never sharpens.
        "\(identifier)@\(Int(size.width))x\(Int(size.height))"
    }

    // MARK: - Housekeeping

    /// Drops the listing and the thumbnails. What signing out needs — the next account on this
    /// device browses the library again from scratch rather than from a stale snapshot.
    func clear() {
        assets = []
        positions = [:]
        fetchResult = nil
        hasLoaded = false
        error = nil
        revision &+= 1
        memory.removeAllObjects()
    }
}

// MARK: - PHPhotoLibraryChangeObserver

extension DeviceLibraryBrowser: PHPhotoLibraryChangeObserver {

    private func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        PHPhotoLibrary.shared().register(self)
    }

    /// Called by Photos on an arbitrary thread, which is why the work hops to the main actor rather
    /// than happening here.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self, let result = self.fetchResult else { return }
            // Only when *this* fetch is affected. Photos sends a change for every edit anywhere in
            // the library, including ones that leave this listing identical, and re-walking fifty
            // thousand assets for a favourite toggled in another app is a freeze somebody feels.
            guard changeInstance.changeDetails(for: result) != nil else { return }
            await self.load()
        }
    }
}
