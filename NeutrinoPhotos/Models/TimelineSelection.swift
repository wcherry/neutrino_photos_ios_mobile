import Foundation

// MARK: - TimelineSelection

/// What is selected in the timeline's multi-select mode, and the small set of things that can be
/// done to that set.
///
/// A struct rather than a bare `Set<String>` because the mode has a state the set alone cannot
/// express: selecting nothing while *in* the mode is a legitimate position — it is what "Deselect
/// All" leaves behind — and is different from not being in the mode at all. Collapsing the two
/// makes Deselect All exit the mode, which is not what the button says it does.
///
/// It holds ids rather than items so it survives the library refreshing underneath it. An item
/// deleted by another device mid-selection then simply drops out of the resolved set instead of
/// leaving a phantom in the count — see ``resolve(in:)``, which is the only way the actions read it.
///
/// ## Why the queries are generic
///
/// Two grids select now: the timeline, over ``MediaItem``, and the device-library album, over
/// ``ScannedAsset``. They select identically — tap to toggle, select-all, prune what has gone — and
/// the only thing that differs is what the ids name. Everything above the id is therefore written
/// once, against `Identifiable` with a `String` id, rather than copied into a second selection type
/// whose first divergence would be a bulk action that addresses the wrong set.
struct TimelineSelection: Equatable {

    // MARK: - Properties

    /// Whether the timeline is in multi-select mode.
    private(set) var isActive = false

    /// The photo-record ids currently selected. Private so the mode and the set cannot drift apart.
    private(set) var ids: Set<String> = []

    /// What the toolbar counts. Deliberately the raw count and not the resolved one: it has to be
    /// right the instant a cell is tapped, without a list to resolve against.
    var count: Int { ids.count }

    var isEmpty: Bool { ids.isEmpty }

    // MARK: - Queries

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The selected items, in the order the list gives them, skipping ids the library no longer has.
    func resolve<Item: Identifiable>(in items: [Item]) -> [Item] where Item.ID == String {
        items.filter { ids.contains($0.id) }
    }

    /// Whether every item on screen is selected — what decides whether the button offers
    /// "Select All" or "Deselect All". An empty list is not "all selected"; there is nothing to
    /// select, and offering to deselect it would be nonsense.
    func coversAll<Item: Identifiable>(of items: [Item]) -> Bool where Item.ID == String {
        guard !items.isEmpty else { return false }
        return items.allSatisfy { ids.contains($0.id) }
    }

    // MARK: - Mutation

    /// Enters multi-select mode, optionally with the item that was long-pressed to get here already
    /// selected — a long press that selected nothing would need a second tap to do anything.
    mutating func begin(with id: String? = nil) {
        isActive = true
        if let id { ids.insert(id) }
    }

    /// Leaves the mode and forgets the selection. Done and Cancel are the same action here: nothing
    /// is staged, every bulk action applies immediately, so there is nothing left to commit.
    mutating func end() {
        isActive = false
        ids.removeAll()
    }

    mutating func toggle(_ id: String) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
    }

    mutating func selectAll<Item: Identifiable>(in items: [Item]) where Item.ID == String {
        ids = Set(items.map(\.id))
    }

    /// Clears the selection but stays in the mode.
    mutating func deselectAll() {
        ids.removeAll()
    }

    /// Drops ids that are no longer in the library, so a bulk action taken after a sync cannot
    /// address something that has gone.
    mutating func prune<Item: Identifiable>(against items: [Item]) where Item.ID == String {
        let live = Set(items.map(\.id))
        ids.formIntersection(live)
    }
}
