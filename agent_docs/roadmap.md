# Neutrino Photos — Delivery Roadmap

Breaks [mvp.md](mvp.md) into buildable epics. Scope here is **v1.0 (the "Must Have" list,
mvp.md §19)**; everything after it is mapped at the end but not detailed.

---

## How to read this document

**Epics are numbered once and never renumbered.** Epic 7 stays Epic 7 after it ships, so
commit messages, feature flags, and code comments can point at it. Gaps in the numbering
are fine.

**Every user-visible epic lands behind a flag** in `NeutrinoPhotos/Config/FeatureFlags.swift`,
matching the Notes app convention:

```swift
/// Set to true to enable the Epic 9 Organization feature (albums, favorites, and the
/// Recently Deleted view). When false, the Albums tab shows its placeholder and no
/// album/favorite actions appear.
static let organization: Bool = false
```

The flag is flipped to `true` in the same PR that completes the epic's manual verification —
not before. A half-built epic on `main` behind a `false` flag is expected and fine.

**An epic is done when its manual verification passes on a physical device**, not just the
simulator. Background upload, Photos-library scale, thermal/battery behaviour, and Keychain
biometrics all lie on the simulator. Unit tests are necessary but never sufficient here.

**Commands used throughout the verification steps:**

| | |
|---|---|
| `scripts/run_simulator.sh` | build + launch on iPhone 17 Pro simulator |
| `scripts/run_simulator.sh --reset` | wipe app data first — a cold-install run |
| `scripts/run_simulator.sh --console` | stream `os.log` output |
| `scripts/run_simulator.sh --physical --console` | same, on the paired device |
| `scripts/deploy_testflight.sh` | ship a build |

**"Test library"** below means a device photo library seeded with a known mix: ~2,000 items
including at least 20 videos, 10 Live Photos, 5 RAW/DNG, 5 bursts, 5 panoramas, 3 screen
recordings, 100 screenshots, and 50 items with no GPS data. Build it once, snapshot the
device, and reuse it — several epics depend on knowing the exact expected counts.

---

## Milestones

| # | Milestone | Epics | Proves |
|---|---|---|---|
| **M0** | Foundation | 0, 1 | App authenticates against Neutrino and reaches Drive. |
| **M1** | Encrypted round trip | 2, 3 | One photo uploads encrypted and comes back decrypted — end to end. |
| **M2** | It's a photo app | 4, 5 | User picks photos, sees a real timeline, opens the viewer. |
| **M3** | It's a backup app | 6, 7, 8 | Full library imports and backs itself up in the background, videos included. |
| **M4** | It's reliable | 9, 10 | Albums/favorites/trash, multi-device sync, works on a plane. |
| **M5** | It's findable | 11, 12 | Search, metadata, storage management. |
| **M6** | **v1.0 ship** | 13, 14 | Sharing works, TestFlight beta passes, App Store submission. |

Each milestone is a demoable build. Don't start the next milestone's epics until the current
milestone's verification passes on device — the failure modes compound otherwise (an unreliable
upload queue makes every later epic's bugs unreproducible).

---

# M0 — Foundation

## Epic 0 — Architecture & Data Model

**Goal:** Decide the shapes everything else is built on. This epic is mostly documents and
type definitions; it exists so Epics 1–13 don't each invent their own answer.

Covers mvp.md §18 Phase 0.

**Deliverables**

- [ ] `agent_docs/architecture.md` — the decisions below, written down with rationale
- [x] Photo data model: `PhotoItem`, `PhotoAsset` (original/derived), `Album`, `PhotoMetadata`
      — shipped as `MediaItem` / `MediaMetadata` + `MediaExif` / `Album`, decoded against the live
      API and covered by `ModelTests`. There is deliberately no `PhotoAsset` type: the original *is*
      the Drive file (`MediaItem.fileID`) and the only derived artefact is the cover thumbnail
      carried on the record.
- [x] Drive mapping: how a photo is represented as a Drive object (MIME type, folder layout,
      the `type=photo` listing filter, where derived renditions live)
      — decided and implemented; see the doc comments on `MediaContentService.upload` (root folder,
      no `folder_id`, two-step upload-then-register) and the README's "The library is Photos, the
      bytes are Drive".
- [x] Local database choice and schema (SQLite via GRDB, or Core Data — decide and justify;
      the deciding factor is 100k-row timeline query performance, not familiarity)
      — decided in Epic 3 and implemented as `LocalStore`: **SQLite directly, via the SDK's own
      `SQLite3` module**. All three candidates are SQLite and answer the timeline query identically;
      what differs is what else they bring. Core Data adds an object graph, faulting, and the
      migration story most likely to lose somebody's data; GRDB is a third-party dependency for four
      tables and eleven statements. The rule that keeps the choice honest is written on the type: no
      query builder, no object mapping, no lazy loading — if this file ever wants those, it wants
      GRDB. The timeline query is answered by `photo(is_trashed, is_archived, timeline_date DESC)`
      with no sort step, and `LocalStoreTests` asserts a 2,000-row write and read.
- [ ] Sync protocol: cursor/delta shape, conflict rule, tombstones
- [x] Thumbnail/rendition ladder: which sizes, generated where, cached where, evicted how
      — `MediaRendition` is the ladder and the table in its doc comment is the answer: 512 px
      plaintext thumbnail on the Drive file for the grid, 2048 px **encrypted** preview as a second
      Drive file for the viewer, original for zoom and export. Generated on the uploading device,
      because the server holds ciphertext and has no key. Cached in `DiskCache` — capped, evicted
      least-recently-used, `Library/Caches`, excluded from backup, file protection matching the
      Keychain's. Every step falls back to the one below it, so nothing in the ladder is
      load-bearing.
- [ ] Background task architecture: `BGProcessingTask` vs `URLSession` background config,
      and which one owns the upload queue
- [ ] Error/retry policy: which errors are retryable, backoff curve, poison-item handling
- [x] Key management: master key → per-file DEK derivation, matching the web app's
      `crypto_box_seal` + XChaCha20-Poly1305 secretstream (see `project.yml` notes)
      — implemented in `MediaCrypto` (the primitives), `MediaContentService` (`sealDEK` / `unsealDEK`,
      which is the part that needs the Keychain), and `KeyImportService`, and asserted against real
      crypto rather than a mock. Note the DEK is *generated* per file and sealed to the account's
      Curve25519 identity key, not derived from a master key — that is what the web app does and the
      two must agree. Epic 2 added the layer above it: the master key is what wraps the *identity*,
      and `KeyVaultCrypto` is where that envelope lives.

**Status (updated 2026-08-18, after Epic 3):** five of nine deliverables are done. The first three
were the ones the app was *forced* to decide in order to ship the timeline; the local database and
the rendition ladder were forced by Epic 3, and like the others they exist as working code rather
than as prose — `LocalStore` and `MediaRendition`, both with their rationale on the type.

Four remain, and they are the four an implementation can defer until the epic that needs them:
the sync cursor and conflict rule (Epic 10), the background task architecture (Epic 7), and the
error/retry policy (Epic 7). `FeatureFlags.offlineMode` and `FeatureFlags.automaticBackup` are
`false` for exactly that reason.

**Two of those four are less open than they look.** The background task architecture and the
backoff curve are both answered in the Neutrino Drive app — `BackgroundTransferService` and
`PhotoSyncService`, described in its `agent_docs/plans/feature-photo-auto-sync.md` — against a
real device rather than on paper. Epic 7 ports them; `architecture.md` should record the decision
by reference rather than re-deriving it. What Drive does *not* answer is how a **multi-step**
import (upload → register → renditions → metadata) resumes at a step boundary after a suspension,
since Drive's upload is a single POST. That one is genuinely this app's to decide.

**Amended after Epic 6.** Half of the error/retry policy now exists as working code rather than as
prose, and the half that exists is the poison-item half: `LibraryImportService` retries a failed
item up to `maximumAttempts` across *passes* over the queue rather than in place, so one item can
never stall the rest, and after that it waits in a failed list with its message. There is still no
backoff *curve* — the network hold is a fixed poll, not exponential — and nothing outside the import
queue retries at all. Epic 7 is what generalises it.

`architecture.md` has not been written. What belongs in it now lives in `README.md` and in the doc
comments on `MediaContentService`, `MediaRendition`, `LocalStore`, and `DiskCache` — that covers
the five decided items but not the four deferred ones, and it is not a substitute for the document
the exit criteria name.

**Exit criteria:** A reviewer can read `architecture.md` and correctly predict what Epic 3 and
Epic 10 will look like without asking a question.

**Manual verification**

1. Walk the document against the [Neutrino Drive web app](../neutrino/web/apps/web/src/app/\(apps\)/drive/)
   upload path. Confirm the crypto described here produces a file the web app can open.
2. Sanity-check the storage math out loud: 50,000 photos × (original + 3 renditions + thumbnail).
   Confirm the local cache budget and eviction rule survive that number.
3. Confirm the sync section answers: two devices edit the same album offline — what happens?
   If the document doesn't answer it, the epic isn't done.

---

## Epic 1 — Authentication & App Shell

**Goal:** SwiftUI shell, Neutrino sign-in, session persistence.

