import AVFoundation
import AVKit
import SwiftUI

// MARK: - PhotoDetailView

/// The full-screen viewer: one page per item, swiped between, with the actions that apply to the
/// one on screen.
///
/// This is the only place an *original* is fetched. The grid behind it draws cover thumbnails, so
/// opening a photograph is the first time its bytes are downloaded, its file key unsealed, and the
/// picture decrypted — which is why a page can be loading while its neighbours are already drawn.
struct PhotoDetailView: View {

    let items: [MediaItem]
    let initialID: String

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var albums: AlbumService
    @EnvironmentObject private var content: MediaContentService
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary
    /// Held only to hand on to the info sheet, which says whether a location was published.
    @EnvironmentObject private var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String
    @State private var showsChrome = true
    @State private var showsInfo = false
    @State private var showsAlbumPicker = false
    @State private var isSaving = false
    /// The one line the save reports, success or failure. An alert rather than a toast because
    /// "saved" and "couldn't save" are both worth being sure of, and a photo library is the sort of
    /// place a user goes looking straight afterwards.
    @State private var saveOutcome: SaveOutcome?

    init(items: [MediaItem], initialID: String) {
        self.items = items
        self.initialID = initialID
        _currentID = State(initialValue: initialID)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentID) {
                ForEach(items) { item in
                    MediaPage(item: item, showsChrome: $showsChrome)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if showsChrome {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
            }
        }
        .statusBarHidden(!showsChrome)
        .animation(.easeInOut(duration: 0.2), value: showsChrome)
        .sheet(isPresented: $showsInfo) {
            if let current {
                MediaInfoView(item: current)
                    .environmentObject(settings)
            }
        }
        .sheet(isPresented: $showsAlbumPicker) {
            if let current {
                AlbumPickerView(item: current)
                    .environmentObject(albums)
            }
        }
        .alert(saveOutcome?.title ?? "", isPresented: saveAlertBinding) {
            Button("OK") { saveOutcome = nil }
        } message: {
            Text(saveOutcome?.message ?? "")
        }
    }

    // MARK: - Save to device

    /// What a save reported.
    private struct SaveOutcome: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var saveAlertBinding: Binding<Bool> {
        Binding(get: { saveOutcome != nil }, set: { if !$0 { saveOutcome = nil } })
    }

