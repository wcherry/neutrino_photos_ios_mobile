// MARK: - FeatureFlags

/// Compile-time switches for the feature set in `agent_docs/mvp.md`.
///
/// Two jobs. A flag that is `true` names something the app does and can be switched off in a build
/// without unpicking its wiring — how the sibling Neutrino apps shipped their epics. A flag that is
/// `false` names something the roadmap calls for and this app does *not* do yet, so the gap is
/// visible in one file rather than inferred from a missing tab.
enum FeatureFlags {

    // MARK: - Phase 0 / MVP — implemented

    /// Neutrino authentication: the OAuth PKCE login, token refresh, device registration.
    static let authentication: Bool = true

    /// End-to-end encryption: unlocking the account's key vault, importing a key pair by file,
    /// sealing a per-file key on upload, and unsealing it to open an original.
    static let encryption: Bool = true

    /// The photo timeline: the library grid grouped by day / month / year, pinched between those
    /// densities, travelled with the date scrubber, and selected from.
    ///
    /// Like ``mediaPipeline``, nothing branches on this one. The timeline is the Library tab rather
    /// than a feature inside it, and a `false` here would leave the tab with nothing to draw — so
    /// the flag records that Epic 4 is in this build rather than switching it off.
    static let timeline: Bool = true

    /// The full-screen viewer: progressive load up the rendition ladder, zoom to the original,
    /// pan, swipe between items, info panel.
    static let viewer: Bool = true

    /// Video playback in the viewer, from the decrypted original.
    static let videoPlayback: Bool = true

    /// Importing from the device's photo library, and the upload queue behind it.
    static let importFromPhotos: Bool = true

    /// Favorites — the photo record's `isStarred` flag, shared with the web app.
    static let favorites: Bool = true

    /// Archive: hiding an item from the main timeline without deleting it.
    static let archive: Bool = true

    /// Recently Deleted: trash, restore, empty.
    static let trash: Bool = true

    /// Albums: listing, creating, renaming, deleting, and adding or removing photographs.
    ///
    /// Opening an album is deliberately absent: the server has no endpoint that lists an album's
    /// contents — see ``Album`` — so this covers everything the API can currently do.
    static let albums: Bool = true

    /// The media pipeline: the rendition ladder, the encrypted preview stored beside each original,
    /// the size-capped caches of decrypted media on disk, and the SQLite library the timeline paints
    /// from before the network answers.
    ///
    /// Not a switch anything branches on — it is here because the epic that built it is a fact
    /// about this build that ``RoadmapView`` should be able to state. Turning it off would not
    /// remove a screen; it would remove the thing every screen reads through.
    static let mediaPipeline: Bool = true

    // MARK: - Not yet implemented

    /// Automatic background backup of new camera-roll items (`BGTaskScheduler`, upload queue,
    /// charging / Wi-Fi conditions). Import is manual until this lands.
    static let automaticBackup: Bool = false

    /// Offline browsing.
    ///
    /// Half of what this names now exists — see ``mediaPipeline``: the local database, the cached
    /// thumbnails, and the cached originals, so a cold launch with no signal draws the timeline it
    /// drew last time. What is still missing is the half that makes it *offline mode* rather than a
    /// cache: a delta sync on a cursor, a queue that holds favourites, deletes, and album edits made
    /// with no network and drains them in order, and a rule for what happens when two devices
    /// changed the same thing. That is Epic 10, and half of it would be worse than none.
    static let offlineMode: Bool = false

    /// Search by date, filename, and metadata.
    static let search: Bool = false

    /// Places and the photo map, from `GET /api/v1/photos/map`.
    static let places: Bool = false

    /// People: face detection, clustering, and naming, from `/api/v1/photos/persons`.
    static let people: Bool = false

    /// Memories and Year in Review, from `/api/v1/photos/memories`.
    static let memories: Bool = false

    /// Non-destructive editing, backed by `/api/v1/photos/{id}/edits`.
    static let editing: Bool = false

    /// Sharing photographs and albums with other Neutrino accounts.
    static let sharing: Bool = false

    /// Accepting inbound `https://www.getneutrino.app/open/photo/<id>` Universal Links. The
    /// `applinks:` entitlement is a bundle property rather than a runtime one, so iOS still hands
    /// the app such a URL; without a router to consume it, it is dropped.
    static let appLinks: Bool = false
}