Reuses `AccessToken.swift`, `KeychainService.swift`, `DeviceIdentity.swift` (already present)
and ports `AuthService.swift` from the Notes app.

**Deliverables**

- [x] `NeutrinoPhotosApp.swift` + tab shell: Library · Albums · Search · Settings
      — the composition root builds every service once and injects it; `ContentView` holds the four
      tabs, each with its own `NavigationStack`. The shell's shape is fixed rather than flag-dependent,
      so tabs don't move under the user's thumb between builds.
- [x] `AuthService` — sign in, sign out, token refresh, `GET /api/v1/auth/me`
      — the three-step OAuth PKCE flow (session login → authorize with the redirect suppressed →
      token exchange), refresh-if-expiring on every authorized request, and `loadProfile()` for
      `/auth/me`. A 401 from `/me` signs out (revoked, not stale); a 5xx or an offline phone does not.
- [x] Sign-in screen; signed-out state for every tab
      — `RootView` gates the whole shell: signed out is `LoginView`, not four tabs each explaining
      themselves. Cold install therefore opens on sign-in, which is what verification step 1 asks for.
- [x] Token persisted in Keychain; survives app termination
      — `KeychainService`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, under `nphoto.*` keys
      so Drive/Docs/Notes on the same device don't collide. `AuthService.init` reads it back.
- [x] Device registered via `DeviceIdentity`
      — there is no registration endpoint: a device names itself in `X-Device-Name` on login, which
      is what `GET /api/v1/auth/sessions` later lists. Asserted in `AuthServiceTests`.
- [x] Placeholder views for each tab, so the shell is navigable end to end
      — `TabPlaceholderView`, used by `SearchView` and by the Albums tab when `FeatureFlags.albums`
      is off. Library and Settings are real.
- [x] `FeatureFlags.swift` created

**Flag:** none — this is the floor.

**Status (2026-08-18):** all seven deliverables are implemented and the unit suite passes. Verification
step 1 has been run (`--reset` → the app opens on sign-in, screenshot confirmed). Steps 2–7 need a real
Neutrino account and, for step 7, the paired device — they have not been run, so **M0 is not closed**.

**Manual verification**

1. `scripts/run_simulator.sh --reset` → app opens on the sign-in screen, not a blank tab bar.
2. Sign in with a real Neutrino account → lands on Library, tab bar shows four tabs.
3. Force-quit and relaunch → still signed in, no sign-in flash.
4. Wrong password → a readable error, not a spinner that never stops.
5. Airplane mode → sign-in fails with "check your connection", not a crash or an infinite spinner.
6. Settings → Sign out → returns to sign-in; relaunch confirms the session is gone.
7. Repeat 2–3 on a physical device (`--physical`) — Keychain accessibility differs from the simulator.

**Milestone M0 complete** when Epic 1 verification passes on device.

---

# M1 — Encrypted Round Trip

## Epic 2 — Encryption & Key Management

**Goal:** The app holds keys, and everything written to the cloud is encrypted client-side.

Ports `KeyVaultService`, `KeyVaultCrypto`, `KeyImportService` (and optionally
`KeyQRDecryptService`) from the Notes app.

Covers mvp.md §4 Encryption, §19 items 2.

**Deliverables**

- [x] Vault unlock: password (Argon2id) and passkey/PRF, matching the Notes implementation
      — `KeyVaultCrypto` + `KeyVaultService`. Password and recovery code are done and asserted against
      a vault the *web* client produced (`WebVault` in `TestSupport`), not against a round trip through
      this app — a self-consistent round trip passes just as happily when both halves are wrong
      together. Passkey/PRF goes further than the Notes port, which skips it: `PasskeyPRFAuthenticator`
      performs an `ASAuthorization` PRF assertion on iOS 18+ and the unlock screen hides the option
      below that. See the caveat under Status.
- [x] Master key in Keychain, `kSecAttrAccessibleAfterFirstUnlock` — background upload needs it
      — with one deliberate deviation: what is persisted is the *identity key* MK protects, not MK
      itself, which exists only for the moment it takes to unwrap. Keeping MK would buy exactly one
      thing this app does not do — enrolling a new unlock method — for a second long-lived secret on
      the device. The accessibility class is `…AfterFirstUnlockThisDeviceOnly`, and
      `KeychainAccessibilityTests` asserts it on every key entry rather than trusting the write sites.
- [x] Per-file DEK generation and sealing to the account identity key
      — moved out of `MediaContentService` into `MediaCrypto`, which has no actor and no networking.
      What stays behind is the only part that needs the Keychain: which key pair a DEK is sealed to.
- [x] Encrypt/decrypt helpers: streaming for large originals, one-shot for metadata/thumbnails
      — `MediaCrypto.encryptStream` / `decryptStream` hold one chunk at a time regardless of file
      size; the one-shot pair stays for metadata, thumbnails, and ordinary photographs. A file that
      fits in one chunk comes out byte-identical to the single-push format, which is what keeps web
      interop. Read the note on `MediaCrypto` before using the chunked writer — the framing is not
      inferable and has to travel in the file's encrypted metadata.
- [x] Key import via `.json` key file (the `com.neutrino.photos.keyfile` UTI is already declared)
      — the UTI was declared but nothing consumed the URL, so tapping a key file did nothing.
      `KeyFileRouter` + `onOpenURL` closes that; the in-app file picker and paste box stay.
- [x] Device key registration and listing
      — `DeviceSessionService` over `GET/DELETE /api/v1/auth/sessions`, surfaced as Settings › Devices.
      Registration is a property of signing in rather than a call of its own (a device names itself in
      `X-Device-Name`), so "registered" is honestly labelled as when that device signed in.
- [x] Locked state: what the UI shows when signed in but vault-locked
      — a prompt, not a wall. `RootView` offers the unlock sheet once per launch when the account has
      a vault this device cannot open; dismissing it leaves a banner on the library, an Unlock button
      on any original that fails to open, and a reworded refusal from the importer. The timeline keeps
      browsing throughout, because the grid draws plaintext cover thumbnails and always could.

**Flag:** none — nothing writes to the cloud before this exists.

**Status (2026-08-18):** all seven deliverables are implemented; 149 unit tests pass. Two things are
**not** verified and cannot be from inside this repository:

- **Passkey unlock needs a server-side file.** A passkey enrolled on the web is bound to
  `www.getneutrino.app` as its relying party, and iOS hands this app such a credential only once that
  domain's `apple-app-site-association` names the app under a `webcredentials` section.
  `static/apple-app-site-association` in the `neutrino` repository currently has an `applinks` section
  only, and does not list `com.neutrino.photos` at all. The entitlement is in place here; until the
  AASA catches up, an assertion fails with a domain error and the screen falls back to the password —
  which is why the passkey button is never the only option offered.
- **Manual verification steps 1–7 have not been run.** They need a real Neutrino account with a vault,
  and step 6 needs a physical device. The unit suite covers the crypto and the state machine; it says
  nothing about what `AfterFirstUnlock` does on real hardware after a reboot.

**Manual verification**

1. Fresh install, sign in with an account that already has a vault → prompted to unlock, not
   silently signed in with no keys.
2. Unlock with the correct password → Library loads. Wrong password → clear error, retry allowed.
3. Force-quit, relaunch → vault still unlocked (key survived in Keychain).
4. Import a key file: AirDrop/Files a `.json` key file to the device, tap it → Neutrino Photos
   offers to import, import succeeds.
5. **Cross-app check:** unlock the same account in the Notes app. Same master key, no re-import.
6. Reboot the device, launch the app *before* unlocking the phone (via a notification tap if
   possible) → confirm the `AfterFirstUnlock` behaviour is what you actually wanted.
7. Settings → Devices → this device appears, with its registration date.

---

## Epic 3 — Media Pipeline & Cloud Storage

**Goal:** One photo goes up encrypted, comes back down decrypted, byte-identical.

Covers mvp.md §4 Storage, §19 items 14.

**Deliverables**

