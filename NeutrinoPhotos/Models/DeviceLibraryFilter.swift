import Foundation

// MARK: - DeviceLibraryFilter

/// Holds the device album's derived shape — which of the phone's items the grid is currently
/// drawing, and how many of them are already in the account — and rebuilds it only when one of its
/// inputs has actually changed.
///
/// ## Why the device album needs this
///
/// The same problem ``TimelineCache`` solves, arriving from the other direction. There, body ran on
/// scroll frames; here it runs on *upload* frames — the byte fraction of the item in flight is
/// published several times a second, and ``DeviceLibraryView`` draws a progress bar from it. A
/// filter over a fifty-thousand-item camera roll, re-run on each of those, is the difference between
/// a grid that scrolls while an upload runs and one that does not.
///
/// ## Why the inputs are what they are
///
/// `revision` stands in for the listing — see ``DeviceLibraryBrowser/revision`` — and `importedCount`
/// stands in for the ledger. The second one is only faithful because the ledger is append-only
/// between resets: an item is never *un*-imported without the count changing too, so two states with
/// the same count hold the same items. `forget()` takes it to zero, which is a change like any other.
///
/// Like ``TimelineCache``, a plain class rather than an `ObservableObject`: it publishes nothing and
/// must not, because it is read during a body pass and a publish from there re-renders the view
/// currently rendering. It is held in `@State` purely so the reference survives, and `refresh` is
/// idempotent — calling it every body pass is the intended use.
final class DeviceLibraryFilter {

    // MARK: - Inputs

    /// Everything the derived shape depends on, in a form cheap enough to compare every frame.
    struct Inputs: Equatable {
        /// ``DeviceLibraryBrowser/revision`` — stands in for the listing itself.
        let revision: Int
        /// ``ImportLedger/count`` — stands in for which items have been uploaded.
        let importedCount: Int
        let hidesUploaded: Bool
    }

    // MARK: - Output

    /// What the grid draws.
    private(set) var visible: [ScannedAsset] = []

    /// How many of the items on this device are already in the account — of the whole listing, not
    /// of `visible`, since the sentence it is used in ("every photo on this iPhone is already in
    /// your library") is about the phone rather than about the filter.
    private(set) var uploadedCount = 0

    /// How many of the *visible* items are already in the account. Zero whenever the filter is on,
    /// by construction. What "Select All" would be selecting that does not need uploading.
    private(set) var visibleUploadedCount = 0

    /// How many times the work has actually been done. Exposed so a test can assert that a body pass
    /// with unchanged inputs is free — the whole point of the type, and not otherwise observable.
    private(set) var recomputeCount = 0

    // MARK: - Private

    private var inputs: Inputs?

    // MARK: - Refresh

    /// Brings the derived shape up to date, doing nothing if it already is.
    ///
    /// - Parameters:
    ///   - source: produces the full device listing. A closure rather than a value so nothing is
    ///     copied on the passes that turn out to be no-ops, which is nearly all of them.
    ///   - isImported: whether this device has already uploaded that asset.
    /// - Returns: whether anything was rebuilt.
    @discardableResult
    func refresh(_ inputs: Inputs, source: () -> [ScannedAsset],
                 isImported: (String) -> Bool) -> Bool {
        guard inputs != self.inputs else { return false }
        self.inputs = inputs
        recomputeCount += 1

        let assets = source()
        // One pass, counting as it filters. Two passes over fifty thousand items to produce a
        // number and a list that are both functions of the same predicate would be twice the work
        // for no clarity.
        var visible: [ScannedAsset] = []
        var uploaded = 0
        visible.reserveCapacity(assets.count)
        for asset in assets {
            let imported = isImported(asset.localIdentifier)
            if imported { uploaded += 1 }
            if !imported || !inputs.hidesUploaded { visible.append(asset) }
        }

        self.visible = visible
        self.uploadedCount = uploaded
        self.visibleUploadedCount = inputs.hidesUploaded ? 0 : uploaded
        return true
    }
}
