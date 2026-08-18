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
struct PhotoThumbnailView: View {

    let item: MediaItem
    /// Drawn over the corner for favourites, as Apple Photos does.
    var showsBadges: Bool = true

    /// Decoded once per cell rather than in `body`: `body` runs on every scroll pass, and a base64
    /// decode plus a JPEG decode per frame is what turns a smooth grid into a stuttering one.
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
        .task(id: item.thumbnailBase64) { await decode() }
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

    // MARK: - Decoding

    private func decode() async {
        guard let data = item.thumbnailData else {
            image = nil
            return
        }
        // Off the main actor: a screenful of cells appearing at once is a screenful of JPEG decodes,
        // and doing them inline stalls the scroll they were supposed to fill.
        image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
    }
}