- [x] `PhotosDriveService` — Drive CRUD scoped to `type=photo`, modelled on `NotesDriveService`
      — the root listing (`/drive/folders/{userID}?type=photo`, where the root folder's id is the
      caller's own user id), one file's record, rename, delete, the account quota, and the
      renditions folder. It sits beside `PhotoLibraryService` rather than under it because the two
      answer questions neither can answer for the other: the Photos API lists *photo records* and
      knows nothing about bytes, the Drive listing lists *files* and includes images nothing ever
      registered as a photograph. `unregisteredPhotoFiles(knownFileIDs:)` is the reconciliation, and
      it is what Epic 6 will build "don't upload it twice" on.
- [x] Rendition generator: thumbnail (grid), preview (viewer), original (export)
      — `MediaRendition` names the three and `RenditionGenerator` makes them, entirely through
      ImageIO: decoding a 12-megapixel photograph with `UIImage(data:)` to draw it 500 px wide holds
      48 MB of bitmap to throw 47 of them away. A preview is only made when it would actually be
      smaller than what it is a preview of — a screenshot or a web graphic gets none, and the same
      rule governs both the upload side and the local fallback so a picture cannot be served as a
      rendition on one device and as an original on another.
- [x] Encrypted upload of original + renditions, streaming, memory-bounded
      — two paths. A photograph goes up as it always did (one-shot secretstream, the format the web
      client reads) and its 2048 px preview follows it into a `Photo Previews` subfolder, encrypted
      under its own DEK. A subfolder because both library listings are root-scoped, so a rendition
      filed there is invisible to them — which is the point. The second path takes a *file*:
      `MediaCrypto.encryptStream` writes the ciphertext a chunk at a time, `MultipartFormBody.write`
      copies it into the body through a fixed buffer, and `URLSession` streams that off disk. Peak
      memory is a couple of megabytes whether the video is 30 seconds or 20 minutes, and
      `PhotoImportService` now loads a video as a URL rather than as `Data` so the picker's half of
      it is bounded too. A rendition upload that fails is logged and swallowed: the original is safe
      by then, and refusing an import over a *preview* would trade the thing that matters for the
      thing that does not.
- [x] Encrypted download with local cache
      — decrypted originals land in a capped `DiskCache`, so opening a photograph twice downloads it
      once and a video plays from a file rather than from `Data`. Above 32 MB the download spools to
      disk and decrypts there, reading the chunk framing out of the file's encrypted metadata first,
      because a chunked stream and a single push are indistinguishable from their bytes and guessing
      wrong fails authentication rather than reading short.
- [x] `ThumbnailCache` — disk-backed, size-capped, LRU eviction
      — two tiers over one `DiskCache`: an `NSCache` of decoded bitmaps that empties itself under
      memory pressure, and 64 MB of JPEGs on disk that survives a relaunch. What it saves is not a
      download (a cover thumbnail arrives inside the listing) but the decode, which is what a grid
      pays for on every scroll pass.
- [x] Local database from Epic 0, with the schema live and migrated
      — `LocalStore`, and *live* rather than written-and-never-read: `PhotoLibraryService` paints the
      timeline from it before the network is asked anything, and writes back after every listing and
      every mutation. Migrations run off `user_version` and are append-only. It also holds the
      rendition index, which has nowhere else to live — nothing on a photo record can point at a
      rendition.

**Flag:** `mediaPipeline` — true, and nothing branches on it. The epic is infrastructure every
screen reads through rather than a screen of its own, so a `false` would not hide a feature, it
would remove the floor. It is in `FeatureFlags` so `Settings › What's not here yet` can state it.

**Exit criteria:** SHA-256 of a downloaded original equals the SHA-256 of what was uploaded.
✅ `MediaContentServiceTests.testAnUploadedOriginalComesBackByteIdentical` — through both real
paths, not a round trip of the crypto on its own: the bytes go out through the multipart upload,
are pulled back out of the captured request body exactly as the server would have stored them, are
served back through the download path, and are hashed at the far end.

**Status (2026-08-18):** all six deliverables are implemented; 219 unit tests pass. What that suite
covers and what it cannot:

- **Covered, and worth knowing it is:** the exit criterion above; the streaming upload writing a
  chunked stream *and saying so in its encrypted metadata* (a chunked file whose metadata forgot
  `chunkSize` is one nothing can ever read back); the streaming download reading that framing back
  and reproducing the file byte for byte; the cache serving a second read with no request at all;
  LRU eviction dropping the least recently *used* rather than the oldest written; and a rendition
  upload failing without taking the import with it.
- **Not covered, and not coverable here:** manual verification steps 2–7 have not been run. Step 3
  is the one that matters most — a photograph uploaded by this app opening in **Neutrino Drive web**
  — because a self-consistent round trip passes just as happily when both halves are wrong together.
  Step 6 (memory flat in Instruments during a 4K video upload) is asserted structurally by the tests
  and by construction, but "no allocation proportional to file size" is a claim only Instruments on
  a device can settle. Step 5's export has no UI yet — saving an original back out is Epic 5's
  save-to-device — so it is the unit-test harness that step 1 explicitly allows.
- **One deliberate deviation to note:** the preview rendition is a second Drive file in a
  `Photo Previews` folder, which today's web client neither writes nor reads. It ignores it — the
  folder is outside the root-scoped listing the web library uses — but a user browsing Drive will
  see the folder. Deleting it costs them nothing: every rendition is re-derivable from its original,
  and every read falls back.

**Manual verification**

1. Debug screen (or a unit-test harness): upload one 12MP JPEG. Note the item id.
2. `--console` → confirm the log shows encrypt → upload → renditions, with no plaintext bytes
   in any request body.
3. Open the file in **Neutrino Drive web** → it decrypts and displays. This is the
   interoperability check; if it fails, the crypto is wrong regardless of what the app shows.
4. Delete local cache (Settings → Clear cache), re-open the photo → re-downloads and displays.
5. Export the original, compute its SHA-256, compare to the source file's. Must match exactly.
6. Upload a 4K 3-minute video → memory stays flat in Instruments (streaming, not buffered).
   Watch for a jump proportional to file size; that's the bug this step exists to catch.
7. Upload with airplane mode toggled mid-transfer → fails cleanly, retryable, no half-written
   item in the database.

**Milestone M1 complete** when a photo round-trips and opens in the web app.

---

# M2 — It's a Photo App

## Epic 4 — Timeline & Viewer

**Goal:** The core browsing experience.

Covers mvp.md §2 Timeline (MVP subset), §19 items 7, 8.

**Deliverables**

- [x] Chronological grid, newest first, grouped by day with sticky date headers
      — `TimelineGridView`, a `LazyVStack` of pinned `Section` headers over a `LazyVGrid`. Ordering
      goes through `MediaItem.timelineDate` — capture date, falling back to upload date — so a
      photograph cannot sit under one date in the grid and another in its heading.
- [x] Month and year grouping levels; pinch-to-zoom between densities
      — the three levels already existed as a menu; the pinch is new, and so is the part that makes
      it usable. A `MagnificationGesture` attached *simultaneously* with the scroll (a pinch is two
      fingers, a scroll one) steps `TimelineGrouping.zoomedIn` / `zoomedOut`, latched so one gesture
      moves one step. The step fires mid-gesture rather than on release, because a density change
      that waits for the fingers to lift reads as not having taken.
      **Anchoring** is the half that matters: `TimelinePosition` notes the date at the top of the
      screen as the grid scrolls, and `TimelineSection.index(containing:in:)` finds where that date
      landed among the *new* sections. Without it every pinch returns to the top of the library,
      which is exactly what verification step 2 is looking for.
- [x] Fast scroll with a date scrubber
      — `TimelineScrubber` (the arithmetic) and `TimelineScrubberView` (the control). The thumb
      follows an ordinary scroll as well as leading one, so it doubles as a position indicator, and
      fades out when the timeline settles. Sections are weighted by the rows they actually draw
      rather than split evenly: an even split gives a 400-picture weekend and the Tuesday either
      side of it a third of the track each, so the thumb crawls through thirty screens and then
      leaps a year in a millimetre.
- [x] Full-screen viewer: pinch/double-tap zoom, pan, swipe between items
      — mostly present already; what is new is that **pan is now clamped** to the zoomed picture, so
      a photograph can no longer be flung off screen and left there with nothing to drag back, and
      the clamp is re-applied on a size change, which is what makes step 6's rotate-mid-zoom hold.
      Maximum zoom raised from 6× to 10× to match step 5.
- [x] Progressive load — thumbnail, then preview, then original on zoom
      — `MediaPage` climbs the ladder in three steps, each replacing the last in place so the
      picture sharpens rather than flashes: the cover thumbnail the grid already decoded (no network
      at all), then the 2048 px preview, then the original — but only once a zoom passes 1.5×.
      Starting from the thumbnail is what makes step 4's swipe through twenty items show a picture
      on every page instead of a spinner.
- [x] Multi-select mode
      — `TimelineSelection`, a pure type holding ids rather than items so it survives the library
      refreshing underneath it. Entered from the View menu or a cell's context menu, with Select All
      / Deselect All, a live count in the title, and a bottom bar carrying favorite, archive, and
      delete. Deselect All deliberately stays *in* the mode; only Done leaves it.
      Bulk **add to album** is absent rather than stubbed — that is Epic 9's.
- [x] Empty state that points at Import

**Flag:** `timeline` — true, and, like `mediaPipeline`, nothing branches on it. The timeline *is*
the Library tab rather than a feature inside it, so a `false` would leave the tab with nothing to
draw rather than hiding something.

**Status (2026-08-19):** all seven deliverables are implemented; **264 unit tests pass** (up from
219). One structural change went in alongside them and is worth knowing about:

- **`TimelineCache` and `PhotoLibraryService.revision`.** The scrubber and the pinch are both driven
  by scroll geometry, which means `LibraryView`'s body now runs on scroll *frames* rather than a
  handful of times a minute. It was previously regrouping the whole library — filter, sort, bucket,
  sort each bucket, sort the buckets — on every one of those passes. `TimelineCache` memoizes that
  on a revision counter, so a scroll frame costs an integer comparison. `TimelineCacheTests` asserts
  that sixty passes with unchanged inputs do the work once. Scroll-position state is likewise held
  in an unobserved `TimelinePosition` so that a scroll re-renders the scrubber's thumb rather than
  the library.
- **Covered by the suite:** the density ladder and its round trip; column counts across phone, iPad,
  and a 1/3 Split View pane; anchoring a date across a regroup; the scrubber's weighting, its
  binary search at every section boundary, its behaviour off both ends of the track, and its refusal
  to draw over a short library; the selection model including the Deselect-All-is-not-Done
  distinction and what happens when a selected item leaves the library mid-selection.
- **Not covered, and not coverable here:** every one of the nine manual verification steps below.
  They need the test library on a physical device, and steps 1 and 9 need Instruments. The unit
  suite says the arithmetic is right; it says nothing about frame rate, and 55fps is the actual
  exit criterion. **M2 is therefore not closed by this epic** — Epic 5 and these steps remain.

**Manual verification**

1. With the test library imported: scroll from today to the oldest item in one flick.
   No blank cells that persist past ~200ms, no stutter below 55fps (Instruments → Animation Hitches).
2. Pinch to zoom out through day → month → year → back. Scroll position anchors on the same
   date at each level rather than jumping to the top.
3. Drag the scrubber to a date two years back → grid arrives there; release → thumbnails fill in.
4. Tap a photo → opens full screen at the right item. Swipe left/right through 20 items —
   each loads without a visible placeholder flash.
5. Double-tap to zoom, pinch to 10x → sharpens to the original rather than staying blurry.
6. Rotate to landscape mid-zoom → no layout break, zoom preserved.
7. Multi-select 50 items → count is correct, Select All works, Deselect clears.
8. iPad: repeat 1–4 in Split View at 1/3 width and full width.
9. Memory ceiling: scroll the full 2,000-item library twice in Instruments → memory plateaus
   rather than climbing. A steady climb here is a cell-reuse or cache-eviction bug.

---

## Epic 5 — iOS Photos Integration

**Goal:** Get photos out of the system library and into Neutrino.

Covers mvp.md §3 iOS Photos Integration (selective path), §19 items 3.

**Deliverables**

- [x] `PhotosPicker`-based selective import (out-of-process; needs no library authorization —
      see the `project.yml` note)
      — shipped in Epic 3 and unchanged in shape: the picker is still the only route in, still needs
      no permission, and still runs one item at a time. What Epic 5 added is what happens *around*
      each item once the library can be seen.
- [x] `PHPhotoLibrary` full-access path for full-library import, with the authorization prompt
      and a graceful "limited access" state
      — `DevicePhotoLibrary`, and Settings › This Device's Photos › Photo Library. Access is
      **offered, not demanded**: every one of the five things below degrades to what the file itself
      says, so a user who declines has the app they had before. `limited` is a first-class state
      rather than a failure — the user shared a subset and the subset is what gets read — and it is
      the only state with a way to widen itself, via `presentLimitedLibraryPicker`. `restricted` is
      kept separate from `denied` because sending somebody to Settings to find a switch an MDM
      profile removed is worse than saying so. The enumeration itself is Epic 6's; this is the door.
- [x] Metadata extraction: creation date, GPS, camera/lens, EXIF, favorite status
      — `MediaMetadataExtractor` and `PhotoLibraryService.setMetadata`. This is the deliverable that
      turned out to be forced rather than optional: `MediaItem.metadata` was nil for *every item this
      app had ever imported*, because the server's metadata worker cannot open a file it only has the
      ciphertext of. The device is the one place an encrypted photograph's EXIF is readable, and
      `PUT /api/v1/photos/{id}/metadata` — a worker endpoint that takes an opaque JSON blob — is
      where it goes.
      **Location is the one field held back.** The picture is E2E encrypted; the metadata index is
      not, because the server sorts and searches it, so publishing coordinates hands Neutrino a list
      of where somebody has been beside a library it otherwise cannot open. `AppSettings
      .publishesLocationMetadata` defaults to `false`; the coordinates are extracted and kept
      locally either way, so the Info sheet is complete offline and a refresh does not blank it
      (`PhotoLibraryService.mergingDeviceOnlyMetadata`). Turning it on is what will make Epic 15's
      Places and map search work, and the Info sheet says which side of that line each photograph
      fell on.
- [x] Live Photo and RAW detection and preservation (stored now, rendered in v1.1)
      — both preserved rather than merely detected, which is the difference that costs something.
      A **Live Photo**'s paired video is a second `PHAssetResource` that nothing about the still
      refers to, so uploading only the still discards the motion silently; it now goes up encrypted
      into a `Live Photos` Drive folder (a subfolder because a MOV in the root is a *video* to the
      root-scoped `type=video` listing, and the timeline would gain a two-second clip beside the
      photograph), and its file id travels in the photo record's metadata so any device learns of it
      from one listing. **RAW** is fetched as the resource the camera wrote: the picker hands back a
      compatible JPEG rendering of a DNG, and storing that under the name "original" would make the
      backup a lie. Both draw a badge in the grid; neither is rendered in the viewer, which is what
      v1.1 is for, and `MediaInfoView` says "motion stored" rather than "Live Photo" so the label
      does not promise a press-and-hold that does nothing.
- [x] Save-back to the device library (`NSPhotoLibraryAddUsageDescription` is already declared)
      — the viewer's download button. Writes the **original**, not the 2048 px preview on screen,
      and through `addResource(with:data:)` rather than `creationRequestForAsset(from: UIImage)`,
      which would re-encode a DNG into a JPEG on the way out. A Live Photo goes back *as a Live
      Photo*, still and paired video together, which is what closes verification step 7's round
      trip. Add-only is a separate and much smaller permission, tracked separately, and asked for
      only the first time the button is used.

**Flag:** `import` — spelled `importFromPhotos` and shared with Epic 6, exactly as planned. The
`PHPhotoLibrary` half got a flag of its own, **`deviceLibraryAccess`**, because it is the only thing
in this app that asks for a permission the user can refuse: everything behind it degrades rather
than breaks, so a build with it off is a working app that never shows a photo-library prompt.

**Status (2026-08-19):** all five deliverables are implemented; **306 unit tests pass** (up from
264). Two things are worth knowing:

- **`PHAsset` cannot be constructed and a simulator has no camera roll**, so nothing downstream of
  the Photos framework could be tested through it. That is why `DeviceAsset` exists — a plain value
  holding everything the importer needs — and the extraction, merging, redaction, and publishing are
  all asserted against it rather than against a mock library. `DevicePhotoLibraryTests` covers what
  is left: the authorization mapping, and that constructing the service prompts for nothing.
- **The EXIF assertions use real JPEGs with real EXIF**, written by `CGImageDestination`
  (`TestImages.jpegWithMetadata`). A hand-built dictionary would assert that ImageIO can round-trip
  a `CFDictionary`, which is not the thing under test — the hemisphere-ref bug that puts Santiago in
  Boston only shows up against a real APP1 segment.
- **Not covered, and not coverable here:** every one of the eight manual verification steps. Steps
  5 and 6 need a device with the grant actually changed, step 7 needs a Live Photo and a DNG in a
  real library, and step 8 needs a photo library to write into. **M2 is not closed by this epic**;
  these steps and Epic 4's nine remain.

**Manual verification**

1. Import → Select Photos → pick 10 → all 10 appear in the timeline within seconds.
2. Confirm each landed with its **original** creation date, not today's. Sort order proves it.
3. Import a photo with known GPS → Info sheet shows the right coordinates.
4. Import a photo marked Favorite in Apple Photos → arrives favorited.
5. Grant only **Limited** photo access → app explains the limitation and still works with the
   selected subset; no crash, no infinite spinner.
6. **Deny** access entirely → app explains, offers Settings deep link, other tabs still work.
7. Import a Live Photo and a DNG → both stored, both exportable; verify by exporting and
   re-importing to Apple Photos. The Live Photo must come back **as a Live Photo** — a still plus a
   stray clip means the paired video went up but did not come back paired.
8. Viewer → Save to device → appears in Apple Photos.
9. Import one photo with a known location, with **Settings → Privacy → Include location in cloud
   metadata off**. Confirm with a proxy that no coordinates appear in the
   `PUT /api/v1/photos/{id}/metadata` body, and that the Info sheet still shows them. Then pull to
   refresh and confirm they are *still* there — the merge that keeps them is the easiest thing in
   this epic to break without noticing.

**Milestone M2 complete** when a user can pick photos and browse them in a real timeline.

---

# M3 — It's a Backup App

## Epic 6 — Full-Library Import

**Goal:** Move an entire Apple Photos library across, once, reliably.

Covers mvp.md §3 (full-library path), §19 items 4.

**Deliverables**

- [x] Full-library scan and enumeration with a live count
      — `DevicePhotoLibrary.scan(onProgress:)`, and the part that matters is where it runs.
      `enumerateObjects` over fifty thousand assets is tens of thousands of trips across the Photos
      XPC boundary, so the walk happens on a detached task and only the count hops back to the main
      actor. It also reads *less* per asset than Epic 5's `DeviceAsset` does: `ScannedAsset` exists
      because asking `PHAssetResource.assetResources(for:)` whether each item is RAW — which the
      full record needs — is cheap over forty picked items and minutes of wall clock over a real
      library. The full record is fetched one item at a time, when that item is imported.
- [x] Import queue with pause/resume and per-item retry
      — `import_queue` in `LocalStore` (schema v2) and the loop over it in `LibraryImportService`.
      Pause cancels the task; the rows stay. Retry is two-tier: a failed item is re-queued
      automatically at the end of each pass while its attempt count is under
      `LibraryImportService.maximumAttempts`, so a poison item is retried *around* the rest of the
      library rather than in front of it, and after three attempts it waits in a failed list with
      its error message for the user to retry by hand. A single item failing can never stall the
      queue, which is Epic 7's step 8 arriving an epic early because the queue is the same shape.
- [x] Duplicate detection — content hash plus `PHAsset.localIdentifier`, so re-running the
      import doesn't double the library
      — `ImportLedger`, and the important part is that there is exactly **one** of them. Both
      importers consult it: two records would mean a photograph picked in the picker and later found
      by a scan gets uploaded twice, which is the same bug this deliverable exists to prevent
      arriving by the back door. `PhotoImportService`'s `UserDefaults` list of fingerprints is gone,
      migrated into `imported_asset` on first launch — losing it on upgrade would have re-uploaded
      every existing user's library. Two keys because neither is enough: the identifier is known
      *before* any bytes are read (which is what lets a re-scan skip 49,000 of 50,000 assets without
      touching the disk) and survives a re-encode; the hash catches what has no asset to name — an
      item imported with no library access, or AirDropped from another phone.
- [x] Incremental import: only what's new since the last run
      — the same code path, deliberately. "New since the last run" and "not in the ledger" are the
      same set, and the second definition cannot drift out of step with reality the way a date
      cursor can: an item restored from a backup, or added to a shared album months after it was
      taken, has an old creation date and is still new here.
- [x] Album structure preserved where Drive can express it
      — the device album titles an item belongs to travel **on its queue row**, not in a map held by
      the run, because after a relaunch the run that finishes an item has no memory of the scan that
      found it. Each is matched to a Neutrino album by title or created, then the photo is added.
      User albums only: "Recently Added", "Selfies", and "Screenshots" are `.smartAlbum` — views over
      the library rather than structure somebody built — and copies of them would be albums that
      never update again. Only fresh imports are filed; an item skipped as a duplicate may already
      be in albums the user has since edited by hand, and re-adding it on every incremental run
      would slowly undo those edits.
- [x] Progress UI: items done / total, bytes, ETA, current item
      — `LibraryImportView`, plus a banner on the timeline so a run is visible without opening it.
      Progress is measured in **bytes rather than items**: a library is mostly photographs by count
      and mostly video by size, and an item-counting bar sits at 99% through the part that takes the
      longest. The bytes are estimates — the Photos framework does not publish a resource's size,
      and this app will not read the private `fileSize` key for a number that only draws a bar — but
      the estimate and the throughput are in the *same units*, so a systematic bias cancels in both
      the fraction and the ETA. See `ImportSizeEstimate`. The ETA excludes paused time, or a run
      resumed the next morning would tell somebody with ten items left that they had four days to
      wait, and says nothing at all for the first eight seconds.
- [x] Import survives app backgrounding and termination — resumes where it stopped
      — every outcome is written to its row before the next item begins, so being killed costs at
      most the item in flight, and that one is still `pending`. A launch that finds pending rows
      reports `.interrupted` rather than either silently restarting a 2,000-item upload or silently
      forgetting it. `beginBackgroundTask` buys the seconds after a home-press so the item in flight
      finishes rather than being killed halfway. This is **not** background upload — that needs a
      background `URLSession` and is Epic 7.
- [x] **The device library as an album, selectable and uploadable** *(added 2026-09-14, not in the
      original scope)*
      — `DeviceLibraryBrowser`, `DeviceLibraryView`, and a row at the foot of the Albums tab. This
      is the case Epics 5 and 6 between them left out: the picker shows the roll but only *outside*
      the app and hands back bytes, and the full-library run takes everything without showing any of
      it. Neither answers "what is on this phone, and which of it is backed up?", which is the
      question somebody asks before deciding to upload anything.

      Three things are worth knowing about how it is built. **It reuses Epic 6's queue rather than
      importing on its own**: `LibraryImportService.importSelected(_:)` writes the selection to
      `import_queue` and starts a run, so de-duplication, RAW originals, Live Photo motion,
      surviving a force-quit, the retry ladder and the Wi-Fi / storage / thermal conditions are all
      inherited rather than written a third time. **The rows are prepended, not substituted** — see
      `LocalStore.prependImportQueue(with:)`. `replaceImportQueue` is right for a scan, which owns
      the queue, and catastrophic for a selection: somebody picking forty photographs has not asked
      to discard the two thousand an interrupted run still has pending. Lower sort indices put the
      selection in front, because the person who just tapped Upload is watching for *those* forty.
      **Device album membership is deliberately not carried across**: reading it means walking every
      album in the library, a cost a scan pays once and a forty-item selection should not pay at all.

      Two performance shapes are load-bearing rather than incidental, both because this screen draws
      an upload progress bar and therefore re-runs `body` several times a second while the thing it
      started is running. `DeviceLibraryBrowser.revision` stands in for the listing wherever it
      would otherwise be *compared* — 50,000 structs, on every view update — and
      `DeviceLibraryFilter` memoizes the filtered grid on `(revision, ledger count, filter on)`, the
      same bargain `TimelineCache` makes for the timeline and for the same reason. Measured: one
      pass over 50,000 items is 52 ms, and every pass after it is 4 µs.

**Flag:** `import` — spelled `importFromPhotos` and shared with Epic 5, plus **`fullLibraryImport`**
for this epic's half, on the Epic 5 precedent: it is the path that asks for a permission and then
does thousands of unattended uploads, and a build with it off is a working app whose import is
exactly what the user picked in the picker. **`deviceLibraryAlbum`** was added for the browsable
album, on the same precedent again — it needs `deviceLibraryAccess` to enumerate the roll at all,
and it has no route for its Upload button without `fullLibraryImport`'s queue behind it.

**Status (2026-08-19):** all seven deliverables are implemented; **362 unit tests pass** (up from
306). Three things are worth knowing:

- **One refactor went in alongside them, and it was forced rather than tidy.** The per-item
  pipeline — upload, register, de-duplicate, favourite, Live Photo motion, metadata — moved out of
  `PhotoImportService` into `MediaImportPipeline`, which both importers now share. Two copies would
  have diverged into a photograph that arrives with its EXIF on one route and without it on the
  other, and, more immediately, into two duplicate records that do not know about each other.
- **Covered by the suite:** the ledger's two keys, its migration from `UserDefaults`, and that
  signing out takes it with it (a ledger surviving into the next account leaves them an empty
  library and an import that reports nothing to do); the queue surviving a `LocalStore` reopened
  from scratch mid-run and resuming at the right row rather than the top; the retry ladder,
  including that an item at its attempt limit stays failed while everything else drains; the byte
  arithmetic, the in-memory count bookkeeping that avoids a table scan per item, and the ETA's
  refusal to guess early or to count paused time; and the three hold reasons, which are the whole of
  what a stalled import tells the user and each name a different fix.
- **Not covered, and not coverable here:** every one of the nine manual verification steps.
  `PHAsset` cannot be constructed and a simulator has no camera roll, so nothing downstream of the
  Photos framework is reachable from a test — the same constraint Epic 5 documented. Step 1's exact
  count, step 8's thermals, and step 9's albums all need the test library on a physical device.
  The schema migration *has* been verified for real: the simulator's existing v1 database came up at
  `user_version = 2` with both new tables, which is the upgrade path an installed device takes.
  **M3 is not closed by this epic**; Epics 7 and 8 remain, as do these steps.

**Manual verification**

1. Full import of the test library (~2,000 items) → final count matches the Photos app's count
   exactly. An off-by-N is a filtering bug worth finding before it's an off-by-thousands.
2. Run the import **again** → reports 0 new items, adds nothing. This is the single most
   important check in the epic.
3. Pause at ~30% → progress freezes. Resume → continues from there, doesn't restart.
4. Force-quit at ~50% → relaunch → offers to resume, resumes correctly, no duplicates.
5. Airplane mode at ~50% → queue holds, no items lost; restore network → drains.
6. Add 3 new photos to the device library, run incremental import → exactly 3 imported.
7. Fill the device to near-full storage, then import → clear "not enough space" message,
   no corrupt partial items.
8. Watch thermals during a full import on device: sustained heavy import shouldn't push the
   phone into thermal throttling for more than a few minutes. If it does, add backpressure.
9. Confirm album structure survived: a 3-album test library shows those 3 albums in Neutrino.

**Manual verification — the device album** *(added 2026-09-14)*

10. Albums tab → "On This iPhone" shows a count matching the Photos app, and opens onto a grid of
    the roll with thumbnails drawn. Scroll the whole test library: no stalls, no blank cells left
    behind.
11. Tap 5 photos → the title reads "5 Selected" and the button reads "Upload 5 Items". Tap Upload →
    they appear in the Neutrino library, and the cells come back marked as uploaded.
12. Select the same 5 again and upload → nothing is added. The footer under the button should say so
    *before* the tap, which is the ledger being read at selection time rather than at upload time.
13. Turn on "Hide Already Uploaded" → those 5 disappear from the grid; turn it off → they come back,
    dimmed with a cloud tick. Force-quit and reopen: the setting is still where it was left.
14. Start a full-library import, then — while it runs — open the device album and upload 4 pictures.
    The 4 must upload **next**, and the full-library run must still have its remaining items
    afterwards. This is the property `prependImportQueue` exists for and the one most worth checking
    on a device.
15. Take a photograph in the Camera app with the device album open → it appears at the top of the
    grid without a relaunch (`PHPhotoLibraryChangeObserver`).
16. Deny photo access in Settings, reopen the album → an explanation and an Open Settings button, no
    empty grid and no crash. Grant "Limited", reopen → only the shared subset, with "Select More
    Photos…" offered in both the menu and the empty state.
17. Upload a selection with the vault locked → the items queue and a banner says to unlock rather
    than the tap doing nothing. Unlock → they upload.

---

## Epic 7 — Automatic Backup & Background Upload

**Goal:** New photos back themselves up without the user opening the app.

Covers mvp.md §3 Automatic Backup, §19 items 5, 6.

### This epic is a port, not a design

**Neutrino Drive already ships this mechanism**, and the epic was originally written as though it
did not. See `../neutrino_drive_ios_mobile`: `PhotoSyncService`, `PhotoSyncQueue`,
`BackgroundTransferService`, `PhotoSyncSettingsView`, and
`agent_docs/plans/feature-photo-auto-sync.md`. `FeatureFlags.photoAutoSync` and
`FeatureFlags.backgroundTransfers` are both `true` there.

Every hard question this epic used to ask has an answer over there, arrived at against a real
device and a real server:

| Question | Drive's answer |
|---|---|
| Change detection | `PHPhotoLibraryChangeObserver` live, `fetchPersistentChanges(since:)` for the killed-app gap, bounded `creationDate` fetch when the token expires |
| Transfers that outlive the app | `.background` `URLSessionConfiguration` behind a delegate, in `BackgroundTransferService` |
| Scheduled catch-up | `BGProcessingTask`, rescheduled from inside its own handler because the system grants one run per submission |
| Conditions | `NWPathMonitor` for Wi-Fi (resume on the callback, never poll), `batteryState` for charging, `isLowPowerModeEnabled` pausing background drains only |
| Retry | 30s → 2m → 10m → 1h → 6h, then a user-visible failed list; 4xx other than 408/429 is permanent immediately |

**Treat that as the specification.** This is the same relationship the roadmap already has with the
Notes app for `AuthService`, `KeyVaultService`, and `SyncEngine` — a port, with the design settled
elsewhere. Reading the Drive plan's "Known risks" section first is worth more than re-deriving any
of it.

Two of Drive's limitations must **not** come across with the port, because this app already does
better and regressing would be silent:

- Drive uploads Live Photos as **stills only**, dropping the paired video. Epic 5 pairs them, and
  `MediaImportPipeline` is what must stay on the path.
- Drive buffers plaintext + ciphertext + the assembled multipart body in memory, and carries a
  512 MB cap because of it. Epic 3's `MediaCrypto.encryptStream` / `MultipartFormBody.write` are
  memory-bounded, so this app needs no cap. Do not port one in.

### What is actually left to build

Epic 6 already shipped the durable queue (`import_queue`, `LocalStore` schema v2), the two-key
`ImportLedger`, the retry ladder, and the byte-based progress. What remains is the part that is
this app's and cannot be lifted from anywhere:

- [ ] `PHPhotoLibraryChangeObserver` enqueueing into **Epic 6's `import_queue`**, not a queue of
      its own. A second queue is a second ledger, and a second ledger is the duplicate upload
      Epic 6's `ImportLedger` exists to prevent.
- [ ] Background `URLSession` carrying `MediaImportPipeline`, which is a **multi-step** import —
      upload, register, rendition upload, metadata `PUT` — where Drive's is a single blob POST plus
      a key `PUT`. The step boundaries are where a suspension lands, so the pipeline has to be
      resumable at each one rather than only at item granularity. This is the only genuinely new
      engineering in the epic.
- [ ] `BGProcessingTask` under this app's own identifier (`com.neutrino.photos.backup` — two apps
      cannot share one), plus the conditions and the `NWPathMonitor` wiring ported from Drive.
