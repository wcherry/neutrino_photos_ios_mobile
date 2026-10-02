import SwiftUI

// MARK: - ExternalDisplayView

/// What the room sees on a television or AirPlay receiver: the photograph, on black, and nothing
/// else.
///
/// Non-interactive — the external-display scene takes no touches — so every move comes from the
/// phone through ``ExternalDisplayService``.
struct ExternalDisplayView: View {

    @EnvironmentObject private var display: ExternalDisplayService

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if display.isPresenting {
                SlideshowStage(frame: display.frame,
                               transition: display.transition,
                               isAdvancing: display.isAdvancing,
                               adjustment: display.adjustment)
                    // A new slideshow starts fresh, rather than animating from wherever the last
                    // one stopped.
                    .id(display.sessionID)
            } else {
                standby
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// Shown outside a slideshow. Claiming the display means the system stops mirroring the phone,
    /// so the alternative to this is a blank screen that looks broken.
    private var standby: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .light))
            Text("Neutrino Photos")
                .font(.title2.weight(.semibold))
            Text("Open an album on your device and tap Play to show it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

// MARK: - SlideshowStage

/// A slideshow photograph filling its frame, with the transition played here.
///
/// Used on both screens. The phone and the external display are separate view graphs, so an
/// animation started on one does not carry across — each plays the transition itself, from the
/// same frame and the same settings.
struct SlideshowStage: View {

    let frame: SlideshowFrame?
    let transition: SlideshowTransition
    let isAdvancing: Bool
    var adjustment: PhotoAdjustment = .identity

    /// Trails `frame` so a change of photograph can be wrapped in `withAnimation` here, while a
    /// sharper picture of the *same* photograph replaces the blurry one without a transition.
    @State private var shown: SlideshowFrame?

    var body: some View {
        ZStack {
            if let shown {
                content(shown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(shown.itemID)
                    .transition(transition.anyTransition(isAdvancing: isAdvancing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear { shown = frame }
        .onChange(of: frame) { newFrame in
            if newFrame?.itemID == shown?.itemID {
                shown = newFrame
            } else {
                withAnimation(transition.animation) { shown = newFrame }
            }
        }
    }

    @ViewBuilder
    private func content(_ frame: SlideshowFrame) -> some View {
        if let image = frame.image {
            GeometryReader { proxy in
                let fitted = PhotoAdjustment.fittedSize(of: image.size, in: proxy.size)
                // Only the photograph on screen now is adjusted; one arriving starts fitted.
                let applied = frame.itemID == self.frame?.itemID ? adjustment : .identity
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(x: applied.scale * (applied.isFlippedHorizontally ? -1 : 1),
                                 y: applied.scale * (applied.isFlippedVertically ? -1 : 1))
                    .offset(applied.offset(fitted: fitted))
                    // Responsive enough to follow a finger, smooth enough that a flip or a zoom
                    // button reads as a movement rather than a jump — on both screens.
                    .animation(.interactiveSpring(), value: applied)
            }
        } else if frame.isUnavailable {
            Image(systemName: "lock.slash")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
        } else {
            ProgressView()
                .tint(.white)
        }
    }
}
