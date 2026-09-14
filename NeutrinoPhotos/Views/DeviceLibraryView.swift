import SwiftUI

// MARK: - DeviceLibraryView

/// The photos on this iPhone, as an album beside the ones in the account.
///
/// ## Why it belongs in Albums
///
/// Everything else in that tab answers "where is a picture?" — Favorites, an album, Recently
/// Deleted. This answers the same question for the one place a Neutrino photo app cannot otherwise
/// look: the phone it is running on. Putting it anywhere else would make "the photos on this device"
/// a *setting* rather than a place, and somebody who wants to check whether last weekend is backed
/// up should not have to go through Settings to find out.
///
/// ## Why selection is always on
///
/// Every other grid in this app is a browser first: a tap opens the viewer, and selecting is a mode
/// you enter. Here a tap cannot open anything — ``PhotoDetailView`` draws a ``MediaItem``, an item
/// in the *account*, and these are not in the account yet; that is the point of the screen. So the
/// only thing a tap can usefully mean is "this one", and making the user press Select first would be
/// a tap paid on every visit for a mode there is no alternative to. The system photo picker makes
/// the same choice for the same reason.
///
/// ## What Upload actually does
///
/// Hands the selection to ``LibraryImportService/importSelected(_:)``, which puts it at the front of
/// the same resumable queue the full-library import drains. That is what makes this screen small: it
/// owns a grid and a selection, and every hard property — de-duplication, RAW originals, Live Photo
/// motion, surviving a force-quit, retries, Wi-Fi and storage and thermal conditions — belongs to the
/// queue and is inherited rather than reimplemented.
struct DeviceLibraryView: View {

    @EnvironmentObject private var browser: DeviceLibraryBrowser
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary
    @EnvironmentObject private var importer: LibraryImportService
    @EnvironmentObject private var ledger: ImportLedger
    @EnvironmentObject private var settings: AppSettings

    /// The picked items. ``TimelineSelection/begin()`` is deliberately never called: `isActive`
    /// tracks whether the *timeline* is in multi-select mode, and this grid has no mode to be in —
    /// see the note above. Everything else on the type works the same either way.
    @State private var selection = TimelineSelection()
    @State private var isRequestingAccess = false
    /// Set when Upload was refused before anything was queued — no key, no index, no permission.
    @State private var uploadProblem: String?

    /// The filtered listing, rebuilt only when one of its inputs actually changes. Deliberately not
    /// observed — see ``DeviceLibraryFilter``.
    @State private var filter = DeviceLibraryFilter()

    /// How many of the selected items are already in the account, for the line under the button.
    ///
    /// Carried alongside the selection rather than counted where it is drawn, for the same reason
    /// the filter is memoized: it is read from `body`, `body` runs on every tick of the upload
    /// progress bar, and counting it there is a pass over the selection — up to the whole camera
    /// roll after Select All — several times a second. Every mutation of ``selection`` goes through
    /// a method below that keeps this in step with it.
    @State private var selectedUploadedCount = 0

    /// The grid's width, which is what decides how many columns fit. Measured rather than assumed,
    /// so an iPad and a Split View pane get a grid built for them instead of a stretched phone.
    @State private var gridWidth: CGFloat = 0

    /// The gap between cells, and the only spacing in the grid — a device library is looked at as a
    /// wall of pictures, exactly as Apple Photos presents it.
    private static let spacing: CGFloat = 2

    /// About this wide, before the column count is rounded to fit. Matches the timeline's densest
    /// setting, which is the one this grid is read at.
    private static let preferredCellSide: CGFloat = 118

    // MARK: - Body