- [ ] Backup status surface: "All photos backed up" / "12 remaining". Epic 6's `LibraryImportView`
      is most of the UI already; this is the always-on summary, not a second screen.
- [ ] Backup history — the one deliverable Drive has no answer for.
- [ ] Error/retry policy generalised beyond the import queue, closing the Epic 0 deliverable that
      is still open. Drive's backoff curve is the starting point.

### Unresolved: two apps backing up one camera roll

**This is a decision, and it is not made.** With both apps installed and backup enabled in each,
every new photo uploads **twice** against the same quota — once as a Drive file in `iPhone Photos`,
once as a registered photo record. Neither app can see the other's ledger; they are separate
sandboxes, and Drive's queue lives in its own Application Support container. The user also answers
two `PHPhotoLibrary` prompts for one job.

The two are not redundant copies of each other, which is what makes the choice real rather than
obvious: Drive's files sit outside the root-scoped `type=photo` listing, so they never appear in
this app's timeline, never get renditions, never get their EXIF published, and never land in an
album. A user who backed up through Drive and then installs Neutrino Photos opens it to an empty
library.

The options, none of them free:

1. **Retire `photoAutoSync` in Drive when this epic ships**, and migrate — adopt the existing
   `iPhone Photos` folder's files as photo records rather than re-uploading bytes the user already
   paid for. Cleanest result; it is a feature removal in a shipped app.
