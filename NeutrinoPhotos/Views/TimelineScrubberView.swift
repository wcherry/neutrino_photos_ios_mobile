import SwiftUI
import UIKit

// MARK: - TimelinePosition

/// Where the timeline currently is, as the scroll view reports it.
///
/// ## Why this is a class and not `@State`
///
/// Scroll position arrives through a geometry preference, which fires on every frame of a scroll.
/// Holding it in `@State` on `LibraryView` would therefore re-run that view's body — and its
/// thousand-cell `ForEach` — sixty times a second, which is precisely the stutter the scrubber
/// exists to help avoid. So the position lives in a reference type that `LibraryView` holds but does
/// **not** observe, and only ``TimelineScrubberView`` subscribes to it. A scroll then re-renders a
/// thumb rather than a library.
///
/// Even that is throttled: ``topSectionID`` is `@Published` and only assigned when the section
/// actually changes, so a flick through one long day publishes once rather than per frame.
/// ``topSectionStart`` is deliberately *not* published — it is read once, at the instant a pinch
/// regroups the timeline, and publishing it would undo the whole arrangement.
final class TimelinePosition: ObservableObject {

    /// The section pinned at the top of the screen.
    @Published private(set) var topSectionID: String?

    /// That section's date. The anchor a density change scrolls back to.
    private(set) var topSectionStart: Date?

    /// When the timeline last moved, which is what decides whether the track has gone quiet enough
    /// to fade out. Unpublished for the same reason as `topSectionStart`: it is written on every
    /// scroll frame, and announcing that would re-render the grid sixty times a second.
    private(set) var lastMovedAt = Date.distantPast

    func update(id: String?, start: Date?) {
        topSectionStart = start
        lastMovedAt = Date()
        guard id != topSectionID else { return }
        topSectionID = id
    }
}

// MARK: - TimelineScrubberView

/// The fast-scroll track down the trailing edge: drag it to travel years in a gesture.
///
/// The thumb follows an ordinary scroll as well as leading one, so it doubles as a position
/// indicator — which is what makes it findable. It fades out when the timeline is at rest, because
/// a permanently visible bar over the right-hand column of photographs is chrome that has to earn
/// its place on every screen, not just the ones being scrolled.
struct TimelineScrubberView: View {

    // MARK: - Inputs

    let scrubber: TimelineScrubber

    /// Owned by the timeline, observed only here — see ``TimelinePosition``.
    @ObservedObject var position: TimelinePosition

    /// Whether the timeline has been touched recently enough for the track to be worth showing.
    let isActive: Bool

    /// Called continuously as the thumb passes into a new section, and once when the drag ends.
    let onScrub: (TimelineScrubber.Stop) -> Void

    /// True while a drag is in progress, so the timeline can stop chasing its own scroll events.
    let onDragChange: (Bool) -> Void

    // MARK: - State

    /// Where the thumb sits while being dragged. Nil when it is merely following the scroll — the
    /// two are separate because a drag has to lead the scroll view rather than wait for it.
    @State private var dragPosition: Double?
    @State private var dragOrigin: Double?
    /// The section last reported, so a drag fires one haptic per section rather than one per frame.
    @State private var lastReportedID: String?

    private let feedback = UISelectionFeedbackGenerator()

    private let thumbHeight: CGFloat = 46
    private let thumbWidth: CGFloat = 34

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - thumbHeight, 1)

            ZStack(alignment: .topTrailing) {
                Color.clear
                thumb
                    .offset(y: currentPosition * travel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .gesture(drag(travel: travel))
        }
        .frame(width: thumbWidth + 12)
        .padding(.vertical, 8)
        .opacity(isShowing ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isShowing)
        // Off when hidden, so an invisible track cannot swallow a tap meant for the photograph
        // underneath it.
        .allowsHitTesting(isShowing)
    }

    // MARK: - Derived

    private var isShowing: Bool { scrubber.isUseful && (isActive || isDragging) }

    private var isDragging: Bool { dragPosition != nil }

    /// The thumb's place on the track: where the finger has put it, or where the scroll says it is.
    private var currentPosition: Double {
        if let dragPosition { return dragPosition }
        guard let id = position.topSectionID else { return 0 }
        return scrubber.position(ofSectionID: id) ?? 0
    }

    /// What the callout says — only while dragging, since at rest the date headings already say it.
    private var calloutTitle: String? {
        guard isDragging, let dragPosition else { return nil }
        return scrubber.stop(atPosition: dragPosition)?.title
    }

    // MARK: - Thumb

    private var thumb: some View {
        HStack(spacing: 8) {
            if let calloutTitle {
                Text(calloutTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(radius: 3)
                    // The callout hangs off the left of the track and must not be clipped by it,
                    // nor push the thumb sideways as the date under the finger changes width.
                    .frame(width: 0, alignment: .trailing)
                    .offset(x: -12)
                    .transition(.opacity)
            }

            Image(systemName: "arrow.up.and.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: thumbWidth, height: thumbHeight)
                .background(.thinMaterial, in: Capsule())
                .shadow(radius: 2)
                .scaleEffect(isDragging ? 1.1 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }

    // MARK: - Dragging

    private func drag(travel: CGFloat) -> some Gesture {
        // Zero minimum distance so the thumb responds to the press rather than after a threshold —
        // a fast-scroll control that needs a shove before it moves feels broken.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin: Double
                if let dragOrigin {
                    origin = dragOrigin
                } else {
                    origin = currentPosition
                    dragOrigin = origin
                    feedback.prepare()
                    onDragChange(true)
                }

                let next = min(max(origin + Double(value.translation.height / travel), 0), 1)
                dragPosition = next

                guard let stop = scrubber.stop(atPosition: next), stop.sectionID != lastReportedID else {
                    return
                }
                lastReportedID = stop.sectionID
                feedback.selectionChanged()
                onScrub(stop)
            }
            .onEnded { _ in
                // Reported once more on release: the last `onChanged` may have landed mid-section,
                // and this is what verification step 3's "release → thumbnails fill in" settles on.
                if let dragPosition, let stop = scrubber.stop(atPosition: dragPosition) {
                    onScrub(stop)
                }
                dragPosition = nil
                dragOrigin = nil
                lastReportedID = nil
                onDragChange(false)
            }
    }
}
