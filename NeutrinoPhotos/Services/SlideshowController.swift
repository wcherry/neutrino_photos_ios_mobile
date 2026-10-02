import SwiftUI

// MARK: - SlideshowController

/// One running slideshow: which photograph is up, whether it is playing, how fast, and the decoded
/// pictures around the current one.
///
/// Owned by ``SlideshowView`` for as long as it is on screen. Kept out of the view so the parts
/// that are easy to get wrong — wrapping at the ends, what is kept in memory, what reaches the
/// external display — can be tested without one.
///
/// ## Memory
///
/// A preview is 2048 px on its long edge, about 16 MB decoded. An album can hold thousands, so only
/// a window is kept: the current photograph, the next — which the phone shows and the auto-advance
/// is about to need — and the previous, for stepping back. Everything else is dropped as the window
/// moves; the ``ThumbnailCache`` and the disk cache underneath make coming back to one cheap.
@MainActor
final class SlideshowController: ObservableObject {

    typealias Loader = @MainActor (MediaItem) async throws -> UIImage
    typealias Placeholder = @MainActor (MediaItem) async -> UIImage?

    // MARK: - State

    /// The photographs, in album order. Never empty — see ``init(items:startID:interval:transition:display:placeholder:loader:)``.
    let items: [MediaItem]

    @Published private(set) var index: Int
    /// Which way the last move went, so a directional transition plays the right way round.
    @Published private(set) var isAdvancing = true
    @Published var isPlaying = true
    /// Seconds each photograph stays up.
    @Published var interval: TimeInterval
    @Published var transition: SlideshowTransition {
        didSet { display.setTransition(transition) }
    }

    /// Zoom, pan and flip on the current photograph. Reset by every move.
    @Published private(set) var adjustment = PhotoAdjustment.identity

    /// The best picture so far for each photograph in the window.
    @Published private(set) var images: [String: UIImage] = [:]
    /// Photographs in the window that could not be loaded, with the reason.
    @Published private(set) var failures: [String: String] = [:]

    // MARK: - Dependencies

    private let display: ExternalDisplayService
    private let placeholder: Placeholder
    private let loader: Loader
    /// Which items have their preview, as opposed to a thumbnail standing in for it.
    private var sharp: Set<String> = []

    // MARK: - Init

    /// - Parameters:
    ///   - items: the photographs to show. Must not be empty; the album screen only offers the
    ///     slideshow when there is something to show.
    ///   - startID: the photograph to start on, or the first if nil or not among `items`.
    ///   - placeholder: a picture to show while the real one loads — the grid thumbnail.
    ///   - loader: the picture itself.
    init(items: [MediaItem],
         startID: String? = nil,
         interval: TimeInterval,
         transition: SlideshowTransition,
         display: ExternalDisplayService,
         placeholder: @escaping Placeholder,
         loader: @escaping Loader) {
        precondition(!items.isEmpty, "a slideshow needs something to show")
        self.items = items
        self.index = startID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        self.interval = interval
        self.transition = transition
        self.display = display
        self.placeholder = placeholder
        self.loader = loader
    }

    // MARK: - Reading

    var current: MediaItem { items[index] }

    /// The photograph after this one, wrapping to the first. Nil for an album of one, which has no
    /// "next" worth showing.
    var nextItem: MediaItem? {
        items.count > 1 ? items[(index + 1) % items.count] : nil
    }

    /// What the current photograph looks like right now, on either screen.
    var frame: SlideshowFrame {
        SlideshowFrame(itemID: current.id,
                       image: images[current.id],
                       isUnavailable: images[current.id] == nil && failures[current.id] != nil)
    }

    // MARK: - Lifecycle

    /// Starts sending to the external display. Safe with none connected — see
    /// ``ExternalDisplayService/begin(transition:)``.
    func start() {
        display.begin(transition: transition)
        publish()
    }

    func stop() {
        display.end()
    }

    // MARK: - Moving

    func next() {
        move(to: (index + 1) % items.count, isAdvancing: true)
    }

    func previous() {
        move(to: (index - 1 + items.count) % items.count, isAdvancing: false)
    }

    private func move(to target: Int, isAdvancing: Bool) {
        guard target != index else { return }
        self.isAdvancing = isAdvancing
        index = target
        adjustment = .identity
        publish()
    }

    // MARK: - Adjusting

    /// Changes the zoom, pan or flip of the current photograph, kept within bounds.
    ///
    /// Adjusting pauses the slideshow. Somebody who has zoomed into a face to show the room has
    /// stopped to look at it, and the clock carrying on would move them to the next photograph
    /// mid-sentence. Play resumes it, and the next photograph starts unadjusted.
    func adjust(_ change: (inout PhotoAdjustment) -> Void) {
        var updated = adjustment
        change(&updated)
        updated = updated.clamped()
        guard updated != adjustment else { return }
        if !updated.isIdentity { isPlaying = false }
        adjustment = updated
        display.setAdjustment(updated)
    }

    func zoom(by factor: CGFloat) {
        adjust { $0.scale *= factor }
    }

    /// Double-tap: in to 2.5× from fitted, back to fitted from anything else.
    func toggleZoom() {
        adjust { $0.scale = $0.scale > 1 ? 1 : 2.5 }
    }

    func flipHorizontally() {
        adjust { $0.isFlippedHorizontally.toggle() }
    }

    func flipVertically() {
        adjust { $0.isFlippedVertically.toggle() }
    }

    func resetAdjustment() {
        adjust { $0 = .identity }
    }

    /// Waits one interval and moves on, if still playing.
    ///
    /// Called from a `.task` keyed on the index, the play state and the interval, so any of those
    /// changing — a manual step, a pause, the slider moving — restarts the countdown rather than
    /// letting a stale one fire.
    func autoAdvance() async {
        guard isPlaying, items.count > 1 else { return }
        try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        guard !Task.isCancelled, isPlaying else { return }
        next()
    }

    // MARK: - Loading

    /// The indices worth holding a picture for: current first, so it is the one fetched first.
    var windowIndices: [Int] {
        guard items.count > 1 else { return [index] }
        var result = [index, (index + 1) % items.count, (index - 1 + items.count) % items.count]
        // An album of two has the same photograph as both neighbours.
        var seen = Set<Int>()
        result = result.filter { seen.insert($0).inserted }
        return result
    }

    /// Loads the pictures around the current photograph and drops the rest.
    ///
    /// Called from a `.task` keyed on the index, so a step cancels the loads it no longer needs.
    func loadWindow() async {
        let window = windowIndices.map { items[$0] }
        let keep = Set(window.map(\.id))
        images = images.filter { keep.contains($0.key) }
        failures = failures.filter { keep.contains($0.key) }
        sharp.formIntersection(keep)

        for item in window where !sharp.contains(item.id) {
            if Task.isCancelled { return }
            if images[item.id] == nil, let cover = await placeholder(item), !sharp.contains(item.id) {
                images[item.id] = cover
                if item.id == current.id { publish() }
            }
            do {
                let image = try await loader(item)
                images[item.id] = image
                sharp.insert(item.id)
                failures[item.id] = nil
            } catch where error.isCancellation {
                return
            } catch {
                // Kept on its thumbnail if it has one — still a photograph worth showing — and
                // marked, so a photograph with nothing at all says why instead of spinning.
                failures[item.id] = error.localizedDescription
            }
            if item.id == current.id { publish() }
        }
    }

    // MARK: - Publishing

    private func publish() {
        display.show(frame, isAdvancing: isAdvancing)
    }
}