2. **Coexist with mutual detection** via an App Group or a Keychain access group, so whichever app
   is installed second defers. More engineering, and when detection breaks the failure is silent
   double-billing.
3. **Accept the overlap** and document it.

**Resolve this before writing code, not after** — option 1 implies a migration path that options 2
and 3 do not, and it is far cheaper to build than to retrofit.

**Flag:** `autoBackup`

**Manual verification** *(physical device only — none of this works on the simulator)*

1. Enable backup. Take a photo with the Camera app. Do **not** open Neutrino Photos.
   Wait 5 minutes → open the app → the photo is already uploaded.
2. Take a photo, immediately background the app, lock the phone for 10 minutes → on unlock,
   the upload completed (or is in flight), not reset.
3. Wi-Fi only ON, disconnect Wi-Fi, take a photo → queued, not uploaded on cellular.
   Reconnect → uploads. Status text explains the wait rather than showing a silent stall.
4. Charging only ON, unplugged → queued. Plug in → drains.
5. Low Power Mode ON → uploads defer; the UI says why.
6. Kill the app mid-upload from the app switcher → the background session still completes it
   (check `--console` on relaunch for the completion handler firing).
7. Queue 100 items, then walk out of network range → failures retry with backoff, don't
   hot-loop the radio. Check battery usage in Settings after an hour: Neutrino Photos should
   not be the top consumer.
