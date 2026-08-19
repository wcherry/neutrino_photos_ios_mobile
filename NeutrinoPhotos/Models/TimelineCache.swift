import Foundation

// MARK: - TimelineCache

/// Holds the timeline's derived shape — the filtered, sorted item list and the sections it groups
/// into — and rebuilds it only when one of its inputs has actually changed.
///
/// ## Why the timeline needs this and the other grids do not
///
/// Grouping is not cheap: a filter, a sort, a dictionary of buckets, a sort inside each bucket, and
/// a sort of the buckets themselves — over the whole library. That was fine while `LibraryView`'s
/// body ran only when the library or a setting changed, which is a handful of times a minute.
///
/// It stopped being fine when the timeline gained a scrubber and a pinch. Both are driven by
/// geometry reported out of the scroll view, so body now runs on *scroll frames*, and recomputing
/// two thousand photographs' worth of sections sixty times a second is exactly the stutter the
/// epic's first verification step is looking for. Memoizing on a revision counter turns those
/// frames into an integer comparison.
///
/// ## Why it is a plain class read from `body`
///
/// Not an `ObservableObject`: it publishes nothing and must not, because it is *read* during a body
/// pass and a publish from there is a re-render of the view currently rendering. It is held in
/// `@State` purely so the reference survives, and `refresh` is idempotent — calling it every body
/// pass is the intended use, and all but the first call after a change is a comparison and a return.
///
/// Main-actor by construction rather than by annotation: it is only ever touched from a view's
/// body. Annotating it would make the `@State` initializer a cross-actor call from a nonisolated
/// struct, which is a diagnostic that says nothing true about how this is used.
final class TimelineCache {

    // MARK: - Inputs

    /// Everything the derived shape depends on, in a form cheap enough to compare on every frame.
    struct Inputs: Equatable {
        /// ``PhotoLibraryService/revision`` — stands in for the item array itself.
        let revision: Int
        let grouping: TimelineGrouping
        let showsArchived: Bool
    }

    // MARK: - Output

    /// The timeline's items, filtered and newest first.
    private(set) var items: [MediaItem] = []

    /// Those items grouped at the current density.
    private(set) var sections: [TimelineSection] = []

    /// How many times the work has actually been done. Exposed so a test can assert that a body
    /// pass with unchanged inputs is free — the whole point of the type, and not otherwise
    /// observable from outside.
    private(set) var recomputeCount = 0

    // MARK: - Private

    private var inputs: Inputs?

    // MARK: - Refresh

    /// Brings the derived shape up to date, doing nothing if it already is.
    ///
    /// - Parameter source: produces the filtered item list. A closure rather than a value so the
    ///   filter and sort behind it are not paid for on the passes that turn out to be no-ops —
    ///   which is nearly all of them.
    /// - Returns: whether anything was rebuilt.
    @discardableResult
    func refresh(_ inputs: Inputs, source: () -> [MediaItem]) -> Bool {
        guard inputs != self.inputs else { return false }
        self.inputs = inputs
        recomputeCount += 1

        let items = source()
        self.items = items
        self.sections = TimelineSection.sections(from: items, grouping: inputs.grouping)
        return true
    }
}
