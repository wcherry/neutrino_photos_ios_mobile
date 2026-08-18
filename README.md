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

Sign in with a Neutrino account, then import the account's encryption key (Settings > Encryption, or
the banner on the library). The key file is the JSON the web app exports from its own
Settings > Encryption page.

## What This Build Does

| Area | Features | Status |
|------|----------|--------|
| Authentication | OAuth PKCE login, token refresh, device registration, sign out | COMPLETE |
| Encryption | Key import (file or paste), Keychain storage, per-file key sealing and unsealing | COMPLETE |
| Timeline | Grid grouped by day / month / year, capture-date ordering, pull to refresh | COMPLETE |
| Viewer | Full screen, pinch and double-tap zoom, swipe between items, info panel | COMPLETE |
| Video | Playback of the decrypted original | COMPLETE |
| Import | Multi-select from the system picker, HEIC→JPEG, EXIF capture date, thumbnail, upload progress, cancel, duplicate skip | COMPLETE |
| Favorites / Archive / Trash | Star, archive, delete, restore, empty | COMPLETE |
| Albums | List, create, rename, delete, add a photo | PARTIAL — see below |
| Settings | Grouping, appearance, Wi-Fi-only uploads, cache, device name, roadmap | COMPLETE |

`FeatureFlags` is the honest list of what is *not* here yet: automatic backup, offline browsing,
search, places, people, memories, editing, sharing, and Universal Links. Each is a flag set to
`false` rather than a half-built screen.

## Architecture

```
NeutrinoPhotosApp        composition root — every service constructed once, injected explicitly
├── APIClient            all authorized HTTP: token refresh, status checks, JSON, uploads
├── AuthService          OAuth PKCE (login → authorize → token), refresh, logout
├── PhotoLibraryService  /api/v1/photos — the library, favorites, archive, trash, registration
├── AlbumService         /api/v1/albums
├── MediaContentService  download + decrypt an original; encrypt + upload a new one
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

### Import is serial

An original is in memory twice while it is in flight — plaintext and ciphertext — so importing five
48-megapixel photographs in parallel is how a phone gets killed. One at a time also gives honest
progress: "3 of 40", with a byte count for the item actually moving.

Duplicate detection is a SHA-256 of the prepared bytes, kept on the device. It has to be local: the
server stores ciphertext and cannot compare two uploads for sameness. It catches the common case —
the same photographs picked twice — and Settings can forget the record.

## Known Gaps

**Albums cannot be opened.** The server has `GET /api/v1/albums` and `GET /api/v1/albums/{id}`, but
neither returns the album's items and there is no `/items` listing. So this app lists albums,
creates, renames, and deletes them, and adds photographs to them from the viewer — and says on the
screen why a card does not open. `AlbumService.photos(in:)` is the one place that changes when the
endpoint lands, and a test asserts the gap so it fails the day it closes.

**No automatic backup.** `PhotosPicker` selects out of process, which is why the app needs no
photo-library permission and never sees the rest of the roll. Watching for new photographs needs
`PHPhotoLibrary`, its permission prompt, and `BGTaskScheduler` — that is `FeatureFlags.automaticBackup`.

**No offline mode.** Listings and thumbnails are fetched per launch; nothing is cached but decrypted
videos, which live in the temporary directory and are cleared from Settings.

## Testing

```bash
xcodebuild test -project NeutrinoPhotos.xcodeproj -scheme NeutrinoPhotos \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro,OS=latest"
```

79 tests. HTTP is exercised end to end against `MockURLProtocol` — real requests, real decoding, real
status handling — rather than behind a protocol seam. The crypto is *not* mocked: `TestKeys` installs
a genuine X25519 pair, so the seal / unseal / secretstream round trip is asserted for what it is.

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
