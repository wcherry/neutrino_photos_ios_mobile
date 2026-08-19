import CoreGraphics
import Foundation

// MARK: - TimelineScrubber

/// The map between a position on the fast-scroll track and a place in the timeline.
///
/// ## Why this is not just an index
///
/// The obvious scrubber divides its track evenly among the sections: halfway down means the middle
/// section. In a photo library that is wrong in a way people notice immediately. One holiday weekend
/// can hold four hundred pictures and the Tuesday either side of it two, yet an even split gives all
/// three the same third of the track — so the thumb crawls through a day that fills thirty screens
/// and then leaps a year in a millimetre. The thumb stops corresponding to the scroll bar it is
/// standing in for.
///
/// So each section is weighted by how tall it actually draws: one header, plus a row for every
/// ``columns`` items. The units are rows rather than points, which is enough — the track only needs
/// to be *proportional* to the content, and a row's height in points is the same for every row in a
/// square grid, so it cancels.
///
/// Pure, and separated from the view for that reason: "the scrubber is off by a section near the
/// end" is invisible in a screenshot and obvious in a test.
struct TimelineScrubber {

    // MARK: - Stop

    /// One section, and where its top sits on the track as a fraction from 0 (newest) to 1 (oldest).
    struct Stop: Equatable {
        let sectionID: String
        let title: String
        let start: Date
        /// 0...1, measured to the *top* of the section.
        let position: Double
    }

    // MARK: - Properties

    let stops: [Stop]

    /// Whether the control is worth drawing. A timeline that fits in a screen or two is faster to
    /// flick than to aim at, and a scrubber over it is chrome covering the photographs.
    var isUseful: Bool { stops.count >= Self.minimumStops }

    /// How many sections there have to be before the track earns its place on screen.
    private static let minimumStops = 6

    // MARK: - Weights

    /// A section header, expressed in the same units as a grid row. Approximate on purpose: the
    /// track is proportional, not a measurement, and being a few points out over a thousand
    /// sections moves the thumb by less than its own height.
    private static let headerWeight = 0.4

    // MARK: - Init

    /// - Parameters:
    ///   - sections: the timeline as it is currently grouped, newest first.
    ///   - columns: how many pictures the grid draws per row, which is what decides how many rows a
    ///     section of a given size occupies. Passing the wrong number does not break the scrubber,
    ///     it just biases long sections against short ones.
    init(sections: [TimelineSection], columns: Int) {
        let columns = max(1, columns)
        let weights = sections.map { section -> Double in
            let rows = Double((section.items.count + columns - 1) / columns)
            return Self.headerWeight + rows
        }
        let total = weights.reduce(0, +)

        guard total > 0 else {
            stops = []
            return
        }

        var running = 0.0
        stops = zip(sections, weights).map { section, weight in
            let stop = Stop(sectionID: section.id,
                            title: section.title,
                            start: section.start,
                            position: running / total)
            running += weight
            return stop
        }
    }

    // MARK: - Reading the track

    /// The section under a point on the track, where 0 is the top and 1 the bottom.
    ///
    /// Positions outside 0...1 are clamped rather than refused: a drag that runs off the end of the
    /// track should pin to the last section, which is what a finger sliding past the bottom of the
    /// screen means.
    func stop(atPosition position: Double) -> Stop? {
        guard !stops.isEmpty else { return nil }
        let position = min(max(position, 0), 1)

        // The last stop that begins at or before `position` — binary search, because this runs on
        // every frame of a drag and a long library has thousands of sections.
        var low = 0
        var high = stops.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if stops[middle].position <= position {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return stops[found]
    }

    /// Where a section sits on the track — how the thumb follows an ordinary scroll rather than
    /// only moving when it is dragged.
    func position(ofSectionID id: String) -> Double? {
        stops.first { $0.sectionID == id }?.position
    }
}