    /// Writes the item's decrypted original back into Apple Photos.
    ///
    /// The **original**, not what is on screen: the viewer may be showing a 2048 px preview, and
    /// exporting that would hand the user a downscaled copy of their own photograph under the name
    /// of the real one. So this fetches the full file, which for anything not already cached is a
    /// download — hence the spinner.
    ///
    /// A Live Photo goes back with its motion. That is what ``MediaContentService/livePhotoVideoURL(for:)``
    /// is for, and it is the round trip verification step 7 asks for: import a Live Photo, export
    /// it, and get a Live Photo back rather than a still and a stray clip.
    private func saveToDevice() async {
        guard let item = current, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            if item.kind == .video {
                let url = try await content.localURL(for: item)
                try await deviceLibrary.save(videoAt: url, fileName: item.fileName)
            } else {
                let data = try await content.originalData(for: item)
                // Best-effort: a Live Photo whose motion will not come down is still worth saving
                // as the photograph it is.
                let motion = item.liveVideoFileID == nil
                    ? nil
                    : try? await content.livePhotoVideoURL(for: item)
                try await deviceLibrary.save(photo: data, fileName: item.fileName,
                                             pairedVideoURL: motion)
            }
            saveOutcome = SaveOutcome(
                title: "Saved",
                message: "\(item.displayName) is in your device's photo library.")
        } catch where error.isCancellation {
            // The view went away mid-download. Nothing was saved and nobody is waiting on an alert.
        } catch {
            saveOutcome = SaveOutcome(title: "Couldn't Save",
                                      message: error.localizedDescription)
        }
    }

    // MARK: - Current item

    /// Read out of the service rather than out of `items` so a favourite toggled here is reflected
    /// in the toolbar immediately; `items` is the snapshot the viewer was opened with.
    private var current: MediaItem? {
        library.item(id: currentID) ?? items.first { $0.id == currentID }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            VStack(spacing: 2) {
                Text(current?.displayName ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let date = current?.timelineDate {
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showsInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        // Tightened from 36 when Save to Device made this five buttons: at 36 the row overflows a
        // 320 pt screen, and the first thing to fall off it is Delete.
        HStack(spacing: 28) {
            if FeatureFlags.favorites {
                Button {
                    guard let current else { return }
                    library.setStarred(id: current.id, isStarred: !current.isStarred)
                } label: {
                    Image(systemName: current?.isStarred == true ? "heart.fill" : "heart")
                }
            }
            if FeatureFlags.deviceLibraryAccess {
                Button {
                    Task { await saveToDevice() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .disabled(isSaving)
            }
            if FeatureFlags.albums {
                Button {
                    showsAlbumPicker = true
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                }
            }
            if FeatureFlags.archive {
                Button {
                    guard let current else { return }
                    library.setArchived(id: current.id, isArchived: !current.isArchived)
                } label: {
                    Image(systemName: current?.isArchived == true
                          ? "arrow.up.bin" : "archivebox")
                }
            }
            if FeatureFlags.trash {
                Button(role: .destructive) {
                    guard let current else { return }
                    library.trash(id: current.id)
                    // Nothing left to look at once it is out of the timeline this viewer was
                    // opened over.
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .font(.title3)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

// MARK: - MediaPage

/// One item at full size: a zoomable photograph, or a video player.
///
/// ## The ladder, climbed as it is needed
///
/// Three steps, each replacing the last in place so the picture sharpens rather than flashes:
///
/// | Step | Where it comes from | When |
/// |---|---|---|
/// | Thumbnail | the cover the grid already drew — no network at all | immediately |
/// | Preview | the 2048 px encrypted rendition, or the original downscaled | on open |
/// | Original | the full file, decrypted | only once zoomed past ``originalZoomThreshold`` |
///
/// Starting from the thumbnail is what makes a swipe through twenty photographs show a picture on
/// every page instead of a spinner: the bytes for it are already on the device. Stopping at the
/// preview until a zoom asks for more is what keeps opening a photograph from downloading twelve
/// megapixels to fill a screen that can show two.
private struct MediaPage: View {

    // MARK: - Stage

    /// How far up the ladder this page has climbed. Ordered so a step can never be replaced by a
    /// coarser one that finished later — a thumbnail arriving after its preview would otherwise
    /// blur a picture that was already sharp.
    private enum Stage: Int, Comparable {
        case none
        case thumbnail
        case preview
        case original

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let item: MediaItem
    @Binding var showsChrome: Bool

    @EnvironmentObject private var content: MediaContentService
    @EnvironmentObject private var thumbnails: ThumbnailCache
    @EnvironmentObject private var vault: KeyVaultService

    @State private var image: UIImage?
    @State private var stage: Stage = .none
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isLoadingOriginal = false
    /// Set when the failure was specifically "no key on this device", which is the one failure with
    /// something the user can do about it right here.
    @State private var isLocked = false
    @State private var showsUnlock = false

    /// Committed zoom, and the live pinch on top of it. Split so a gesture that ends below 1×
    /// springs back rather than leaving the picture smaller than the screen.
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    /// The page's own size, kept so pan can be clamped and so a rotation can re-clamp what was
    /// legal in portrait and is not in landscape.
    @State private var viewport: CGSize = .zero

    /// How far in a zoom has to go before the original is worth fetching. Just past a double-tap's
    /// worth of magnification: below it the preview genuinely has the pixels, and above it the
    /// screen is showing less of the picture than the preview can resolve.
    private let originalZoomThreshold: CGFloat = 1.5
    private let maximumZoom: CGFloat = 10

    // MARK: - Body

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let error, stage < .preview {
                // Checked *before* the picture, because by this point there is usually a thumbnail
                // on screen and drawing it would hide the failure — and with it the Unlock button,
                // which is the whole of what the user can do about the commonest failure there is.
                failure(error)
            } else if let image {
                photo(image)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A photograph still on its thumbnail, or fetching its original for a zoom, says so rather
        // than leaving the user to wonder whether the blur is the picture.
        .overlay(alignment: .topTrailing) { sharpeningIndicator }
        .task(id: item.id) { await load() }
        .onChange(of: scale) { newScale in
            guard newScale >= originalZoomThreshold else { return }
            Task { await loadOriginal() }
        }
        .sheet(isPresented: $showsUnlock) {
            VaultUnlockView(onUnlocked: {
                // Clear the failure so `load()` runs again for this page when the sheet closes.
                error = nil
                isLocked = false
            })
            .environmentObject(vault)
        }
        .onChange(of: showsUnlock) { isPresented in
            guard !isPresented, error == nil else { return }
            Task { await load() }
        }
    }

    // MARK: - Photo

    private func photo(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale * pinch)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                .gesture(
                    MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { value in
                            scale = min(max(1, scale * value), maximumZoom)
                            if scale == 1 {
                                offset = .zero
                            } else {
                                offset = clamped(offset, image: image)
                            }
                        }
                )
                // Panning is only live while zoomed in: at 1× the horizontal drag belongs to the
                // pager, and claiming it would stop the viewer swiping between photographs.
                // `.subviews` leaves this view's own gesture out of the running without disabling
                // the ancestor's.
                .gesture(panGesture(image: image), including: scale > 1 ? .all : .subviews)
                .onTapGesture(count: 2) { toggleZoom() }
                .onTapGesture { showsChrome.toggle() }
                .animation(.easeInOut(duration: 0.2), value: scale)
                .onAppear { viewport = geometry.size }
                // A rotation keeps the zoom — what step 6 asks for — but an offset that was inside
                // the picture in portrait can be outside it in landscape, so it is re-clamped.
                .onChange(of: geometry.size) { size in
                    viewport = size
                    offset = clamped(offset, image: image)
                }
        }
    }

    private func panGesture(image: UIImage) -> some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset = clamped(
                    CGSize(width: offset.width + value.translation.width,
                           height: offset.height + value.translation.height),
                    image: image
                )
            }
    }

    private func toggleZoom() {
        if scale > 1 {
            scale = 1
            offset = .zero
        } else {
            scale = 2.5
        }
    }

    /// Keeps a pan inside the picture, so a photograph cannot be flung off the screen and left
    /// there with nothing to drag back.
    ///
    /// The bound is half the overhang on each axis: how far the zoomed picture extends past the
    /// viewport, which is zero on an axis the picture does not fill — a wide photograph zoomed a
    /// little is still letterboxed vertically, and should not move up and down.
    private func clamped(_ offset: CGSize, image: UIImage) -> CGSize {
        guard viewport.width > 0, viewport.height > 0, image.size.width > 0, image.size.height > 0
        else { return offset }

        let fitted = AVMakeRect(aspectRatio: image.size,
                                insideRect: CGRect(origin: .zero, size: viewport)).size
        let limitX = max(0, (fitted.width * scale - viewport.width) / 2)
        let limitY = max(0, (fitted.height * scale - viewport.height) / 2)

        return CGSize(width: min(max(offset.width, -limitX), limitX),
                      height: min(max(offset.height, -limitY), limitY))
    }

    // MARK: - Sharpening

    @ViewBuilder
    private var sharpeningIndicator: some View {
        if isLoadingOriginal || (stage == .thumbnail && error == nil) {
            ProgressView()
                .tint(.white)
                .padding(8)
                .background(.black.opacity(0.35), in: Circle())
                .padding(.top, 60)
                .padding(.trailing, 16)
                .transition(.opacity)
        }
    }

    // MARK: - Failure

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.slash")
                .font(.largeTitle)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if isLocked {
                Button("Unlock") { showsUnlock = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
    }

    // MARK: - Loading

    private func load() async {
        guard !isLoading, stage < .preview, player == nil else { return }
        isLoading = true
        defer { isLoading = false }

        // Step one, before anything is asked of the network. The grid drew this cell a moment ago,
        // so its cover is already decoded — a page that opens on it never shows an empty frame, and
        // a video gets a poster to sit behind its player instead of a black rectangle.
        if let cover = await thumbnails.image(for: item), stage < .thumbnail {
            image = cover
            stage = .thumbnail
        }

        do {
            if item.kind == .video {
                guard FeatureFlags.videoPlayback else {
                    error = "Video playback isn't available in this build."
                    return
                }
                // A video has to be decrypted to a file before it can be played: `AVPlayer` reads
                // from a URL, and the Drive URL serves ciphertext no player could demux.
                player = AVPlayer(url: try await content.localURL(for: item))
                stage = .preview
            } else {
                image = try await content.image(for: item, rendition: .preview)
                stage = .preview
            }
        } catch let error as MediaContentError {
            // "No key on this device" is the one failure here with a next step, so it gets one.
            if case .noEncryptionKey = error { isLocked = true }
            self.error = error.localizedDescription
            return
        } catch where error.isCancellation {
            // Swiping to the next photograph cancels this page's download — `.task(id:)` re-keys on
            // the item. The page being left has nothing to report.
            return
        } catch {
            self.error = error.localizedDescription
            return
        }

        // A zoom that happened while the preview was still downloading would otherwise be lost:
        // `onChange(of: scale)` did fire, but it fired while the page was still on its thumbnail
        // and `loadOriginal` refused. This is the catch-up.
        if scale >= originalZoomThreshold {
            await loadOriginal()
        }
    }

    /// The last step of the ladder, taken only when a zoom has gone far enough to want it.
    ///
    /// A failure here is swallowed on purpose: the preview is still on screen and still correct, so
    /// there is nothing to tell the user and nothing for them to do. That is different from
    /// ``load()`` failing, which leaves an empty page and has to say why.
    private func loadOriginal() async {
        guard item.kind == .photo, stage == .preview, !isLoadingOriginal else { return }
        isLoadingOriginal = true
        defer { isLoadingOriginal = false }

        guard let full = try? await content.image(for: item, rendition: .original) else { return }
        // Re-checked after the await: a swipe or a pinch back to 1× may have moved on while the
        // original was downloading, and `stage` is what says whether this is still wanted.
        guard stage == .preview else { return }
        image = full
        stage = .original
    }
}
