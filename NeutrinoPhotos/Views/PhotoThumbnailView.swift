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

    let item: MediaItem
    /// Drawn over the corner for favourites, as Apple Photos does.
    var showsBadges: Bool = true

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
}

// MARK: - ThumbnailIdentity

/// What has to change for a cell to fetch its picture again.
private struct ThumbnailIdentity: Equatable {
    let fileID: String
    let hasThumbnail: Bool
}
