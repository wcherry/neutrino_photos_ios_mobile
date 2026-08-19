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

    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String
    @State private var showsChrome = true
    @State private var showsInfo = false
    @State private var showsAlbumPicker = false

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
            }
        }
        .sheet(isPresented: $showsAlbumPicker) {
            if let current {
                AlbumPickerView(item: current)
                    .environmentObject(albums)
            }
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
        HStack(spacing: 36) {
            if FeatureFlags.favorites {
                Button {
                    guard let current else { return }
                    library.setStarred(id: current.id, isStarred: !current.isStarred)
                } label: {
                    Image(systemName: current?.isStarred == true ? "heart.fill" : "heart")
                }
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
private struct MediaPage: View {

    let item: MediaItem
    @Binding var showsChrome: Bool

    @EnvironmentObject private var content: MediaContentService
    @EnvironmentObject private var vault: KeyVaultService

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var isLoading = false
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

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let image {
                photo(image)
            } else if let error {
                failure(error)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) { await load() }
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
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale * pinch)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        scale = min(max(1, scale * value), 6)
                        if scale == 1 { offset = .zero }
                    }
            )
            // Panning is only attached while zoomed in: at 1× the horizontal drag belongs to the
            // pager, and claiming it would stop the viewer swiping between photographs.
            .gesture(scale > 1 ? panGesture : nil)
            .onTapGesture(count: 2) { toggleZoom() }
            .onTapGesture { showsChrome.toggle() }
            .animation(.easeInOut(duration: 0.2), value: scale)
    }

    private var panGesture: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
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
        guard !isLoading, image == nil, player == nil else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            if item.kind == .video {
                guard FeatureFlags.videoPlayback else {
                    error = "Video playback isn't available in this build."
                    return
                }
                // A video has to be decrypted to a file before it can be played: `AVPlayer` reads
                // from a URL, and the Drive URL serves ciphertext no player could demux.
                player = AVPlayer(url: try await content.localURL(for: item))
            } else {
                image = try await content.image(for: item)
            }
        } catch let error as MediaContentError {
            // "No key on this device" is the one failure here with a next step, so it gets one.
            if case .noEncryptionKey = error { isLocked = true }
            self.error = error.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
