import SwiftUI

// MARK: - TimelineGridView

/// The scrolling grid of photographs: day, month, or year sections with pinned headings, pinched
/// between densities, and travelled with the scrubber down the trailing edge.
///
/// Split out of ``LibraryView`` because it is the only part that touches scroll geometry, and
/// keeping that here means the banners, toolbar, and selection bar around it are not re-rendered by
/// a scroll. What it deliberately does *not* own is the sections themselves — those are grouped once
/// by ``TimelineCache`` and handed down, so a pinch regroups the library exactly once rather than on
/// every frame of the gesture.
struct TimelineGridView: View {

    // MARK: - Inputs

    let sections: [TimelineSection]
    /// The density `sections` were grouped at. Passed in rather than inferred because it is what
    /// says a *regroup* has happened, as distinct from the library merely having changed.
    let grouping: TimelineGrouping
    let columns: Int
    /// Owned by the parent, observed only by the scrubber.
    let position: TimelinePosition
    @Binding var selection: TimelineSelection

    let onOpen: (MediaItem) -> Void
    /// The long-press menu for one cell. Selection mode is entered from an item *in* this menu
    /// rather than from a long press of its own: a context menu is itself driven by a long press,
    /// and two recognizers on the same cell means neither reliably wins.
    @ViewBuilder let contextMenu: (MediaItem) -> AnyView

    /// Steps the density in or out. Nil when the timeline should not respond to a pinch at all.
    let onZoom: (TimelineZoomDirection) -> Void

    /// How far through the library the background fill has got, or nil once it holds all of it.
    ///
    /// The grid shows photographs after one page and grows behind the reader, so without this the
    /// bottom of the timeline is indistinguishable from the end of the library — and on a big
    /// library the two are minutes apart.
    let fillProgress: LibraryFillProgress?

    // MARK: - State

    /// Latched for the duration of one pinch so a gesture that keeps growing steps the density once
    /// rather than once per frame. Reset when the fingers lift.
    @State private var hasZoomedThisGesture = false

    /// The scrubber fades in on movement and out again when the timeline settles. Held here so the
    /// timer that clears it does not re-render the whole library screen.
    @State private var isScrubberActive = false
    @State private var isScrubbing = false
    @State private var scrubberIdleTask: Task<Void, Never>?

    private static let coordinateSpace = "timeline"

