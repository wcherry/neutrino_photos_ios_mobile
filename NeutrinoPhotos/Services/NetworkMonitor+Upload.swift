import Foundation
import NeutrinoCore

// MARK: - Upload gating

/// Photos' vocabulary over the shared connectivity predicate.
///
/// `NetworkMonitor` lives in `NeutrinoCore` and asks the question the sync-shaped apps ask —
/// `shouldSync(allowCellular:)`. Photos' setting is spelled the other way round ("Upload over
/// Wi-Fi only"), and inverting the flag at each call site is how one of them eventually gets
/// inverted twice. This states the mapping once instead of adding a second name for the same
/// predicate to the shared type.
extension NetworkMonitor {

    /// Whether an upload may start now, honouring the user's Wi-Fi-only preference.
    func shouldUpload(wifiOnly: Bool) -> Bool {
        shouldSync(allowCellular: !wifiOnly)
    }
}
