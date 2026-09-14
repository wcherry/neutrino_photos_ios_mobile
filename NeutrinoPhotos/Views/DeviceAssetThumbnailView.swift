import SwiftUI

// MARK: - DeviceAssetThumbnailView

/// One square cell of the device-library grid.
///
/// The counterpart to ``PhotoThumbnailView``, and deliberately a separate view rather than a
/// generalisation of it: the two draw pictures that arrive by completely different routes — that one
/// decodes a base64 thumbnail the server already sent, this one asks Photos to render one — and the
/// badges say different things. There, they describe a photograph in the account; here, the one
/// badge that matters is whether this item is *already* in the account, which is the whole question
/// somebody scanning this grid is asking.
struct DeviceAssetThumbnailView: View {

    let asset: ScannedAsset
    /// The side of the cell in points, which decides the pixel size asked of Photos. Passed in
    /// rather than measured per cell: every cell in the grid is the same size, and measuring it
    /// forty times a screen would be forty geometry readers.
    let side: CGFloat
    /// Already in the Neutrino library, as the import ledger records it.
    let isImported: Bool
    var selectionState: PhotoThumbnailView.SelectionState = .inactive

    @EnvironmentObject private var browser: DeviceLibraryBrowser

    /// Held per cell rather than read in `body`: `body` runs on every scroll pass.
    @State private var image: UIImage?

    // MARK: - Body

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: asset.isVideo ? "video" : "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .contentShape(Rectangle())
        // Dimmed rather than hidden or disabled. An item already uploaded is still worth seeing —
        // it is how somebody reads the grid as "these are backed up and these are not" — and it is
        // still selectable, because re-selecting it is harmless: the ledger skips it.
        .opacity(isImported && selectionState != .selected ? 0.55 : 1)
        .overlay(alignment: .bottomLeading) { badges }
        .overlay(alignment: .topTrailing) { importedMark }
        .overlay(alignment: .bottomTrailing) { selectionMark }
        .scaleEffect(selectionState == .selected ? 0.88 : 1)
        .animation(.easeOut(duration: 0.12), value: selectionState)
        // Keyed on the asset and the size, so a cell reused for a different item — which is what
        // `LazyVGrid` does as you scroll — fetches the new one, and a rotation that changes the
        // column width re-requests at the size it will actually be drawn at.
        .task(id: ThumbnailRequest(identifier: asset.localIdentifier, side: side)) {
            image = await browser.thumbnail(for: asset.localIdentifier, targetSize: pixelSize)
        }
    }

    /// The size asked of Photos, in pixels rather than points — `PHImageManager` works in pixels,
    /// and asking for 120 of them to fill a 120-point cell on a 3× screen is a blurred grid.
    private var pixelSize: CGSize {
        let scale = UIScreen.main.scale
        let pixels = max(side, 1) * scale
        return CGSize(width: pixels, height: pixels)
    }

    // MARK: - Badges

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if asset.isVideo {
                Image(systemName: "video.fill")
                if let duration = Self.durationText(asset.duration) {
                    Text(duration)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .shadow(radius: 2)
        .padding(4)
    }

    /// "Already in your library", as one mark in the corner.
    ///
    /// Drawn opposite the selection tick so the two never sit on top of each other, and suppressed
    /// while the cell is selected — at that point the tick is the thing the user is reading, and two
    /// circles in one small square is noise.
    @ViewBuilder
    private var importedMark: some View {
        if isImported && selectionState != .selected {
            Image(systemName: "checkmark.icloud.fill")
                .font(.caption)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .shadow(radius: 2)
                .padding(5)
        }
    }

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

    // MARK: - Duration

    /// "0:07", "1:42", "1:02:03". Nil for anything that is not a video with a real length.
    ///
    /// Hand-built rather than `DateComponentsFormatter`: that one writes "1:02" for 62 seconds and
    /// "2:03" for 123, dropping the leading zero a clock length needs, and configuring it out of
    /// that costs more than the arithmetic.
    static func durationText(_ seconds: TimeInterval) -> String? {
        guard seconds >= 1, seconds.isFinite else { return nil }
        let total = Int(seconds.rounded())
        let (hours, minutes, remainder) = (total / 3600, (total % 3600) / 60, total % 60)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

// MARK: - ThumbnailRequest

/// What has to change for a cell to ask Photos for a picture again.
private struct ThumbnailRequest: Equatable {
    let identifier: String
    let side: CGFloat
}