8. Corrupt one queued item deliberately → it lands in "failed" with an explanation, and the
   rest of the queue keeps draining. A single poison item must not stall the queue.
9. Leave the device overnight with 500 items queued → all uploaded by morning.
10. Kill the app between the blob upload and the metadata `PUT` (the pipeline's step boundary) →
    on relaunch the item completes its remaining steps rather than re-uploading from the top.
    This is the step the multi-step pipeline exists to survive, and the one Drive's single-POST
    design never had to answer.
11. **Take a Live Photo with backup on** → it arrives paired, not as a still. The regression this
    catches is the Drive port bringing Drive's stills-only behaviour across with it.
12. **With Neutrino Drive installed and its Photo Sync also on**, take one photo → confirm what
    actually happens matches whichever option was chosen above. If it uploads twice, that is the
    unresolved decision showing up as a bill, not a bug to fix here.

---

## Epic 8 — Video Support

**Goal:** Videos are first-class, not "photos that happen to move".

Covers mvp.md §19 items 11, §4 (transcoding/streaming subset).

**Deliverables**

- [ ] Video import, upload, and storage with the same encryption path
- [ ] Poster-frame thumbnails; duration badge in the grid
- [ ] In-app playback with scrubbing, from the encrypted store
- [ ] Progressive/chunked download so playback starts before the full file lands
- [ ] Large-file handling: multi-GB uploads that don't exhaust memory or the background window

**Flag:** `video`

**Manual verification**

1. Import a 30s 4K video → thumbnail shows a poster frame and the duration.
2. Tap → plays within 2 seconds. Scrub to the middle → seeks without re-downloading from zero.
3. Import a 20-minute 4K video (~10GB) → uploads without an out-of-memory crash; monitor in
   Instruments.
4. Play a video that isn't fully downloaded → starts streaming rather than blocking on the
   whole file.
5. Play, lock the screen, unlock → playback state is sane (paused, resumable).
6. Import a slow-motion clip and a time-lapse → both play at the right speed, not at 1x.
7. Import a screen recording → treated as a video, plays with audio.
8. Rotate during playback → goes full-screen landscape cleanly.

**Milestone M3 complete** when the test library is fully backed up, unattended, on a real device.

---

# M4 — It's Reliable

## Epic 9 — Albums, Favorites & Recently Deleted

**Goal:** Basic organization.

Covers mvp.md §7 Manual Albums, §19 items 9, 10, 17.

### This epic needed the server, and that is the headline

Most of this epic's surface already existed — Epics 3–6 shipped favorites, archive, trash, restore,
empty, and album create/rename/delete/add/remove. **Three things were not missing from the app, they
were missing from the API**, and no amount of client work could have produced them:

| Gap | What it blocked |
|---|---|
| No `GET /api/v1/albums/{id}/items` | Opening an album at all. `album_photos` held the memberships and nothing read them, so neither this app nor the web client could show an album's contents — the count was the only thing an album could say about itself. |
| `PhotoResponse` carried no `deletedAt` | "30-day retention" and "days remaining". |
| No permanent delete, and `empty_trash` dropped only the rows | Verification step 7's "verify they're gone from Drive too" — the bytes stayed on the user's quota with nothing left pointing at them. |

All three are now implemented in the `neutrino` repository. See the Status section for the full list
and for the two pre-existing bugs found on the way.

**Deliverables**

- [x] Create / rename / delete album; add / remove photos; album cover
      — the first five already existed. The cover is new and is an **id, not an image**:
      `AlbumResponse.coverPhotoId` names the most recently added live photograph and the app resolves
      it against the library it already holds, so a cover costs no bytes and no extra request. Sending
      one base64 thumbnail per album would put a picture in every row of a mostly-text list.
- [x] Albums tab with cover grid and item counts
      — `AlbumsView` is now a `LazyVGrid` of cover cards over a list of collections, and the two are
      different shapes on purpose: collections are a fixed, short, *named* set a user scans for the
      word "Favorites", while albums are remembered by what is in them rather than what they are
      called. Cards open into the new `AlbumDetailView`.
- [x] Favorite toggle in viewer and in multi-select; Favorites view
      — all three already shipped (Epics 3–4). Unchanged.
- [x] Soft delete → Recently Deleted, 30-day retention, restore, delete permanently
      — the retention half is what was missing. `TrashRetention` counts down from `deletedAt`, and
      **the countdown is now a fact rather than a policy**: `PhotosService::purge_expired_trash`
      sweeps hourly from `main`. Before this the trash was kept forever and "kept for 30 days" was a
      sentence no code made true. Permanent delete arrives as `DELETE /photos/{id}/permanent`, which
      refuses a live photograph — the two-step path through the trash is the whole point of having
      one, and the app refuses to short-circuit it too.
- [x] Recently Added view
      — a fourth `MediaCollectionView.Collection`, ordered and filtered by `createdAt` rather than
      `timelineDate`. That distinction *is* the feature: a shoebox of 1998 photographs scanned today
      is recently added and is nowhere near the top of the timeline.
- [x] Bulk actions on multi-select: add to album, favorite, delete
      — favorite/archive/delete already existed; **add to album** was the one Epic 4 left absent
      rather than stubbed. `AlbumService.add(photoIDs:to:)` is serial (the endpoint takes one photo
      per call) and one refusal does not stop the rest, so 499 land when one is gone. The count is
      bumped once from what actually succeeded, so a partial run leaves an honest number on the card.

**Flag:** `organization` — added and `true`. An umbrella over the existing `albums`, `favorites`,
`archive`, and `trash` rather than a replacement: those four stay because each is independently
switchable and each was shipped by an earlier epic, and this one names what tied them into the
Albums tab and added what none of them had.

**Status (2026-08-20):** all six deliverables are implemented. **389 iOS unit tests pass** (up from
362) and **304 backend tests pass** (up from 294). Four things are worth knowing:

- **The server changed, and that was the epic.** In `neutrino`: `GET /albums/{id}/items`;
  `coverPhotoId` on `AlbumResponse`; `deletedAt` on `PhotoResponse`; `DELETE /photos/{id}/permanent`;
  `DriveClient::delete_file_permanently`; and the hourly trash purge in `main`. The web client's
  hand-written types in `web/packages/api-photos` were updated to match, but **no web UI was
  written** — the web app still cannot open an album, and now only because nobody has built the
  screen rather than because the API cannot answer.
- **Two pre-existing bugs turned up on the way, both now fixed.** First, an album's `photoCount`
  counted *trashed* photographs, so verification step 8 would have shown "3 photos" over a grid of 2
  — the count, the cover, and the contents now come from one query (`list_live_album_photo_ids`) so
  the three cannot disagree. Second, `album_photos` has **no foreign key** onto `photos`, so every
  permanent-delete path left memberships pointing at photographs that no longer existed; all three
  paths now clear them in the same transaction.
- **`delete_file` was the wrong call and the live test is what caught it.** It *trashes* a Drive
  file rather than deleting it, so the first implementation of permanent delete freed nothing — the
  unit tests passed and `GET` on the file still returned 200. `delete_file_permanently` was added to
  `DriveClient` and verified against a running server: the row goes, the blob leaves the disk, and
  the file 404s. This is exactly the failure mode step 7 exists to catch.
- **Verified against a real server, not only in unit tests.** The whole Epic 9 loop — create album,
  add three photographs, list contents, cover ordering, remove-from-album leaving the photo in the
  library, trashing dropping it from the album while the count follows, restore putting it back in
  the album it was in, permanent delete freeing the bytes — was exercised end to end against the
  built binary on a **copy** of the database. What that does *not* cover is every manual step below:
  they need the test library on a physical device, and steps 1, 4, 6, and 9 are UI behaviour no curl
  can see. **M4 is not closed by this epic**; Epic 10 remains, as do these steps.

**Manual verification**

1. Create an album, add 20 photos → count and cover are right; open it and confirm all 20.
2. Remove a photo from the album → gone from the album, **still in the timeline**. (Removing
   from an album must never delete the photo — verify explicitly.)
3. Rename, then delete the album → the album's photos survive in the timeline.
4. Favorite 5 photos from multi-select → all 5 in Favorites; unfavorite one → drops out.
5. Delete 10 photos → gone from timeline, present in Recently Deleted with days remaining.
6. Restore 5 → back in the timeline, in their original date positions (not at the top).
7. Delete permanently → gone from Recently Deleted; verify they're gone from Drive too.
   *Checked against a running server: the `files` row is deleted, the blob leaves the disk, and a
   `GET` on the Drive file 404s. Worth repeating on a device against the real deployment, since it
   is the step whose first implementation silently freed nothing.*
8. Add one photo to three albums → appears in all three; delete it → gone from all three
   and in Recently Deleted once, not three times.
9. Add 500 photos to an album at once → completes without freezing the UI.
   *The one step most likely to fail. The add is serial by necessity — one HTTP call per photo — so
   500 items is 500 round trips, and the progress bar in `AlbumPickerView` exists because of it. If
   this is too slow to live with, the fix is a bulk endpoint on the server, not concurrency here.*
10. **With the trash purge running:** trash a photo, set its `deleted_at` back beyond the retention
    window in the database, and confirm the hourly sweep removes it *and* its Drive file. This is
    the step that proves the countdown means something; nothing before this epic swept anything.

---

## Epic 10 — Sync & Offline

**Goal:** Multi-device consistency, and full usefulness with no network.

Covers mvp.md §15, §16, §19 items 15, 16. Ports the `SyncEngine` / `OfflineStore` pattern
from the Notes app.

**Deliverables**

- [ ] `SyncEngine` — incremental delta sync on a cursor, on foreground and on a schedule
- [ ] Download queue for renditions and offline originals
- [ ] Conflict detection and resolution per the Epic 0 rule
- [ ] Offline browsing of everything cached; offline albums/favorites/deletes queued
- [ ] Network-aware behaviour via the existing `NetworkMonitor`
- [ ] Per-device sync status in Settings

**Flag:** `sync`

**Manual verification** *(needs two devices, or a device plus the web app)*

1. Device A: import 10 photos. Device B: within a minute, the same 10 appear.
2. Device A: create an album; B sees it. B adds a photo to it; A sees the addition.
3. Device A: delete a photo. B: it moves to Recently Deleted, not silently vanishing.
4. **Conflict:** both devices offline. A renames album to "Trip", B renames it to "Vacation".
   Both come online → resolution matches the Epic 0 rule, no duplicate album, no data loss,
   and the losing side is reported to the user rather than discarded silently.
5. Airplane mode: browse the timeline → cached thumbnails render; uncached items show a clear
   "not downloaded" state, not a broken image.
6. Airplane mode: favorite 3 photos, delete 2, create an album → all queued. Restore network →
   all four changes land on the server, in order.
7. Airplane mode for 24 hours with queued changes → on reconnect, everything drains.
8. Sign out and back in on a fresh install → full library rebuilds from the cloud, correct
   count, correct dates.
9. Settings → Devices shows both devices with plausible last-sync times.

**Milestone M4 complete** when two devices stay consistent through an offline conflict.

---

# M5 — It's Findable

## Epic 11 — Search & Metadata

**Goal:** Find a photo without scrolling, and see what a photo actually is.

Covers mvp.md §5 Basic Search, §13 Metadata, §19 items 12, 13, 19.

**Deliverables**

- [ ] Local search index over filename, date, camera, lens, media type, album, favorite
- [ ] Search UI with suggestions and recent searches
- [ ] Date/month/year queries in natural forms ("June 2024", "2023", "last week")
- [ ] Info sheet: date/time, location, camera, lens, exposure, ISO, aperture, focal length,
      file size, resolution, MIME type, filename
- [ ] Metadata editing: date/time, title, caption
- [ ] Search works fully offline against the local index

**Flag:** `search`

**Manual verification**

1. Search a known filename → the right photo, first result.
2. Search "June 2024" → exactly the items from that month; cross-check the count against the
   timeline scrolled to June 2024.
3. Search "iPhone 15 Pro" → only items from that camera.
4. Search "video" → the 20 test videos, nothing else.
5. Type a query with no matches → an empty state, not a spinner or a crash.
6. Search on a 50,000-item library → results in under 500ms. Time it; don't estimate.
7. Airplane mode → search still works against the local index.
8. Open Info on a photo with full EXIF → every field populated and correct against what
   Apple Photos shows for the same file.
9. Open Info on a photo with **no** GPS and no EXIF → missing fields are omitted or shown as
   "—", never as "0" or "nil".
10. Edit a photo's date → timeline re-sorts to the new position; confirm on a second device
    after sync.
11. Add a caption → persists, survives relaunch, syncs.

---

## Epic 12 — Storage Management & Settings

**Goal:** The user can see and control what's stored where.

Covers mvp.md §17, §19 items 18.

**Deliverables**

- [ ] Settings: Backup (enabled, Wi-Fi only, cellular, charging only, original vs optimized,
      video settings)
- [ ] Settings: Privacy (location processing, analytics, encryption status)
- [ ] Settings: Storage (cloud usage, local cache usage, offline storage, clear cache,
      optimize storage)
- [ ] Settings: Account (account, devices, encryption keys, sessions, storage plan)
- [ ] Storage dashboard with a real breakdown by kind
- [ ] "Optimize storage" — evict local originals that exist in the cloud

**Flag:** none — Settings ships incrementally with the epics it configures.

**Manual verification**

1. Storage dashboard numbers match reality: compare cloud usage against the Drive web app's
   figure, and local cache against Settings → General → iPhone Storage → Neutrino Photos.
   Both should be within a few percent.
2. Clear cache → local usage drops, **no photos are lost** — browse the timeline and confirm
   items re-download.
3. Optimize storage → local originals evicted, thumbnails retained, timeline still scrolls
   smoothly, opening an item re-fetches the original.
4. Toggle every backup setting and confirm each one changes actual behaviour (re-run the
   relevant Epic 7 checks) rather than just flipping a switch.
5. Encryption status shows the real vault state; lock the vault and confirm it updates.
6. Devices list: sign in on a second device → it appears. Revoke it → that device is signed out.
7. Storage plan reflects the account's real plan and quota.
8. Fill the cache to its cap → eviction kicks in automatically, app stays usable.

**Milestone M5 complete** when search returns in <500ms on a 50k library and storage numbers
reconcile with the web app.

---

# M6 — Ship

## Epic 13 — Basic Sharing

**Goal:** Get a photo out of the app to someone else.

Covers mvp.md §12 Basic Sharing, §19 items 20. Ports `SharingService` / `LinksService`
from the Notes app.

**Deliverables**

- [ ] iOS Share Sheet export of one or many photos (decrypted originals)
- [ ] Neutrino share link for a photo or album, with the web viewer on the other end
- [ ] Link permissions: view-only, download allowed, expiry
- [ ] Share management: list active links, revoke
- [ ] Universal Link inbound handling — `https://www.getneutrino.app/open/photo/<id>` opens the
      app (the `applinks:` entitlement is already in `project.yml`); needs a router plus
      `FeatureFlags.appLinks`

**Flag:** `sharing`

**Manual verification**

1. Share one photo via the Share Sheet to Messages → the recipient gets a real, viewable image.
2. Share 10 photos at once → all 10 arrive.
3. Create a share link for an album → open it in a **signed-out browser** → the album displays.
4. Set the link to expire in 1 day; change the device clock past it (or use a short expiry) →
   the link is refused with a clear message.
5. Revoke a link → it stops working immediately, not on next cache expiry.
6. View-only link → no download control offered, and the direct asset URL isn't fetchable.
7. Paste `https://www.getneutrino.app/open/photo/<id>` into Notes on the device and tap it →
   Neutrino Photos opens on that photo. Test with and without the `www.`.
8. Tap a link for a photo the account can't access → a clear "not available" screen, not a crash.
9. Confirm what's shared: a share link must not leak the master key. Inspect the link and the
   web request in a proxy and confirm the sharing key is scoped to that item.

---

## Epic 14 — Release Readiness

**Goal:** Turn a working app into a shippable one.

**Deliverables**

- [ ] Onboarding flow: sign in → unlock vault → grant photo access → start import
- [ ] Empty, loading, and error states audited across every screen
- [ ] Accessibility pass: VoiceOver labels, Dynamic Type, contrast, reduced motion
- [ ] Localization scaffolding (strings extracted, even if English-only at launch)
- [ ] Crash/diagnostic reporting, privacy-respecting and disclosed
- [ ] App Store metadata, screenshots, privacy nutrition label
- [ ] Performance budget met on the oldest supported device (iOS 16 floor per `project.yml` —
      confirm on an iPhone 11 or equivalent)
- [ ] TestFlight beta with external testers

**Manual verification**

1. Full cold-start journey on a factory-reset device: install → onboard → import 2,000 photos →
   browse. Time it end to end and write the number down; it's the number that decides whether
   onboarding needs work.
2. VoiceOver: navigate timeline → viewer → album → settings using only VoiceOver. Every control
   is reachable and announced meaningfully.
3. Dynamic Type at the largest accessibility size → no clipped or overlapping text anywhere.
4. Dark mode across every screen.
5. iPad: full pass in portrait, landscape, Split View, and Slide Over.
6. iOS 16 device: complete the M2 and M3 verifications there. Anything that only works on
   iOS 18 is a bug at this deployment target.
7. TestFlight build via `scripts/deploy_testflight.sh` → installs and runs for external testers.
8. Run 10 external testers for two weeks. Zero data-loss reports is the gate; anything less
   is a blocker, not a known issue.
9. Privacy label reconciled line by line against what the app actually transmits.

**Milestone M6 / v1.0 complete.**

---

# Post-v1.0

Detailed epics get written when the milestone before them ships. Mapping from mvp.md §19:

## v1.1 — Rich Library

| Epic | Scope | mvp.md |
|---|---|---|
| 15 | Places & Map — GPS clustering, map view, location search, location privacy controls | §6 |
| 16 | Live Photos, RAW, bursts, panoramas — full rendering, not just storage | §2 |
| 17 | Smart albums — date, location, favorite, search-based, auto-updating | §7 |
| 18 | Duplicate detection & cleanup assistant | §11 |
| 19 | Basic editing — crop, rotate, straighten, exposure, color, filters, non-destructive | §9 |
| 20 | Shared & collaborative albums | §12 |
| 21 | Hidden items, screenshots view, screen recordings | §2 |

## v1.5 — Intelligence

| Epic | Scope | mvp.md |
|---|---|---|
| 22 | On-device face detection & clustering, People view | §5 |
| 23 | On-device object/scene recognition | §10 |
| 24 | Semantic search over on-device embeddings | §5 |
| 25 | Memories — automatic collections and slideshow presentation | §8 |

The privacy constraint from mvp.md §5 governs this whole tier: face and object processing runs
on device, or through an explicitly privacy-preserving pipeline. That is an architectural
decision to make **before** Epic 22, not during it — E2E encryption means the server cannot see
pixels, so cloud-side inference is off the table without a deliberate, disclosed exception.

## v2.0 — Ecosystem

| Epic | Scope | mvp.md |
|---|---|---|
| 26 | AI editing — object removal, background blur, enhancement | §9, §10 |
| 27 | Family / shared libraries | §12 |
| 28 | Web parity — full library, search, albums, editing in Neutrino web | §18 Phase 7 |
| 29 | Desktop — library, automatic backup, bulk management | §18 Phase 7 |
| 30 | Drive & cross-app integration — shared photo picker for Docs/Sheets/Slides | §18 Phase 7 |
| 31 | Widgets, App Intents, Siri, Shortcuts, Spotlight | §14 |
| 32 | Full-library export, no-lock-in guarantee | §21 |

---

# Cross-cutting rules

These aren't epics; they apply to every epic and are checked at every milestone.

**Never lose a photo.** Deletion is soft by default, uploads are verified by hash before the
local copy is evictable, and no code path removes the last copy of an item. Every epic's
verification includes at least one "and the photo is still there" step for this reason.

**The user's keys never leave the device.** Any epic that adds a network call states explicitly
what it sends. Re-verify with a proxy at each milestone, not just once.

**Scale is a feature, tested like one.** 2,000 items is the development library; 50,000 is the
acceptance library. Timeline scroll, search latency, and import throughput are measured on the
larger one before a milestone closes.

**Offline is the default assumption.** Every feature is asked "what does this do on a plane?"
before it's called done.

**Feature flags are removed once an epic ships and stabilizes** — typically one release later.
A flag that outlives its epic by three releases is dead code with a switch on it.
