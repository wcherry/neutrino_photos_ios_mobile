import PhotosUI
import SwiftUI
import NeutrinoCrypto
import NeutrinoUI

// MARK: - LibraryView

/// The timeline: every photograph and video in the library, grouped by day, month, or year.
///
/// This view owns the chrome — the toolbar, the banners, the empty state, and multi-select — and
/// hands the scrolling grid to ``TimelineGridView``. The split is not tidiness: scroll geometry
/// re-renders whatever view reads it, and keeping that inside the grid means a flick through the
/// library does not also re-render the import progress bar and four toolbar items.
struct LibraryView: View {

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var settings: AppSettings
    /// Held for the bulk "Add to Album" action and handed on to its sheet.
    @EnvironmentObject private var albums: AlbumService
    @EnvironmentObject private var importer: PhotoImportService
    @EnvironmentObject private var libraryImporter: LibraryImportService
    @EnvironmentObject private var vault: KeyVaultService
    /// Held only to hand on to the viewer — see the `fullScreenCover` below.
    @EnvironmentObject private var thumbnails: ThumbnailCache
    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary
    /// Held only to hand on to the import sheet, which explains what it holds.
    @EnvironmentObject private var ledger: ImportLedger

    /// What the picker handed back. Cleared as soon as the import starts so picking the same
    /// photographs twice in a row still fires — an unchanged selection is not a changed binding.
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var viewerStart: MediaItem?
    @State private var hasLoaded = false
    @State private var showsUnlock = false
    @State private var showsLibraryImport = false

    /// The grouped timeline, rebuilt only when the library or the density actually changes.
    /// Deliberately not observed — see ``TimelineCache``.
    @State private var cache = TimelineCache()

    /// Where the grid is scrolled to. Held here so it survives a regroup, observed only by the
    /// scrubber — see ``TimelinePosition``.
    @State private var position = TimelinePosition()

    @State private var selection = TimelineSelection()
    @State private var showsBulkDeleteConfirmation = false
    /// The selection being filed into an album. Captured at the moment the sheet opens rather than
    /// read live, so a library refresh mid-sheet cannot change what is being added under it.
    @State private var addingToAlbum: AlbumTarget?

    /// A selection on its way into an album.
    ///
    /// A wrapper with an identity of its own because `sheet(item:)` needs `Identifiable` and an
    /// array is not — and because identifying the sheet by its *contents* would tear it down and
    /// rebuild it if the selection changed underneath, mid-add.
    private struct AlbumTarget: Identifiable {
        let id = UUID()
        let items: [MediaItem]
    }

    /// The grid's width, which is what decides how many columns fit. Measured rather than assumed
    /// so an iPad and a Split View pane get a grid built for them instead of a stretched phone.
    @State private var gridWidth: CGFloat = 0

    // MARK: - Body