    var body: some View {
        // Reading the filter is the first thing body does, and refreshing it is a no-op on every
        // pass where nothing changed — which is nearly all of them, since an upload in progress
        // republishes its counts several times a second and redraws this view each time.
        filter.refresh(
            DeviceLibraryFilter.Inputs(revision: browser.revision,
                                       importedCount: ledger.count,
                                       hidesUploaded: settings.hidesUploadedDeviceItems),
            source: { browser.assets },
            isImported: { ledger.contains(localIdentifier: $0) }
        )

        return Group {
            if !deviceLibrary.access.isUsable {
                accessState
            } else if visibleAssets.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { uploadBar }
        .task {
            deviceLibrary.refresh()
            await browser.loadIfNeeded()
        }
        // The library changes underneath this screen — a photo taken in another app, a limited grant
        // widened, an item deleted — and a selection holding an identifier that has gone would
        // upload nothing under a count that says otherwise. Keyed on the revision rather than on the
        // listing: SwiftUI compares an `onChange` value on every view update, and this one updates
        // on every tick of the upload progress bar above it.
        .onChange(of: browser.revision) { _ in
            selection.prune(against: browser.assets)
            recountSelectedUploaded()
        }
        .alert("Can't Upload", isPresented: Binding(get: { uploadProblem != nil },
                                                    set: { if !$0 { uploadProblem = nil } })) {
            Button("OK") { uploadProblem = nil }
        } message: {
            Text(uploadProblem ?? "")
        }
    }

    // MARK: - Contents

    /// What the grid draws: everything, or only what is not yet in the account.
    private var visibleAssets: [ScannedAsset] { filter.visible }

    // MARK: - Grid

    private var columnCount: Int {
        guard gridWidth > 0 else { return 3 }
        let fitted = Int((gridWidth / Self.preferredCellSide).rounded())
        return max(3, fitted)
    }

    private var cellSide: CGFloat {
        guard gridWidth > 0 else { return Self.preferredCellSide }
        let gaps = Self.spacing * CGFloat(columnCount - 1)
        return max((gridWidth - gaps) / CGFloat(columnCount), 1)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing),
                                     count: columnCount),
                      spacing: Self.spacing) {
                ForEach(visibleAssets) { asset in
                    Button {
                        toggle(asset)
                    } label: {
                        DeviceAssetThumbnailView(
                            asset: asset,
                            side: cellSide,
                            isImported: ledger.contains(localIdentifier: asset.localIdentifier),
                            selectionState: selection.contains(asset.localIdentifier)
                                ? .selected : .unselected
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { gridWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { gridWidth = $0 }
            }
        )
        // Pulls the listing again by hand. The change observer covers everything Photos tells the
        // app about; this covers the case it does not — a permission widened in Settings while the
        // app was in the background.
        .refreshable {
            deviceLibrary.refresh()
            await browser.load()
        }
    }

    // MARK: - Toolbar

    private var navigationTitle: String {
        selection.isEmpty ? "On This iPhone" : "\(selection.count) Selected"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Menu {
                Toggle("Hide Already Uploaded", isOn: $settings.hidesUploadedDeviceItems)
                if deviceLibrary.access == .limited {
                    Divider()
                    Button {
                        deviceLibrary.presentLimitedPicker()
                    } label: {
                        Label("Select More Photos…", systemImage: "photo.badge.plus")
                    }
                }
            } label: {
                Label("View", systemImage: "line.3.horizontal.decrease.circle")
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            if selection.isEmpty {
                Button("Select All") { selectAll() }
                    .disabled(visibleAssets.isEmpty)
            } else {
                Button("Deselect All") { deselectAll() }
            }
        }
    }

    // MARK: - Selecting

    /// The three mutations, each keeping ``selectedUploadedCount`` in step.
    ///
    /// A tap adjusts it by one rather than recounting: after Select All over a large roll the
    /// selection is the whole library, and a pass over it per tap is a grid that stops responding to
    /// taps.
    private func toggle(_ asset: ScannedAsset) {
        let wasSelected = selection.contains(asset.localIdentifier)
        selection.toggle(asset.localIdentifier)
        guard ledger.contains(localIdentifier: asset.localIdentifier) else { return }
        selectedUploadedCount += wasSelected ? -1 : 1
    }

    private func selectAll() {
        selection.selectAll(in: visibleAssets)
        // Already counted while the listing was filtered — the selection *is* everything visible,
        // so there is nothing to count again.
        selectedUploadedCount = filter.visibleUploadedCount
    }

    private func deselectAll() {
        selection.deselectAll()
        selectedUploadedCount = 0
    }

    /// The one case that has to count: the listing changed underneath a selection, so an unknown
    /// subset of it has gone. Paid once per library change rather than once per frame.
    private func recountSelectedUploaded() {
        selectedUploadedCount = selection.ids.reduce(into: 0) { count, identifier in
            if ledger.contains(localIdentifier: identifier) { count += 1 }
        }
    }

    // MARK: - Upload

    /// The bar the whole screen exists for.
    ///
    /// Always present rather than appearing with the first selection: a bar that slides in under the
    /// thumb moves the grid at the moment somebody is tapping cells in it, and the disabled state is
    /// also the clearest statement of what this screen is for.
    @ViewBuilder
    private var uploadBar: some View {
        VStack(spacing: 6) {
            Button(action: upload) {
                Text(uploadTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)

            Text(uploadFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var uploadTitle: String {
        switch selection.count {
        case 0: return "Upload"
        case 1: return "Upload 1 Item"
        case let count: return "Upload \(count) Items"
        }
    }

    /// The one sentence that has to be true, and the caveat that most often is.
    private var uploadFooter: String {
        if selectedUploadedCount > 0 {
            return selectedUploadedCount == selection.count
                ? "Everything selected is already in your library — uploading again does nothing."
                : "\(selectedUploadedCount) of these are already in your library and will be skipped."
        }
        return "Encrypted on this iPhone before it leaves it. Your photos stay on the device."
    }

    private func upload() {
        let assets = browser.resolve(selection.ids)
        guard !assets.isEmpty else { return }
        Task {
            let queued = await importer.importSelected(assets)
            guard queued else {
                // The service records why on its phase; the alert is what makes a refused tap
                // legible, since the banner below the title bar is easy to miss mid-tap.
                if case .paused(let reason?) = importer.phase { uploadProblem = reason }
                return
            }
            // Cleared only on success. A refused upload leaves the selection exactly as it was, so
            // fixing the reason and tapping again does not mean picking forty pictures a second time.
            deselectAll()
        }
    }

    // MARK: - Banners

    /// The queue, as this screen shows it.
    ///
    /// The same phases ``LibraryView`` reports, worded for the place the items were picked: somebody
    /// who just tapped Upload is watching for *their* items, and "Importing 12 of 40" is what tells
    /// them the tap landed.
    @ViewBuilder
    private var banners: some View {
        switch importer.phase {
        case .running, .waiting, .scanning:
            VStack(alignment: .leading, spacing: 4) {
                Text("Uploading \(importer.counts.finished) of \(importer.counts.total)")
                    .font(.footnote.weight(.medium))
                ProgressView(value: importer.counts.fraction)
                if case .waiting(let reason) = importer.phase {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        case .paused(let reason?):
            banner(reason, systemImage: "exclamationmark.triangle", tint: .orange)
        case .interrupted:
            banner("An upload was interrupted — \(importer.counts.pending) item(s) left.",
                   systemImage: "arrow.clockwise", tint: .accentColor)
        case .idle, .finished, .paused:
            EmptyView()
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Access

    /// What the screen is when the app cannot see the library at all.
    ///
    /// Unlike everywhere else this permission appears, there is no degraded version to fall back on:
    /// the picker route needs no access precisely because it never shows the app the roll, and this
    /// screen *is* the roll. So this asks — once, on a button, having first said what it is for.
    @ViewBuilder
    private var accessState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.square.stacked")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Photo Access Needed")
                .font(.title3.weight(.semibold))
            Text(accessMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            switch deviceLibrary.access {
            case .notDetermined:
                Button("Allow Photo Access") {
                    isRequestingAccess = true
                    Task {
                        await deviceLibrary.requestAccess()
                        await browser.load()
                        isRequestingAccess = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRequestingAccess)
            case .denied:
                // No second Allow button: iOS shows the system alert once per install, and a button
                // that appeared to ask again would do nothing at all.
                Button("Open Settings") {
                    guard let url = DevicePhotoLibrary.settingsURL else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            case .restricted, .authorized, .limited:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessMessage: String {
        switch deviceLibrary.access {
        case .notDetermined:
            return """
                   To show the photos on this iPhone, Neutrino Photos needs to read your photo \
                   library. Nothing is uploaded until you select it and tap Upload.
                   """
        case .denied:
            return """
                   Neutrino Photos can't see your photo library, so this album is empty. You can \
                   still import through the photo picker from the Library tab.
                   """
        case .restricted:
            return """
                   Photo access is turned off by a Screen Time or device management restriction, \
                   which this app can't change. Importing through the picker still works.
                   """
        case .authorized, .limited:
            return ""
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: browser.isLoading ? "photo.stack" : "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if deviceLibrary.access == .limited {
                Button("Select More Photos…") { deviceLibrary.presentLimitedPicker() }
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if browser.isLoading { return "Reading your photo library…" }
        if settings.hidesUploadedDeviceItems && filter.uploadedCount > 0 {
            return "Every photo on this iPhone is already in your library."
        }
        if deviceLibrary.access == .limited {
            return "You've shared none of your photo library with Neutrino Photos yet."
        }
        return "There are no photos or videos on this iPhone."
    }
}
