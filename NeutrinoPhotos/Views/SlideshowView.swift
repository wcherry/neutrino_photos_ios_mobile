import SwiftUI

// MARK: - SlideshowView

/// An album played as a slideshow.
///
/// Two layouts, chosen by whether an external display is connected:
///
/// - **No display.** The photographs fill this screen; a tap shows and hides the controls.
/// - **A display.** The photographs go to the television through ``ExternalDisplayService`` and
///   this screen becomes the remote, held in portrait: the current photograph, the next one, the
///   time per photograph and the transition — what the person running the slideshow needs and the
///   room does not.
///
/// Switching between them mid-slideshow is a cable being plugged in or an AirPlay receiver being
/// picked in Control Center, and nothing restarts: ``SlideshowController`` owns the position, and
/// the display picks up wherever it is.
struct SlideshowView: View {

    @StateObject private var controller: SlideshowController

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var display: ExternalDisplayService
    @Environment(\.dismiss) private var dismiss

    @State private var showsChrome = true
    @State private var showsExternalDisplayHelp = false

    init(controller: @autoclosure @escaping () -> SlideshowController) {
        _controller = StateObject(wrappedValue: controller())
    }

    /// What the auto-advance countdown restarts on.
    private struct AdvanceKey: Equatable {
        let index: Int
        let isPlaying: Bool
        let interval: TimeInterval
    }

    // MARK: - Body

    var body: some View {
        Group {
            if display.isConnected {
                SlideshowConsoleView(controller: controller, onDone: { dismiss() })
            } else {
                fullScreen
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: controller.index) { await controller.loadWindow() }
        .task(id: AdvanceKey(index: controller.index, isPlaying: controller.isPlaying,
                             interval: controller.interval)) {
            await controller.autoAdvance()
        }
        .onAppear {
            // Only while the slideshow is up, and put back on the way out — a global "never sleep"
            // would outlive it and flatten the battery of a phone left on a table.
            UIApplication.shared.isIdleTimerDisabled = true
            // Sent whether or not a display is connected yet, so one plugged in mid-slideshow picks
            // up at the current photograph.
            controller.start()
            updateOrientationLock(isConsole: display.isConnected)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stop()
            OrientationLock.unlock()
        }
        .onChange(of: display.isConnected) { updateOrientationLock(isConsole: $0) }
        // Remembered for the next slideshow, in any album.
        .onChange(of: controller.interval) { settings.slideshowInterval = $0 }
        .onChange(of: controller.transition) { settings.slideshowTransition = $0 }
        .alert("Show on a TV", isPresented: $showsExternalDisplayHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open Control Center and choose Screen Mirroring to pick an AirPlay display, "
                 + "or connect a display with a cable. The photos then appear on that screen "
                 + "and this one shows the next photo and the slideshow controls.")
        }
        .preferredColorScheme(.dark)
    }

    /// Portrait while this is the remote. Released as soon as the display goes: a slideshow on the
    /// phone alone wants landscape for landscape photographs.
    private func updateOrientationLock(isConsole: Bool) {
        if isConsole {
            OrientationLock.lock(.portrait)
        } else {
            OrientationLock.unlock()
        }
    }

    // MARK: - Full screen

    /// The slideshow filling this screen — the only display there is.
    private var fullScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AdjustableSlideshowStage(controller: controller) {
                withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
            }
            .ignoresSafeArea()

            if showsChrome {
                chrome
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
    }

    private var chrome: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                }
                .accessibilityLabel("End slideshow")

                SlideshowCounter(controller: controller)

                Spacer()

                // iOS gives apps no way to start AirPlay mirroring themselves, so this explains
                // where the system's own control is rather than pretending to be it.
                Button {
                    showsExternalDisplayHelp = true
                } label: {
                    Image(systemName: "airplayvideo")
                        .font(.title3)
                }
                .accessibilityLabel("Show on a TV")
            }

            Spacer()

            if let failure = controller.failures[controller.current.id] {
                Text(failure)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            SlideshowControlsPanel(controller: controller)
                .padding(16)
                .frame(maxWidth: 520)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(16)
    }
}

// MARK: - SlideshowConsoleView

/// The phone's screen while the photographs are on an external display.
private struct SlideshowConsoleView: View {

    @ObservedObject var controller: SlideshowController
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            header

            // A reminder of what the room sees, with the same transition — and where the zoom,
            // pan and step that the room then sees are done.
            AdjustableSlideshowStage(controller: controller) {
                // Not while adjusted: moving on resets the zoom, and a stray tap would throw away
                // the detail somebody had just zoomed in to show the room.
                if controller.adjustment.isIdentity { controller.next() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Current photo")
            .accessibilityHint("Tap to advance, pinch to zoom")

            if let failure = controller.failures[controller.current.id] {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            nextPhoto

            SlideshowControlsPanel(controller: controller)
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(16)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onDone) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel("End slideshow")

            Label("On external display", systemImage: "tv")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            SlideshowCounter(controller: controller)
        }
    }

