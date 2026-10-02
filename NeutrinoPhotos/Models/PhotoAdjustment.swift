import CoreGraphics

// MARK: - PhotoAdjustment

/// Zoom, pan and flip applied to the photograph a slideshow is showing.
///
/// Set on the phone and drawn on both screens, so it is stated in units that mean the same thing on
/// a 6-inch phone and a 65-inch television: ``pan`` is a fraction of the photograph's *fitted*
/// size, not points. Half a photograph to the left is half a photograph to the left on either
/// screen, whatever their sizes.
///
/// Belongs to one photograph. Moving to the next starts from ``identity``.
struct PhotoAdjustment: Equatable {

    /// 1 is the photograph fitted to the screen.
    var scale: CGFloat = 1
    /// How far the photograph is moved, as a fraction of its fitted width and height.
    var pan: CGSize = .zero
    var isFlippedHorizontally = false
    var isFlippedVertically = false

    static let identity = PhotoAdjustment()
    static let scaleRange: ClosedRange<CGFloat> = 1...5

    var isIdentity: Bool { self == .identity }

    /// Zoom kept within ``scaleRange``, and pan within the photograph.
    ///
    /// The pan limit is how far the zoomed photograph overhangs its fitted frame, half on each side:
    /// at 2× a photograph can move half its fitted width either way and no further, so the
    /// edge of the picture never comes past where it sat unzoomed. It depends only on the zoom —
    /// not on the screen — so the phone and the television agree about it.
    func clamped() -> PhotoAdjustment {
        var result = self
        result.scale = min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let limit = (result.scale - 1) / 2
        result.pan = CGSize(width: min(max(pan.width, -limit), limit),
                            height: min(max(pan.height, -limit), limit))
        return result
    }

    /// The pan in points, for a photograph fitted to `fitted`.
    func offset(fitted: CGSize) -> CGSize {
        CGSize(width: pan.width * fitted.width, height: pan.height * fitted.height)
    }

    /// The size an image of `imageSize` is drawn at when fitted, aspect intact, inside `box`.
    static func fittedSize(of imageSize: CGSize, in box: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, box.width > 0, box.height > 0 else {
            return .zero
        }
        let factor = min(box.width / imageSize.width, box.height / imageSize.height)
        return CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
    }
}
