# Neutrino Photos iOS

An end-to-end encrypted photo and video library for the Neutrino ecosystem. Built with SwiftUI, the
app reuses Neutrino's existing Photos, Drive, and Auth services rather than inventing its own — a
photograph imported here opens in the Neutrino web app, and one uploaded there appears here.

## Tech Stack

- Swift / SwiftUI, iOS 16+
- Xcode / XcodeGen (`project.yml` is the source of truth; the `.xcodeproj` is generated and gitignored)
- [swift-sodium](https://github.com/jedisct1/swift-sodium) — XChaCha20-Poly1305 secretstream, `crypto_box_seal`

## Getting Started

```bash
brew install xcodegen
xcodegen generate
scripts/run_simulator.sh              # build, install, launch on a simulator
scripts/run_simulator.sh --physical   # ... on a paired iPhone
```

Sign in with a Neutrino account. If the account has an encryption vault the app offers to unlock it
straight away — the encryption password (or recovery code, or passkey) set on the web opens the same
key here. An account with no vault imports the key file instead: the JSON the web app exports from
its own Settings > Encryption page, chosen in the app or simply tapped in Files.

## What This Build Does

| Area | Features | Status |
|------|----------|--------|
| Authentication | OAuth PKCE login, token refresh, device registration, account profile, sign out | COMPLETE |
| Encryption | Vault unlock (password, recovery code, passkey), key import (file, paste, or tapped), Keychain storage, per-file key sealing and unsealing, locked state | COMPLETE |
| Devices | The account's signed-in devices, when each registered, revoking one | COMPLETE |
| Timeline | Grid grouped by day / month / year, pinch between those densities, date scrubber, multi-select, capture-date ordering, pull to refresh, drawn from the local index before the network answers | COMPLETE |
| Viewer | Full screen, progressive load (thumbnail → preview → original on zoom), pinch and double-tap zoom to 10×, clamped pan, swipe between items, info panel | COMPLETE |
| Video | Playback of the decrypted original, streamed to disk rather than held | COMPLETE |
| Import | Multi-select from the system picker, HEIC→JPEG, EXIF capture date, thumbnail, upload progress, cancel, duplicate skip | COMPLETE |
| Full-library import | Scan the whole device library, resumable queue with pause and retry, incremental re-runs, albums recreated, progress and ETA | COMPLETE |
| Photo library | Optional `PHPhotoLibrary` access: real capture dates, favorites, coordinates, Live Photo motion, RAW originals, save back to the device | COMPLETE |
| Metadata | Dimensions, camera, lens, exposure, coordinates — extracted on device and published, with location held back by default | COMPLETE |
| Media pipeline | Rendition ladder, encrypted preview beside each original, capped and evicted caches of decrypted media, SQLite library index | COMPLETE |
| Favorites / Archive / Trash | Star, archive, delete, restore, empty | COMPLETE |
| Albums | List, create, rename, delete, add a photo | PARTIAL — see below |
| Settings | Account, grouping, appearance, Wi-Fi-only uploads, storage breakdown, cache, device name, roadmap | COMPLETE |

The shell is four tabs — Library, Albums, Search, Settings — and keeps that shape in every build.
Search has no index behind it yet and says so; a tab that appeared when a flag flipped would move
the other three under the user's thumb.

`FeatureFlags` is the honest list of what is *not* here yet: automatic backup, offline mode, search,
places, people, memories, editing, sharing, and Universal Links. Each is a flag set to `false`
rather than a half-built screen. Two flags are `true` and still worth naming, and both split off
from `importFromPhotos` for the same reason: `deviceLibraryAccess` covers everything that talks to
`PHPhotoLibrary` — the only thing in this app that asks for a permission the user can refuse — and
`fullLibraryImport` covers the run that walks a whole camera roll unattended. A build with either
off is a working app: one that never shows a photo-library prompt, and one whose import is exactly
what you picked in the picker.

## Architecture

```
NeutrinoPhotosApp        composition root — every service constructed once, injected explicitly
├── APIClient            all authorized HTTP: token refresh, status checks, JSON, uploads
├── AuthService          OAuth PKCE (login → authorize → token), refresh, /auth/me, logout
├── KeyVaultService      /api/v1/auth/keyvault — unlock the account key, and this device's lock state
│   ├── KeyVaultCrypto   Argon2id, the secretbox envelope, identity verification
│   └── PasskeyPRFAuth…  the WebAuthn PRF assertion behind a passkey unlock (iOS 18+)
├── KeyImportService     the key file path, and the only place keys are stored
├── KeyFileRouter        a .json key file handed to the app from outside
├── DeviceSessionService /api/v1/auth/sessions — the account's devices
├── PhotoLibraryService  /api/v1/photos — the library, favorites, archive, trash, registration
├── PhotosDriveService   /api/v1/drive — the type=photo listing, quota, the renditions folder
├── AlbumService         /api/v1/albums
├── MediaContentService  download + decrypt an original; encrypt + upload a new one
│   ├── MediaCrypto      the primitives: one-shot and streaming, DEK sealing, metadata
│   ├── MediaRendition   the ladder — thumbnail, preview, original — and how each is made
│   └── DiskCache        decrypted media, capped and evicted least-recently-used
├── ThumbnailCache       the grid's bitmaps: NSCache over that same DiskCache
├── LocalStore           SQLite — the timeline, the rendition index, the import ledger and queue
├── MediaImportPipeline  one item, end to end: de-duplicate → upload → register → enrich
│   ├── ImagePreparation what the picker hands over, turned into what Drive should store
│   ├── MediaMetadataEx… dimensions, camera, exposure, coordinates — read off the plaintext
│   └── ImportLedger     what this device has already uploaded, by asset id and by content hash
├── PhotoImportService   the picker's half: selection → bytes → the pipeline, one item at a time
├── LibraryImportService the whole library: scan → resumable queue → the same pipeline
├── DevicePhotoLibrary   the device's own library: what Apple Photos knows, and saving back to it
├── NetworkMonitor       connectivity and whether the path is metered
├── AppSettings          preferences, in UserDefaults
└── TimelineCache        the grouped timeline, rebuilt only when the library or the density changes
```

### The timeline's job is to not do work

The Library tab draws from `TimelineCache`, not from the library service directly, and the reason is
the scrubber and the pinch: both read scroll geometry, so `LibraryView`'s body runs on scroll
*frames* rather than when something changes. Grouping is a filter, a sort, a bucketing, a sort inside
each bucket, and a sort of the buckets — over the whole library — and doing that sixty times a second
is the stutter, not the fix for it.

So `PhotoLibraryService` carries a `revision` counter that bumps whenever `allItems` changes, and the
cache keys its output on `(revision, grouping, showsArchived)`. A scroll frame costs an integer
comparison. The same idea governs scroll position: it lives on `TimelinePosition`, which
`LibraryView` holds but deliberately does **not** observe, so a scroll re-renders the scrubber's
thumb rather than a thousand cells.

### The library is Photos, the bytes are Drive

Two APIs, deliberately. `GET /api/v1/photos` answers with the *photo records* — capture date,
favourite and archived flags, and the id that albums, faces, and edits address. The bytes live in
Drive, and an item's `fileID` is what the download and file-key endpoints take. An upload is
therefore two steps: `POST /api/v1/drive/files/upload` stores the ciphertext, then
`POST /api/v1/photos` registers it as a photograph. A Drive image nothing registered — a picture
attached to a document, say — is not in the library, which is correct.

### Encryption, and what the grid does without it

Each file gets a fresh data key. The content is sealed with an XChaCha20-Poly1305 secretstream, the
data key is sealed to the account's Curve25519 public key with `crypto_box_seal`, and only then is
anything sent. The private key lives in this device's Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and never reaches Neutrino.

The timeline does not touch any of that. Every Drive file carries a small **plaintext cover
thumbnail** — generated on the device that uploaded it, because the server only ever sees
ciphertext — and that is what a grid cell draws. So a library browses fine before a key is imported,
and a thousand-item timeline costs one request rather than a thousand downloads. Opening an item at
full size is the first moment an original is fetched, unsealed, and decrypted.

A file with no stored key ref is served as it stands: that is a picture uploaded before E2EE, and
the web client makes the same allowance, so both agree on which files are readable.

### Getting the key onto the device

Two routes, and the app has to be honest about which one applies. An account with a **key vault** has
its identity key stored encrypted under a master key, which is itself wrapped once per unlock method —
an encryption password, a recovery code, a passkey. `KeyVaultService` fetches that envelope, unwraps
it with whichever secret the user has, checks the recovered key really is the one the vault advertises,
and hands it to `KeyImportService`. Nothing downstream knows or cares which route a key arrived by.

The master key is not kept. It exists for the moment it takes to unwrap the identity; what lands in
the Keychain is the identity itself, under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
*AfterFirstUnlock* so an upload running in the background can still seal a file key with the phone in
a pocket, *ThisDeviceOnly* so an end-to-end encryption key never rides an iCloud backup to a device
nobody unlocked it on.

An account created before the vault existed has no password to type, and gets the **key file** path
instead: chosen in the app, pasted, or simply tapped in Files — the app claims `.json` and consumes
the URL rather than only declaring the type.

### Locked is not blocked

Signed in without the key is a normal state, not an error screen. The timeline draws cover thumbnails,
so a locked library browses exactly as well as an unlocked one; what is missing is originals and
uploads. So the app prompts once per launch, and after that says so where it matters — a banner on the
library, an Unlock button on an original that would not open, and an importer that refuses with the
instruction that actually applies ("unlock" for an account with a vault, "import" for one without).

The one case worth shouting about is a key from a *different* account, left behind by signing out and
into another. Unnoticed, that presents as every photograph failing to decrypt one at a time;
`KeyVaultService` compares the stored public key against the vault's and says so instead.

### The picker needs no permission; the library adds what it cannot give

`PhotosPicker` runs out of process and hands back only the items the user chose, so importing has
never needed a photo-library prompt and the app never sees the rest of the roll. That stays the
default. But a picked item is *bytes*, and a photo library is more than bytes:

| Needs `PHPhotoLibrary` | Why the picker cannot give it |
|---|---|
| The real capture date | a screenshot or an edited export has no EXIF date; without this it files itself under today |
| Favourite status | a flag on the library's record, not on the file |
| Live Photo motion | the paired video is a second `PHAssetResource` that nothing about the still refers to |
| The RAW original | the picker renders a compatible JPEG from a DNG rather than handing over the DNG |
| Coordinates for an edited export | editors drop the GPS block; Apple Photos keeps its own copy |
| Full-library and automatic import | there is no picker — the library has to be enumerated (Epics 6 and 7) |

So access is **offered rather than demanded**, from Settings › This Device's Photos. Every one of
those degrades rather than breaks, and *Limited* is a working state over fewer items rather than a
failure — it is also the only state with a way to widen itself, which is why the recurring system
alert is suppressed and the app drives that prompt itself. *Restricted* is kept apart from *Denied*
because sending somebody to Settings to find a switch a Screen Time or MDM profile removed is worse
than saying so.

A Live Photo's motion goes up encrypted into a `Live Photos` Drive folder, for the mirror of the
reason previews get one: a MOV in the Drive root is a *video* to the root-scoped `type=video`
listing, so filing it there would put a two-second clip beside the photograph in the timeline. Its
file id travels in the photo record's metadata, so another device learns of it from the library
listing rather than by going looking. Saving such an item back to Apple Photos writes both
resources, so what comes out is a Live Photo rather than a still and a stray clip.

### Metadata is read here, because it cannot be read anywhere else

Neutrino has a metadata worker that reads dimensions and EXIF off an uploaded file, and for a file
uploaded in the clear that is the right place for it. Nothing this app uploads is in the clear: what
reaches the server is ciphertext and the key never leaves the phone. So the extraction happens on
the device, in the seconds between the picker handing a picture over and the upload sealing it, and
`PUT /api/v1/photos/{id}/metadata` — a worker endpoint taking an opaque JSON blob — is where it
goes. Without that, `metadata` is nil forever for every item this app imports, and the Info sheet
has nothing to show but a file name.

**Location is the one field held back.** The photograph is end-to-end encrypted; its index is not,
because the server sorts and searches it — so publishing coordinates hands Neutrino a list of where
somebody has been, next to a library it otherwise cannot open. That is a real trade and it belongs
to the user, so `Settings › Privacy › Include location in cloud metadata` defaults to **off**.
Nothing is lost locally either way: the coordinates are extracted and kept in `LocalStore`, the Info
sheet shows them, and a refresh merges them back over a listing that came home without them. What
publishing buys is the same location on the user's other devices, and the Places view and map search
that will read `GET /api/v1/photos/map`.

### Capture dates

`timelineDate` is `captureDate ?? createdAt`, and every grouping and sort in the app goes through
it — a photograph taken in 2019 and uploaded today belongs in 2019. The capture date is read from
EXIF `DateTimeOriginal` at import and sent as `%Y-%m-%dT%H:%M:%S`, which is *exactly* what
`chrono::NaiveDateTime::parse_from_str` accepts on the server; an ISO 8601 string with a zone or a
fraction fails to parse there and the photograph silently files itself under its upload time.

Grouping happens in the device's calendar rather than UTC, so a picture taken at 11pm stays on the
evening the photographer remembers.

### Originals are stored as they came

The bytes go up at the resolution and in the format the camera wrote them — a backup that silently
re-compressed everything is not one anybody can migrate out of. HEIC is the single exception: it is
converted to JPEG at full resolution, because most browsers cannot display it and the same file is
read by the web app.

That is affordable only because of the other end: `MediaContentService` decodes through ImageIO at a
bounded size rather than through `UIImage(data:)`, which would hold about 48 MB of bitmap for a
12-megapixel photograph. Downscaling before upload throws pixels away for good; downsampling at
decode only declines to hold them.

### Three sizes of a photograph

| | Longest edge | Stored | Drawn by |
|---|---|---|---|
| Thumbnail | 512 px | **plaintext**, on the Drive file | the grid |
| Preview | 2048 px | **encrypted**, as a second Drive file | the viewer |
| Original | as the camera wrote it | **encrypted**, the Drive file itself | zoom, export, save-back |

Only the thumbnail is in the clear, and only because a grid has to draw before any key is imported
and from one listing response rather than a thousand downloads. It is small enough to be a contact
sheet and too small to be the photograph. Everything above it *is* the photograph, and is encrypted
like one.

The preview earns its place at the other end. Opening one picture otherwise means fetching a 4 MB
original to fill a screen that holds about 400 KB of it; the preview costs a tenth of the original
once and saves the other nine tenths every time the item is opened, on any device. It is generated
on the uploading device because nowhere else can — the server holds ciphertext and has no key — and
filed in a `Photo Previews` subfolder, since both library listings are root-scoped and a rendition
in the root would show up as a duplicate photograph in the web app.

Nothing in the ladder is load-bearing. A photograph with no preview rendition opens its original and
makes one locally; a file with no cover thumbnail draws a symbol; a preview that has been deleted in
Drive falls through to the original with a line in the log. And a preview is only made when it would
actually be smaller than the picture it is a preview of — a screenshot or a web graphic gets none,
by the same rule on both the upload side and the fallback.

Finding a rendition is the one awkward part: nothing on a photo record can hold its file id, so the
*name* is the index (`<originalFileID>.preview.jpg`). The uploading device knows the mapping
immediately; every other one learns it by listing the folder once at launch and keeping the result
in `LocalStore`.

### What is kept on this device

Three things, and they are cleared by different buttons for different reasons.

**Decrypted media** — originals and videos — sits in a capped `DiskCache` under `Library/Caches`,
evicted least recently used. It is decrypted, which is a trade rather than an oversight: it carries
`.completeUntilFirstUserAuthentication` file protection, the same accessibility class as the key that
produced it, is excluded from iCloud backup, and is emptied from Settings. The alternative —
re-downloading and re-decrypting a 4 GB video on every play — is not one a phone can afford. LRU is
implemented as a modification date, stamped on read, because iOS does not reliably update access
dates and an in-memory recency list is empty exactly when the cache is fullest.

**Grid thumbnails** get the same treatment plus an `NSCache` of decoded bitmaps on top, which empties
itself under memory pressure. What that tier saves is the decode, not the download.

**The library index** is SQLite (`LocalStore`), in Application Support rather than Caches — the system
may empty Caches at any moment, and a timeline that occasionally forgets everything is worse than one
that never cached. It holds the photo records and the rendition index, migrates off `user_version`,
and answers the timeline with one query against `photo(is_trashed, is_archived, timeline_date DESC)`
— stored rather than computed, because an expression cannot lead an index and a 100,000-row sort is
the thing being avoided. `PhotoLibraryService` paints from it before the network is asked anything,
then replaces it with whatever the listing says.

That is a cache, not offline mode. There is no cursor, no tombstone, no conflict rule, and no queue
for changes made with no signal — those are Epic 10's, and half of them would be worse than none.

### Import is serial, and a video is never held

An original is in memory twice while it is in flight — plaintext and ciphertext — so importing five
48-megapixel photographs in parallel is how a phone gets killed. One at a time also gives honest
progress: "3 of 40", with a byte count for the item actually moving.

A video is not held at all. The picker hands over a file URL rather than `Data`, `MediaCrypto`
encrypts it a chunk at a time into a temporary file, the multipart body copies that through a fixed
buffer, and `URLSession` streams the result off disk — so peak memory is a couple of megabytes
whether the clip is 30 seconds or 20 minutes. Coming back the other way, anything over 32 MB spools
to disk and decrypts there.

The one thing that has to travel with a chunked file is its framing: `[header][chunk][chunk]…` and a
single push of the same bytes are indistinguishable, and guessing wrong fails authentication rather
than reading short. So the chunk size is written into the file's *encrypted metadata*, and a
streaming download reads that before it decrypts anything. It also means a chunked file is not
readable by today's web client — which is why the chunking threshold sits at 64 MB, above every
photograph and below every video. Pictures stay interoperable; videos stay openable.

### Moving a whole library across

There are two ways in — the picker, and a full-library run — and they share everything below the
point where the bytes come from. `MediaImportPipeline` is that shared part: de-duplicate, upload,
register, then the best-effort tail of favourite flag, Live Photo motion, and metadata. Two copies
of it would have diverged into a photograph that arrives with its EXIF on one route and without it
on the other.

The full run is a **scan** and a **queue**. The scan walks `PHAsset.fetchAssets` on a detached task —
fifty thousand assets is tens of thousands of trips across the Photos XPC boundary, and doing that
on the main actor means the count it is reporting never draws — and writes what it finds into a
SQLite table, newest first, with each item's album titles on its row. The run takes one row at a
time, and writes the outcome back before starting the next.

That last sentence is the whole design. Being killed mid-import costs at most the item in flight,
and that one is still `pending`, so the next launch finds pending rows, says the import was
interrupted, and offers to carry on. Pause is the same mechanism with a button on it.

**Running it twice adds nothing**, which is the property the epic is actually judged on.
`ImportLedger` is the one record both importers consult, keyed two ways because neither is enough on
its own:

| Key | Catches | Misses |
|---|---|---|
| `PHAsset.localIdentifier` | the same asset, re-encoded or re-rendered; known *before* any bytes are read | items with no asset — a picker import with no library access; another device's copy |
| SHA-256 of the uploaded bytes | the same picture arriving from anywhere | the same picture re-encoded |

The identifier is what makes a re-scan cheap: forty-nine thousand of fifty thousand assets are
skipped without touching the disk. The hash costs a read, so it is checked once per item actually
being imported. Both live in the local database — the server holds ciphertext and cannot compare two
uploads for sameness — and both go when you sign out, because the next account on this device has
none of these photographs.

**Progress is measured in bytes**, since a library is mostly photographs by count and mostly video
by size, and an item-counting bar sits at 99% through the part that takes longest. Those bytes are
estimated from each item's dimensions and duration: the Photos framework does not publish a
resource's file size, and this app will not read the private `fileSize` key to draw a bar. That is
sound because the estimate and the measured throughput are in the *same units*, so a systematic bias
cancels out of both the fraction and the ETA. The ETA also excludes paused time — a run resumed the
next morning would otherwise tell somebody with ten items left that they had four days to wait — and
says nothing at all for the first few seconds, because a wildly wrong first estimate is the number
people plan around.

**Three things can stop a run, and they are treated differently.** No network or an overheating
phone *hold*, with an explanation, and clear themselves. A merely warm phone is not a stop at all,
just a pause between items — sustained import is exactly the workload that drives a phone into
throttling, and doing less per minute is the fix. Running out of storage stops the run outright,
because polling would be a spinner over a message somebody has to act on.

**A failing item never stalls the queue.** A failure is recorded on its row and the run moves on; at
the end of a pass, everything under three attempts goes back in the queue, so a poison item is
retried *around* the rest of the library rather than in front of it. After that it waits in a failed
list with its error, and there is a Retry button.

What this is *not* is background upload: the run needs the app in the foreground, and
`beginBackgroundTask` buys only the seconds after a home-press so the item in flight can finish.
Uploading with the app closed needs a background `URLSession` and is `FeatureFlags.automaticBackup`.

## Known Gaps

**Albums cannot be opened.** The server has `GET /api/v1/albums` and `GET /api/v1/albums/{id}`, but
neither returns the album's items and there is no `/items` listing. So this app lists albums,
creates, renames, and deletes them, and adds photographs to them from the viewer — and says on the
screen why a card does not open. `AlbumService.photos(in:)` is the one place that changes when the
endpoint lands, and a test asserts the gap so it fails the day it closes.

**Passkey unlock is written but unproven.** `PasskeyPRFAuthenticator` performs the WebAuthn PRF
assertion on iOS 18+, and `webcredentials:` is in the entitlement. iOS still will not hand this app a
passkey registered at `www.getneutrino.app` until that domain's `apple-app-site-association` names
`com.neutrino.photos` under a `webcredentials` section — a file in the server repository, which today
carries `applinks` only. Until it does, the assertion fails with a domain error and the unlock screen
falls back to the password, which is why a passkey is offered beside the other methods and never
instead of them.

**No automatic backup.** A whole camera roll can now be moved across in one resumable run, but
somebody has to start it and leave the app open. Nothing watches for *new* photographs: there is no
`PHPhotoLibraryChangeObserver`, no background `URLSession`, and no `BGTaskScheduler` registration,
so a picture taken with the Camera app sits there until the next import. That is
`FeatureFlags.automaticBackup`, and it is `false`.

**Album structure survives only as far as Drive can express it.** Neutrino albums are a flat list of
titles containing photographs, so that is what a full import recreates — matched by title, created
if absent. Nested folders, an album's own ordering, and smart albums have nowhere to go. Smart
albums are skipped deliberately rather than for want of an endpoint: "Recently Added", "Selfies",
and "Screenshots" are views over the library, and copies of them would be albums that never update
again. Hidden items are never imported at all.

**Live Photos and RAW are stored, not rendered.** A Live Photo's paired video is uploaded, indexed,
and restorable to Apple Photos as a Live Photo; the viewer does not play it in place, and the grid
draws a badge rather than a press-and-hold. A DNG is stored as the camera wrote it and opens through
ImageIO like any other picture. Rendering both properly — along with bursts and panoramas, which are
detected and recorded now — is v1.1's Epic 16.

**No offline mode.** The device's copy of the library is a cache, not a replica. A cold launch with
no signal draws the timeline it drew last time and opens anything still in the media cache — but a
favourite toggled with no network is lost when the request fails, a delete made on another device is
invisible until the next listing, and there is no cursor to ask "what changed". `FeatureFlags.offlineMode`
stays `false` until Epic 10 adds the sync engine and the queue behind it.

**Preview renditions are ours alone.** The `Photo Previews` folder is a Drive folder like any other
and today's web client neither writes nor reads it. It ignores it — the folder is outside the
root-scoped listing the web library uses — but somebody browsing Drive will see it. Deleting it
costs nothing: every rendition is re-derivable from its original, and every read falls back.

## Testing

```bash
xcodebuild test -project NeutrinoPhotos.xcodeproj -scheme NeutrinoPhotos \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
```

362 tests. HTTP is exercised end to end against `MockURLProtocol` — real requests, real decoding, real
status handling — rather than behind a protocol seam. The crypto is *not* mocked: `TestKeys` installs
a genuine X25519 pair, so the seal / unseal / secretstream round trip is asserted for what it is.
The caches and the database are real too, in a temporary directory per test — a cache that is stubbed
out cannot be shown to serve a second read, which is the only thing a cache is for. Nor is the image
data: `TestImages.jpegWithMetadata` writes real EXIF, TIFF, and GPS blocks with
`CGImageDestination`, because a hand-built dictionary would assert only that ImageIO can round-trip
a `CFDictionary` — and the hemisphere-ref bug that puts Santiago in Boston shows up only against a
real APP1 segment.

`PHAsset` cannot be constructed and a simulator has no camera roll, so nothing downstream of the
Photos framework is tested through it. That is what `DeviceAsset` and `ScannedAsset` are for: plain
values holding everything the importers need from an asset, so the extraction, merging, redaction,
publishing, and size estimation are all assertable without a photo library. `DevicePhotoLibrary`
itself is covered for what it *decides* — the authorization mapping, and that constructing it
prompts for nothing, which is the one thing that would otherwise put a permission alert in front of
every user on first launch.

The import queue is tested against a real SQLite file rather than a stub, because the property under
test is that a *process* can die between two items and lose nothing: a store is written, a second
one is opened over the same path with nothing closed politely, and it has to resume at the right row
rather than at the top. The ETA and the throughput are driven by explicit `Date`s, which is what
makes "an eight-hour pause must not change the estimate" a test that runs in a millisecond.

The pipeline's own assertion is that an uploaded original comes back byte for byte: the bytes go out
through the multipart upload, are pulled back out of the captured request body exactly as the server
would have stored them, are served back through the download path, and are hashed at the far end. A
test that encrypted and decrypted in place would pass with a mangled multipart body, which is the
failure that one is for.

The vault tests go one step further and assert against the *other* implementation. `WebVault` holds a
key vault produced by the web client's own `hash-wasm` and `libsodium-wrappers` over fixed inputs, and
the tests unlock it here. A round trip through this app alone would pass just as happily with both
halves wrong in the same direction — and the failure that matters is an account that unlocks in the
browser and not on the phone. If one of those assertions fails, regenerate the fixture from
`web/packages/e2e-crypto`; do not edit the constants.

## Deployment

```bash
scripts/deploy_testflight.sh              # bump the build number, test, archive, upload
scripts/deploy_testflight.sh 3 1.1.0      # build 3, marketing version 1.1.0
scripts/deploy_testflight.sh --no-upload  # archive and export only
```

Credentials come from the environment or `scripts/.env` (gitignored) — see `scripts/.env.example`.
`project.yml` is the source of truth for the version numbers; the script edits it there and
regenerates the project, so remember to commit the bump.

## Roadmap

`agent_docs/mvp.md` holds the full feature list and phasing. Settings > About > What's not here yet
renders the same status from `FeatureFlags`, so the app and this document cannot drift apart.
