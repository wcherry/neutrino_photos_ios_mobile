import SwiftUI

// MARK: - PhotoThumbnailView

/// One square cell in a grid.
///
/// Draws the plaintext cover thumbnail the Drive file carries — no download, no decryption, no
/// network call per cell. That is what lets a thousand-item timeline scroll: the pictures were
/// already in the listing response.
///
/// An item with no thumbnail is one the uploading client sent none for (every video, today) or one
/// whose server-side thumbnail job has not run yet. It draws its symbol rather than a blank square,
/// so the grid stays legible instead of gaining holes.
///
/// The decode goes through ``ThumbnailCache`` rather than happening here, so a cell scrolled back
/// into view redraws from a bitmap the app already has instead of decoding the same JPEG again.
struct PhotoThumbnailView: View {

    // MARK: - SelectionState

    /// How the cell should draw itself with respect to multi-select.
    ///
    /// Three cases rather than a `Bool` because "not selected" and "not selecting" look different
    /// and must: an unselected cell in selection mode shows an empty ring, so the grid says at a
    /// glance that tapping now selects rather than opens.
    enum SelectionState {
        case inactive
        case unselected
        case selected
    }

    let item: MediaItem
    /// Drawn over the corner for favourites, as Apple Photos does.
    var showsBadges: Bool = true
    var selectionState: SelectionState = .inactive

    @EnvironmentObject private var thumbnails: ThumbnailCache

    /// Held per cell rather than read in `body`: `body` runs on every scroll pass, and touching a
    /// cache from it would be a lookup per frame.
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind.placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        // Clipped *after* the aspect ratio so a landscape photograph fills the square and is
        // cropped, rather than being letterboxed into it.
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .bottomLeading) { badges }
        .overlay(alignment: .bottomTrailing) { selectionMark }
        // Applied over the overlays rather than under them, so the badges and the checkmark travel
        // with the picture. Inset while selected so the cell visibly moves under the finger — a
        // checkmark alone is easy to miss in a grid of thumbnails scrolling past. `scaleEffect`
        // rather than padding: it leaves the layout alone, so selecting cannot reflow the grid.
        .scaleEffect(selectionState == .selected ? 0.88 : 1)
        .animation(.easeOut(duration: 0.12), value: selectionState)
        // Keyed on the file *and* on whether it has a thumbnail at all, so a cell drawn before the
        // server's thumbnail job has run redraws when the next listing brings one. Not keyed on the
        // base64 itself: that is tens of kilobytes, compared on every scroll pass.
        .task(id: ThumbnailIdentity(fileID: item.fileID, hasThumbnail: item.thumbnailBase64 != nil)) {
            image = await thumbnails.image(for: item)
        }
    }

    // MARK: - Badges

    @ViewBuilder
    private var badges: some View {
        if showsBadges {
            HStack(spacing: 4) {
                if item.kind == .video {
                    Image(systemName: "video.fill")
                }
                // Stored, not rendered: the motion is in the account and a press-and-hold does not
                // play it yet. The badge is still worth drawing — it is how somebody can tell that
                // importing a Live Photo kept the half of it a grid cannot show.
                if item.isLivePhoto {
                    Image(systemName: "livephoto")
                }
                if item.isRAW {
                    Image(systemName: "camera.aperture")
                }
                if item.isStarred {
                    Image(systemName: "heart.fill")
                }
                if item.isArchived {
                    Image(systemName: "archivebox.fill")
                }
            }
            .font(.caption2)
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(4)
        }
    }

    // MARK: - Selection

    @ViewBuilder
    private var selectionMark: some View {
        switch selectionState {
        case .inactive:
            EmptyView()
        case .unselected:
            Image(systemName: "circle")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 2)
                .padding(5)
        case .selected:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .shadow(radius: 2)
                .padding(5)
        }
    }
}

// MARK: - ThumbnailIdentity

/// What has to change for a cell to fetch its picture again.
private struct ThumbnailIdentity: Equatable {
    let fileID: String
    let hasThumbnail: Bool
}
