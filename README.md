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
| Timeline | Grid grouped by day / month / year, capture-date ordering, pull to refresh, drawn from the local index before the network answers | COMPLETE |
| Viewer | Full screen, pinch and double-tap zoom, swipe between items, info panel | COMPLETE |
| Video | Playback of the decrypted original, streamed to disk rather than held | COMPLETE |
| Import | Multi-select from the system picker, HEIC→JPEG, EXIF capture date, thumbnail, upload progress, cancel, duplicate skip | COMPLETE |
| Media pipeline | Rendition ladder, encrypted preview beside each original, capped and evicted caches of decrypted media, SQLite library index | COMPLETE |
| Favorites / Archive / Trash | Star, archive, delete, restore, empty | COMPLETE |
| Albums | List, create, rename, delete, add a photo | PARTIAL — see below |
| Settings | Account, grouping, appearance, Wi-Fi-only uploads, storage breakdown, cache, device name, roadmap | COMPLETE |

The shell is four tabs — Library, Albums, Search, Settings — and keeps that shape in every build.
Search has no index behind it yet and says so; a tab that appeared when a flag flipped would move
the other three under the user's thumb.

`FeatureFlags` is the honest list of what is *not* here yet: automatic backup, offline mode, search,
places, people, memories, editing, sharing, and Universal Links. Each is a flag set to `false`
rather than a half-built screen.

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
├── LocalStore           SQLite — the timeline before the network answers, and the rendition index
├── PhotoImportService   picker → prepare → upload → register, one item at a time
├── NetworkMonitor       connectivity and whether the path is metered
└── AppSettings          preferences, in UserDefaults
```

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

Duplicate detection is a SHA-256 of the prepared bytes, kept on the device (hashed a block at a time
for a video, for the same reason as everything else here). It has to be local: the server stores
ciphertext and cannot compare two uploads for sameness. It catches the common case — the same
photographs picked twice — and Settings can forget the record.

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

**No automatic backup.** `PhotosPicker` selects out of process, which is why the app needs no
photo-library permission and never sees the rest of the roll. Watching for new photographs needs
`PHPhotoLibrary`, its permission prompt, and `BGTaskScheduler` — that is `FeatureFlags.automaticBackup`.

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

219 tests. HTTP is exercised end to end against `MockURLProtocol` — real requests, real decoding, real
status handling — rather than behind a protocol seam. The crypto is *not* mocked: `TestKeys` installs
a genuine X25519 pair, so the seal / unseal / secretstream round trip is asserted for what it is.
The caches and the database are real too, in a temporary directory per test — a cache that is stubbed
out cannot be shown to serve a second read, which is the only thing a cache is for.

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
