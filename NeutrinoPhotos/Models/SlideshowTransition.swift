import SwiftUI

// MARK: - SlideshowTransition

/// How one photograph gives way to the next in a slideshow.
///
/// Stored by raw value in ``AppSettings``, so a case can be added but never renamed — a renamed
/// case reads back as the default rather than as what the user picked.
enum SlideshowTransition: String, Codable, CaseIterable, Identifiable {
    case dissolve
    case slide
    case zoom
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dissolve: return "Dissolve"
        case .slide:    return "Slide"
        case .zoom:     return "Zoom"
        case .none:     return "None"
        }
    }

    /// How long the change takes. Long enough to read as deliberate on a television across a room;
    /// short against the shortest interval the slider offers, so a photograph is never still moving
    /// when it is time to leave.
    var duration: TimeInterval {
        switch self {
        case .dissolve: return 0.8
        case .slide:    return 0.6
        case .zoom:     return 0.9
        case .none:     return 0
        }
    }

    /// The animation that drives the change, or nil for a cut.
    var animation: Animation? {
        self == .none ? nil : .easeInOut(duration: duration)
    }

    /// The SwiftUI transition, shared by the phone and the external display so both play the same
    /// one.
    ///
    /// `isAdvancing` is which way the last move went, so a directional transition slides the right
    /// way when the user steps *back*.
    func anyTransition(isAdvancing: Bool) -> AnyTransition {
        switch self {
        case .none:
            return .identity
        case .dissolve:
            return .opacity
        case .slide:
            return .asymmetric(insertion: .move(edge: isAdvancing ? .trailing : .leading),
                               removal: .move(edge: isAdvancing ? .leading : .trailing))
        case .zoom:
            return .asymmetric(insertion: .scale(scale: 1.12).combined(with: .opacity),
                               removal: .opacity)
        }
    }
}