    var body: some View {
        // Reading the cache is the first thing body does, and refreshing it is a no-op on every
        // pass where nothing changed. See ``TimelineCache`` for why this is safe from `body`.
        cache.refresh(
            TimelineCache.Inputs(revision: library.revision,
                                 grouping: settings.timelineGrouping,
                                 showsArchived: settings.showArchived)
        ) {
            library.timeline(showingArchived: settings.showArchived)
        }

        return Group {
            if cache.items.isEmpty && !library.isLoading {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
        // Pulling to refresh while picking items out of the grid is a gesture conflict with no
        // right answer, so selection mode simply does not offer it.
        .refreshable { if !selection.isActive { await library.load() } }
        .task {
            // Once per appearance rather than on every navigation: `refreshable` and the import
            // completion handler cover the cases where the library has actually changed.
            guard !hasLoaded else { return }
            hasLoaded = true
            await library.load()
        }
        .onChange(of: pickerSelection) { selection in
            guard !selection.isEmpty else { return }
            importer.startImport(selection)
            pickerSelection = []
        }
        // An item deleted here or on another device must not stay in the selection, or a bulk
        // action would address something the library no longer has.
        .onChange(of: library.allItems.count) { _ in
            guard selection.isActive else { return }
            // Against the library rather than against `cache.items`: the cache is refreshed by the
            // next body pass, which has not run yet, so its copy is the one *without* this change.
            selection.prune(against: library.timeline(showingArchived: settings.showArchived))
        }
        .fullScreenCover(item: $viewerStart) { start in
            // The viewer now reads the thumbnail cache too — it opens on the cover the grid already
            // drew — so it is handed on explicitly rather than left to whether a full-screen cover
            // inherits the presenting view's environment.
            PhotoDetailView(items: cache.items, initialID: start.id)
                .environmentObject(thumbnails)
                .environmentObject(deviceLibrary)
        }
        .sheet(isPresented: $showsUnlock) {
            VaultUnlockView()
                .environmentObject(vault)
        }
        .sheet(isPresented: $showsLibraryImport) {
            NavigationStack {
                // Handed on explicitly for the same reason the viewer's are: a modal's inheritance
                // of the presenting view's environment is not something to rest a crash on.
                LibraryImportView()
                    .environmentObject(libraryImporter)
                    .environmentObject(deviceLibrary)
                    .environmentObject(ledger)
                    .environmentObject(settings)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            // Dismiss rather than stop: an import keeps running with the sheet
                            // closed, which is the whole point of it being a queue.
                            Button("Done") { showsLibraryImport = false }
                        }
                    }
            }
        }
        .sheet(item: $addingToAlbum) { target in
            // Selection mode ends only on a *successful* add. Cancelling, or an add that partly
            // failed, leaves the selection exactly as it was so the user can retry it.
            AlbumPickerView(items: target.items) { selection.end() }
                .environmentObject(albums)
        }
        .confirmationDialog("Delete \(selection.count) item(s)?",
                            isPresented: $showsBulkDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelection() }
        } message: {
            Text("They move to Recently Deleted and can be restored for \(TrashRetention.days) days.")
        }
    }

    // MARK: - Timeline

    private var columns: Int {
        settings.timelineGrouping.columnCount(forWidth: gridWidth)
    }

    private var grid: some View {
        TimelineGridView(
            sections: cache.sections,
            grouping: settings.timelineGrouping,
            columns: columns,
            position: position,
            selection: $selection,
            onOpen: { viewerStart = $0 },
            contextMenu: { item in AnyView(contextMenu(for: item)) },
            onZoom: zoom,
            // Suppressed while picking: the footer sits under the last row, which is exactly where
            // a selection's action bar is, and a spinner arguing with it says nothing useful about
            // a set of photographs the reader has already chosen.
            fillProgress: selection.isActive ? nil : library.fillProgress
        )
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { gridWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { gridWidth = $0 }
            }
        )
    }

    /// Steps the timeline's density, keeping the date on screen.
    ///
    /// The anchor is captured by ``TimelinePosition`` as the grid scrolls, and applied by the grid
    /// once the new sections arrive; all this has to do is change the setting. At the ends of the
    /// ladder — pinching in on Days, out on Years — there is nowhere to go, and doing nothing is
    /// the honest response.
    private func zoom(_ direction: TimelineZoomDirection) {
        let next: TimelineGrouping?
        switch direction {
        case .in:  next = settings.timelineGrouping.zoomedIn
        case .out: next = settings.timelineGrouping.zoomedOut
        }
        guard let next else { return }
        settings.timelineGrouping = next
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for item: MediaItem) -> some View {
        if FeatureFlags.favorites {
            Button {
                library.setStarred(id: item.id, isStarred: !item.isStarred)
            } label: {
                Label(item.isStarred ? "Remove from Favorites" : "Favorite",
                      systemImage: item.isStarred ? "heart.slash" : "heart")
            }
        }
        if FeatureFlags.archive {
            Button {
                library.setArchived(id: item.id, isArchived: !item.isArchived)
            } label: {
                Label(item.isArchived ? "Unarchive" : "Archive",
                      systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
            }
        }
        Button {
            selection.begin(with: item.id)
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        if FeatureFlags.trash {
            Button(role: .destructive) {
                library.trash(id: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    private var navigationTitle: String {
        guard selection.isActive else { return "Library" }
        return selection.isEmpty ? "Select Items" : "\(selection.count) Selected"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if selection.isActive {
                Button(selection.coversAll(of: cache.items) ? "Deselect All" : "Select All") {
                    if selection.coversAll(of: cache.items) {
                        selection.deselectAll()
                    } else {
                        selection.selectAll(in: cache.items)
                    }
                }
            } else {
                Menu {
                    Picker("Group by", selection: $settings.timelineGrouping) {
                        ForEach(TimelineGrouping.allCases) { grouping in
                            Text(grouping.displayName).tag(grouping)
                        }
                    }
                    if FeatureFlags.archive {
                        Toggle("Show Archived", isOn: $settings.showArchived)
                    }
                    if !cache.items.isEmpty {
                        Divider()
                        Button {
                            selection.begin()
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    }
                } label: {
                    Label("View", systemImage: "square.grid.2x2")
                }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            if selection.isActive {
                Button("Done") { selection.end() }
                    .fontWeight(.semibold)
            } else if FeatureFlags.importFromPhotos {
                importControl
            }
        }
    }

    /// The picker on its own, or a menu offering the picker and the whole library.
    ///
    /// A menu only when there is a second thing in it. One item behind a chevron is a tap somebody
    /// pays on every import for a choice they do not have.
    @ViewBuilder
    private var importControl: some View {
        if FeatureFlags.fullLibraryImport && FeatureFlags.deviceLibraryAccess {
            Menu {
                PhotosPicker(selection: $pickerSelection,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    Label("Select Photos…", systemImage: "photo.on.rectangle")
                }
                Button {
                    showsLibraryImport = true
                } label: {
                    Label("Import Entire Library…", systemImage: "square.stack.3d.up")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.up")
            }
            .disabled(importer.isImporting)
        } else {
            PhotosPicker(selection: $pickerSelection,
                         matching: .any(of: [.images, .videos]),
                         photoLibrary: .shared()) {
                Label("Import", systemImage: "square.and.arrow.up")
            }
            .disabled(importer.isImporting)
        }
    }

    // MARK: - Selection bar

    /// The actions that apply to a selection.
    ///
    /// Favourite, add to album, archive, delete. The three that go through ``PhotoLibraryService``
    /// are the same call the context menu makes, run in a loop; "Add to Album" is the one that
    /// needs a destination, so it opens the picker rather than acting immediately.
    @ViewBuilder
    private var selectionBar: some View {
        if selection.isActive {
            HStack(spacing: 0) {
                if FeatureFlags.favorites {
                    action("Favorite", systemImage: allSelectedAreStarred ? "heart.fill" : "heart",
                           perform: toggleStarOnSelection)
                }
                if FeatureFlags.albums {
                    action("Add To", systemImage: "rectangle.stack.badge.plus") {
                        addingToAlbum = AlbumTarget(items: selectedItems)
                    }
                }
                if FeatureFlags.archive {
                    action("Archive",
                           systemImage: allSelectedAreArchived ? "tray.and.arrow.up" : "archivebox",
                           perform: toggleArchiveOnSelection)
                }
                if FeatureFlags.trash {
                    action("Delete", systemImage: "trash", role: .destructive) {
                        showsBulkDeleteConfirmation = true
                    }
                }
            }
            .disabled(selection.isEmpty)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func action(_ title: String, systemImage: String,
                        role: ButtonRole? = nil, perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Bulk actions

    private var selectedItems: [MediaItem] { selection.resolve(in: cache.items) }

    /// Toggling a mixed selection favourites all of it rather than inverting each item — inverting
    /// leaves the user with the same mixture they started from, which is never what they meant.
    private var allSelectedAreStarred: Bool {
        let items = selectedItems
        return !items.isEmpty && items.allSatisfy(\.isStarred)
    }

    private var allSelectedAreArchived: Bool {
        let items = selectedItems
        return !items.isEmpty && items.allSatisfy(\.isArchived)
    }

    private func toggleStarOnSelection() {
        let starred = !allSelectedAreStarred
        for item in selectedItems where item.isStarred != starred {
            library.setStarred(id: item.id, isStarred: starred)
        }
    }

    private func toggleArchiveOnSelection() {
        let archived = !allSelectedAreArchived
        for item in selectedItems where item.isArchived != archived {
            library.setArchived(id: item.id, isArchived: archived)
        }
    }

    private func deleteSelection() {
        for item in selectedItems {
            library.trash(id: item.id)
        }
        // Nothing is left selected once the items are out of the timeline, so staying in the mode
        // would just be an empty toolbar.
        selection.end()
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if importer.isImporting {
                importProgress
            }
            libraryImportBanner
            if let reason = importer.blockedReason {
                banner(reason, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if !importer.failures.isEmpty {
                banner("\(importer.failures.count) item(s) failed to upload.",
                       systemImage: "exclamationmark.circle", tint: .red)
            }
            lockedBanner
            if let error = library.error {
                // Tappable, which the plain banner was not. A refresh that failed leaves the only
                // way back a pull on the grid — and the grid is empty in exactly the case the
                // failure matters most, on a first launch that has nothing cached to pull on.
                Button {
                    Task { await library.load() }
                } label: {
                    banner(error, systemImage: "wifi.exclamationmark", tint: .red,
                           accessory: library.isLoading ? .progress : .retry)
                }
                .buttonStyle(.plain)
                .disabled(library.isLoading)
                .accessibilityHint("Tap to try loading your library again.")
            }
        }
    }

    /// The locked state, as the timeline shows it.
    ///
    /// A banner rather than a wall: the grid below is drawn from plaintext cover thumbnails stored
    /// beside each Drive file, so the library is genuinely browsable without a key. What is missing
    /// is originals and uploads, and this says which of the two routes back applies — unlocking a
    /// vault, or importing a key file for an account that has none.
    @ViewBuilder
    private var lockedBanner: some View {
        if !KeyImportService.hasStoredKeys() {
            switch vault.status {
            case .noVault:
                NavigationLink {
                    KeyImportView()
                } label: {
                    banner("Import your encryption key to open and upload photos.",
                           systemImage: "key", tint: .accentColor)
                }
                .buttonStyle(.plain)
            case .locked, .unknown, .unreachable, .unlocked:
                Button {
                    showsUnlock = true
                } label: {
                    banner("Unlock your encryption key to open and upload photos.",
                           systemImage: "lock", tint: .accentColor)
                }
                .buttonStyle(.plain)
            }
        } else if vault.keyBelongsToAnotherAccount {
            Button {
                showsUnlock = true
            } label: {
                banner("The key on this device belongs to a different account. Unlock to replace it.",
                       systemImage: "exclamationmark.triangle", tint: .orange)
            }
            .buttonStyle(.plain)
        }
    }

    /// The full-library run, as the timeline shows it.
    ///
    /// Its own banner rather than a line in the picker's: the two are different runs with different
    /// lifetimes, and the one that matters here is the one that can still be going after a
    /// relaunch. An interrupted queue is the important case — a user who force-quit the app
    /// mid-import has no other way to find out that two thousand photographs are still waiting.
    @ViewBuilder
    private var libraryImportBanner: some View {
        if FeatureFlags.fullLibraryImport {
            switch libraryImporter.phase {
            case .running, .waiting, .scanning:
                Button {
                    showsLibraryImport = true
                } label: {
                    libraryImportProgress
                }
                .buttonStyle(.plain)
            case .interrupted:
                Button {
                    showsLibraryImport = true
                } label: {
                    banner("Import interrupted — \(libraryImporter.counts.pending) item(s) left. Tap to resume.",
                           systemImage: "arrow.clockwise", tint: .accentColor)
                }
                .buttonStyle(.plain)
            case .paused(let reason?):
                Button {
                    showsLibraryImport = true
                } label: {
                    banner(reason, systemImage: "exclamationmark.triangle", tint: .orange)
                }
                .buttonStyle(.plain)
            case .idle, .finished, .paused:
                EmptyView()
            }
        }
    }

    private var libraryImportProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(libraryImportTitle)
                    .font(.footnote.weight(.medium))
                Spacer()
                if case .running = libraryImporter.phase,
                   let remaining = ImportRate.formatted(remaining: libraryImporter.estimatedTimeRemaining) {
                    Text("about \(remaining) left")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: libraryImporter.counts.fraction)
            if case .waiting(let reason) = libraryImporter.phase {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .foregroundStyle(.primary)
    }

    private var libraryImportTitle: String {
        if case .scanning(let found) = libraryImporter.phase {
            return found == 0 ? "Scanning your library…" : "Scanning… \(found) found"
        }
        return "Importing \(libraryImporter.counts.finished) of \(libraryImporter.counts.total)"
    }

    private var importProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Uploading \(importer.completed + 1) of \(importer.total)")
                    .font(.footnote.weight(.medium))
                Spacer()
                Button("Cancel") { importer.cancel() }
                    .font(.footnote)
            }
            // Two bars would be noise; the item's own byte progress is the one that moves, and the
            // count above says where the run is.
            ProgressView(value: importer.currentFraction)
            if let name = importer.currentName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// What a banner shows at its trailing edge, where it has something to offer.
    private enum BannerAccessory {
        case none, retry, progress
    }

    private func banner(_ text: String, systemImage: String, tint: Color,
                        accessory: BannerAccessory = .none) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                // Two lines: the transport failures now say which one happened, and several of
                // those sentences do not fit a phone's width in one.
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer()
            switch accessory {
            case .none:
                EmptyView()
            case .retry:
                Image(systemName: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            case .progress:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Photos Yet")
                .font(.title3.weight(.semibold))
            Text("Import from your photo library and everything is encrypted on this device before it leaves it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if FeatureFlags.importFromPhotos {
                PhotosPicker(selection: $pickerSelection,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    Text("Import Photos")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