    /// The photograph coming up, as one row — a thumbnail and a label — so it costs the current
    /// photograph as little height as possible.
    private var nextPhoto: some View {
        HStack(spacing: 12) {
            if let next = controller.nextItem {
                ZStack {
                    Color.white.opacity(0.06)
                    if let image = controller.images[next.id] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 128, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(next.displayName)
                        .font(.footnote)
                        .lineLimit(1)
                }
            } else {
                Text("Only photo in this slideshow")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - SlideshowControlsPanel

/// Step, play and pause, the time per photograph and the transition — the same panel on both
/// layouts, so nothing moves when a display is plugged in.
private struct SlideshowControlsPanel: View {

    @ObservedObject var controller: SlideshowController

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 40) {
                Button(action: controller.previous) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Previous photo")

                Button {
                    controller.isPlaying.toggle()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                }
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                Button(action: controller.next) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Next photo")
            }
            .disabled(controller.items.count < 2)

            adjustmentRow

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Time per photo", systemImage: "timer")
                    Spacer()
                    Text("\(Int(controller.interval)) sec")
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Slider(value: $controller.interval, in: AppSettings.slideshowIntervalRange, step: 1)
                    .tint(.white)
                    .accessibilityLabel("Time per photo")
                    .accessibilityValue("\(Int(controller.interval)) seconds")
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Transition", systemImage: "square.on.square")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Transition", selection: $controller.transition) {
                    ForEach(SlideshowTransition.allCases) { transition in
                        Text(transition.displayName).tag(transition)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .foregroundStyle(.white)
    }

    /// Zoom, flip and reset. Pan has no button — it is a drag on the photograph, which is the only
    /// way to say *where* to look.
    private var adjustmentRow: some View {
        let adjustment = controller.adjustment
        return HStack {
            adjustmentButton("Zoom out", systemImage: "minus.magnifyingglass") {
                controller.zoom(by: 1 / 1.5)
            }
            .disabled(adjustment.scale <= PhotoAdjustment.scaleRange.lowerBound)

            adjustmentButton("Zoom in", systemImage: "plus.magnifyingglass") {
                controller.zoom(by: 1.5)
            }
            .disabled(adjustment.scale >= PhotoAdjustment.scaleRange.upperBound)

            adjustmentButton("Flip horizontally",
                             systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                             isOn: adjustment.isFlippedHorizontally) {
                controller.flipHorizontally()
            }

            adjustmentButton("Flip vertically",
                             systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                             isOn: adjustment.isFlippedVertically) {
                controller.flipVertically()
            }

            adjustmentButton("Reset", systemImage: "arrow.counterclockwise") {
                controller.resetAdjustment()
            }
            .disabled(adjustment.isIdentity)
        }
    }

    private func adjustmentButton(_ title: String, systemImage: String, isOn: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(isOn ? Color.white.opacity(0.25) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - AdjustableSlideshowStage

/// The phone's photograph, with the gestures that adjust it: pinch to zoom, drag to pan once zoomed
/// in, double-tap to zoom in and back, and — when not zoomed — a horizontal swipe to step.
///
/// The gestures only change ``SlideshowController/adjustment``; drawing it is ``SlideshowStage``'s
/// job, so the external display draws exactly what this one does.
private struct AdjustableSlideshowStage: View {

    @ObservedObject var controller: SlideshowController
    let onTap: () -> Void

    /// The adjustment a gesture started from, so it applies relative to that rather than compounding
    /// on every update.
    @State private var pinchStart: PhotoAdjustment?
    @State private var dragStart: PhotoAdjustment?

    var body: some View {
        GeometryReader { proxy in
            SlideshowStage(frame: controller.frame,
                           transition: controller.transition,
                           isAdvancing: controller.isAdvancing,
                           adjustment: controller.adjustment)
                .contentShape(Rectangle())
                .gesture(drag(in: proxy.size))
                .simultaneousGesture(pinch)
                .onTapGesture(count: 2) { controller.toggleZoom() }
                .onTapGesture(perform: onTap)
        }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let start = pinchStart ?? controller.adjustment
                pinchStart = start
                controller.adjust { $0.scale = start.scale * value }
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func drag(in viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // At fitted size there is nothing to pan to, and the drag is a swipe.
                guard controller.adjustment.scale > 1 || dragStart != nil else { return }
                let start = dragStart ?? controller.adjustment
                dragStart = start
                let fitted = fittedSize(in: viewport)
                guard fitted.width > 0, fitted.height > 0 else { return }
                controller.adjust {
                    $0.pan = CGSize(width: start.pan.width + value.translation.width / fitted.width,
                                    height: start.pan.height + value.translation.height / fitted.height)
                }
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard dragStart == nil else { return }
                let translation = value.translation
                guard abs(translation.width) > 40, abs(translation.width) > abs(translation.height)
                else { return }
                if translation.width < 0 { controller.next() } else { controller.previous() }
            }
    }

    private func fittedSize(in viewport: CGSize) -> CGSize {
        guard let image = controller.frame.image else { return .zero }
        return PhotoAdjustment.fittedSize(of: image.size, in: viewport)
    }
}

// MARK: - Pieces

/// "3 / 40".
private struct SlideshowCounter: View {

    @ObservedObject var controller: SlideshowController

    var body: some View {
        Text("\(controller.index + 1) / \(controller.items.count)")
            .font(.footnote.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