    // MARK: - Body

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            grid(for: section)
                        } header: {
                            header(for: section)
                        }
                        .id(section.id)
                    }
                    fillFooter
                }
                .padding(.bottom, 24)
            }
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(SectionFramePreference.self) { frames in
                updatePosition(from: frames)
                showScrubberBriefly()
            }
            .simultaneousGesture(pinch)
            .overlay(alignment: .trailing) { scrubber(proxy: proxy) }
            // The anchor a pinch left behind. Applied here rather than inside the gesture because
            // the new sections do not exist until the parent has regrouped and handed them back —
            // by which time this view has already been rebuilt with them.
            //
            // Keyed on the density and nothing else. Keying it on the sections instead would also
            // fire when the *library* changed, and an import that adds today's first photograph
            // changes the first section — so the timeline would scroll away from the picture that
            // just arrived to re-anchor on yesterday.
            .onChange(of: grouping) { _ in restoreAnchor(proxy: proxy) }
        }
    }

    // MARK: - Footer

    /// What sits below the last photograph while the library is still arriving.
    ///
    /// Inside the `LazyVStack` rather than pinned over the grid, because it is a statement about
    /// the bottom of the timeline specifically — "there is more below this" — and somewhere in the
    /// middle of the screen it would read as the whole library being unavailable, which it is not.
    @ViewBuilder
    private var fillFooter: some View {
        if let progress = fillProgress {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading \(progress.loaded.formatted()) of \(progress.total.formatted())…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Loading the rest of your library. \(progress.loaded.formatted()) of \(progress.total.formatted()) photos so far."
            )
        }
    }

    // MARK: - Sections

    private func header(for section: TimelineSection) -> some View {
        HStack {
            Text(section.title)
                .font(.headline)
            Spacer()
            Text("\(section.items.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Opaque: a pinned header over scrolling photographs is unreadable without it.
        .background(.bar)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SectionFramePreference.self,
                    value: [SectionFrame(
                        id: section.id,
                        start: section.start,
                        minY: geometry.frame(in: .named(Self.coordinateSpace)).minY
                    )]
                )
            }
        )
    }

    private func grid(for section: TimelineSection) -> some View {
        // Two points of spacing rather than none: a grid of edge-to-edge photographs reads as one
        // texture, and a hairline is enough to tell where each picture ends.
        LazyVGrid(columns: gridColumns, spacing: 2) {
            ForEach(section.items) { item in
                cell(for: item)
            }
        }
        .padding(.horizontal, 2)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columns)
    }

    @ViewBuilder
    private func cell(for item: MediaItem) -> some View {
        let content = Button {
            if selection.isActive {
                selection.toggle(item.id)
            } else {
                onOpen(item)
            }
        } label: {
            PhotoThumbnailView(item: item, selectionState: selectionState(for: item))
        }
        .buttonStyle(.plain)

        if selection.isActive {
            // No context menu in selection mode: its actions apply to one item, and the bar at the
            // bottom of the screen is already offering the same three for the whole selection.
            content
        } else {
            content.contextMenu { contextMenu(item) }
        }
    }

    private func selectionState(for item: MediaItem) -> PhotoThumbnailView.SelectionState {
        guard selection.isActive else { return .inactive }
        return selection.contains(item.id) ? .selected : .unselected
    }

    // MARK: - Pinch

    /// Steps between Days, Months, and Years.
    ///
    /// `simultaneousGesture` rather than `gesture` so the scroll view keeps its own pan: a pinch is
    /// two fingers and a scroll is one, and claiming the gesture outright would make the timeline
    /// stop scrolling.
    ///
    /// The step fires mid-gesture, as soon as the threshold is crossed, rather than on release. A
    /// density change that waits for the fingers to lift feels like it did not take, and doing it
    /// live is affordable precisely because the latch means it happens once.
    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !hasZoomedThisGesture else { return }
                if value > 1.35 {
                    hasZoomedThisGesture = true
                    onZoom(.in)
                } else if value < 0.75 {
                    hasZoomedThisGesture = true
                    onZoom(.out)
                }
            }
            .onEnded { _ in hasZoomedThisGesture = false }
    }

    // MARK: - Position and anchoring

    private func updatePosition(from frames: [SectionFrame]) {
        guard !frames.isEmpty else { return }
        // The pinned header sits at the top of the viewport, so the section at the top of the
        // screen is the last one whose header has reached it. When none has — the very top of the
        // library — the topmost header below the fold stands in.
        let pinned = frames.filter { $0.minY <= 1 }.max { $0.minY < $1.minY }
        let candidate = pinned ?? frames.min { $0.minY < $1.minY }
        position.update(id: candidate?.id, start: candidate?.start)
    }

    /// Scrolls back to the date the timeline was showing before it was regrouped.
    ///
    /// The anchor is a *date*, not a section: the sections it was captured from no longer exist
    /// after a density change. Without this, every pinch would land at the top of the library —
    /// verification step 2's failure.
    private func restoreAnchor(proxy: ScrollViewProxy) {
        guard let anchor = position.topSectionStart,
              let index = TimelineSection.index(containing: anchor, in: sections) else { return }
        proxy.scrollTo(sections[index].id, anchor: .top)
    }

    // MARK: - Scrubber

    @ViewBuilder
    private func scrubber(proxy: ScrollViewProxy) -> some View {
        let model = TimelineScrubber(sections: sections, columns: columns)
        if model.isUseful {
            TimelineScrubberView(
                scrubber: model,
                position: position,
                isActive: isScrubberActive || isScrubbing,
                onScrub: { stop in
                    // No animation: a scrubbed timeline animating between two dates a year apart
                    // would spend the whole drag catching up.
                    proxy.scrollTo(stop.sectionID, anchor: .top)
                },
                onDragChange: { isScrubbing = $0 }
            )
        }
    }

    /// Shows the track, then hides it again once the timeline has been still for a moment.
    ///
    /// Written carefully because it is called on *every* scroll frame. Both the obvious versions —
    /// assigning `isScrubberActive = true` each time, or restarting a one-shot timer each time —
    /// write `@State` sixty times a second, which re-renders this view and its whole grid. So the
    /// timestamp lives on the unobserved ``TimelinePosition``, the flag is written exactly twice per
    /// scroll, and a single poll decides when the timeline has gone quiet.
    private func showScrubberBriefly() {
        guard !isScrubberActive else { return }
        isScrubberActive = true

        scrubberIdleTask?.cancel()
        scrubberIdleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                guard Date().timeIntervalSince(position.lastMovedAt) > 1.2 else { continue }
                isScrubberActive = false
                return
            }
        }
    }
}

// MARK: - TimelineZoomDirection

/// Which way a pinch went. Named for the pictures rather than the calendar: "in" makes them bigger,
/// which means grouping the timeline more finely.
enum TimelineZoomDirection {
    case `in`
    case out
}

// MARK: - SectionFrame

/// Where one section's header currently sits in the scroll view's viewport.
private struct SectionFrame: Equatable {
    let id: String
    let start: Date
    let minY: CGFloat
}

private struct SectionFramePreference: PreferenceKey {
    static var defaultValue: [SectionFrame] = []

    static func reduce(value: inout [SectionFrame], nextValue: () -> [SectionFrame]) {
        value.append(contentsOf: nextValue())
    }
}
