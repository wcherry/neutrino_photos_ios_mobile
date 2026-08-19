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
- [ ] Local database choice and schema (SQLite via GRDB, or Core Data — decide and justify;
      the deciding factor is 100k-row timeline query performance, not familiarity)
- [ ] Sync protocol: cursor/delta shape, conflict rule, tombstones
- [ ] Thumbnail/rendition ladder: which sizes, generated where, cached where, evicted how
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

**Status (verified 2026-08-18):** three of nine deliverables are done — and they are the three the
app was *forced* to decide in order to ship the timeline, so they exist as working code rather than
as prose. The other six are the ones an implementation can defer, and all six were: there is no
local database anywhere in the tree (no GRDB, Core Data, or SQLite dependency), no sync cursor,
no retry or backoff logic, and no background task registration. `FeatureFlags.offlineMode` and
`FeatureFlags.automaticBackup` are `false` for exactly this reason.

`architecture.md` has not been written. Some of what belongs in it now lives in `README.md` and in
the doc comments on `MediaContentService` — that covers the decided items but not the deferred ones,
and it is not a substitute for the document the exit criteria name.

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

- [ ] `PhotosDriveService` — Drive CRUD scoped to `type=photo`, modelled on `NotesDriveService`
- [ ] Rendition generator: thumbnail (grid), preview (viewer), original (export)
- [ ] Encrypted upload of original + renditions, streaming, memory-bounded
- [ ] Encrypted download with local cache
- [ ] `ThumbnailCache` — disk-backed, size-capped, LRU eviction
- [ ] Local database from Epic 0, with the schema live and migrated

**Exit criteria:** SHA-256 of a downloaded original equals the SHA-256 of what was uploaded.

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

- [ ] Chronological grid, newest first, grouped by day with sticky date headers
- [ ] Month and year grouping levels; pinch-to-zoom between densities
- [ ] Fast scroll with a date scrubber
- [ ] Full-screen viewer: pinch/double-tap zoom, pan, swipe between items
- [ ] Progressive load — thumbnail, then preview, then original on zoom
- [ ] Multi-select mode
- [ ] Empty state that points at Import

**Flag:** `timeline`

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

- [ ] `PhotosPicker`-based selective import (out-of-process; needs no library authorization —
      see the `project.yml` note)
- [ ] `PHPhotoLibrary` full-access path for full-library import, with the authorization prompt
      and a graceful "limited access" state
- [ ] Metadata extraction: creation date, GPS, camera/lens, EXIF, favorite status
- [ ] Live Photo and RAW detection and preservation (stored now, rendered in v1.1)
- [ ] Save-back to the device library (`NSPhotoLibraryAddUsageDescription` is already declared)

**Flag:** `import`

**Manual verification**

1. Import → Select Photos → pick 10 → all 10 appear in the timeline within seconds.
2. Confirm each landed with its **original** creation date, not today's. Sort order proves it.
3. Import a photo with known GPS → Info sheet shows the right coordinates.
4. Import a photo marked Favorite in Apple Photos → arrives favorited.
5. Grant only **Limited** photo access → app explains the limitation and still works with the
   selected subset; no crash, no infinite spinner.
6. **Deny** access entirely → app explains, offers Settings deep link, other tabs still work.
7. Import a Live Photo and a DNG → both stored, both exportable; verify by exporting and
   re-importing to Apple Photos.
8. Viewer → Save to device → appears in Apple Photos.

**Milestone M2 complete** when a user can pick photos and browse them in a real timeline.

---

# M3 — It's a Backup App

## Epic 6 — Full-Library Import

**Goal:** Move an entire Apple Photos library across, once, reliably.

Covers mvp.md §3 (full-library path), §19 items 4.

**Deliverables**

- [ ] Full-library scan and enumeration with a live count
- [ ] Import queue with pause/resume and per-item retry
- [ ] Duplicate detection — content hash plus `PHAsset.localIdentifier`, so re-running the
      import doesn't double the library
- [ ] Incremental import: only what's new since the last run
- [ ] Album structure preserved where Drive can express it
- [ ] Progress UI: items done / total, bytes, ETA, current item
- [ ] Import survives app backgrounding and termination — resumes where it stopped

**Flag:** `import` (shared with Epic 5)

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

---

## Epic 7 — Automatic Backup & Background Upload

**Goal:** New photos back themselves up without the user opening the app.

Covers mvp.md §3 Automatic Backup, §19 items 5, 6.

**Deliverables**

- [ ] `PHPhotoLibraryChangeObserver` → new items auto-queue
- [ ] `URLSession` background configuration for uploads that outlive the app
- [ ] `BGProcessingTask` registration for scheduled catch-up
- [ ] Conditions: Wi-Fi only, cellular allowed, charging only, low-power respect
- [ ] Upload queue UI: pending, in-flight, failed, with per-item status and retry
- [ ] Backup status surface: "All photos backed up" / "12 remaining"
- [ ] Backup history

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

**Deliverables**

- [ ] Create / rename / delete album; add / remove photos; album cover
- [ ] Albums tab with cover grid and item counts
- [ ] Favorite toggle in viewer and in multi-select; Favorites view
- [ ] Soft delete → Recently Deleted, 30-day retention, restore, delete permanently
- [ ] Recently Added view
- [ ] Bulk actions on multi-select: add to album, favorite, delete

**Flag:** `organization`

**Manual verification**

1. Create an album, add 20 photos → count and cover are right; open it and confirm all 20.
2. Remove a photo from the album → gone from the album, **still in the timeline**. (Removing
   from an album must never delete the photo — verify explicitly.)
3. Rename, then delete the album → the album's photos survive in the timeline.
4. Favorite 5 photos from multi-select → all 5 in Favorites; unfavorite one → drops out.
5. Delete 10 photos → gone from timeline, present in Recently Deleted with days remaining.
6. Restore 5 → back in the timeline, in their original date positions (not at the top).
7. Delete permanently → gone from Recently Deleted; verify they're gone from Drive too.
8. Add one photo to three albums → appears in all three; delete it → gone from all three
   and in Recently Deleted once, not three times.
9. Add 500 photos to an album at once → completes without freezing the UI.

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
