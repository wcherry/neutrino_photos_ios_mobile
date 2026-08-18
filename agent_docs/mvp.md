# Neutrino Photos — iOS Feature List & Roadmap

## 1. Product Vision

Neutrino Photos should be a full-featured photo and video library for iPhone and iPad combining:

- The polished, device-integrated experience of **Apple Photos**
- The search, organization, sharing, and AI capabilities of **Google Photos**
- Neutrino's existing **Drive infrastructure**
- End-to-end encrypted, privacy-first storage
- A cloud library that isn't locked to Apple's ecosystem
- Excellent offline support
- Seamless integration with the Neutrino ecosystem

The goal is not simply to build a photo viewer. Neutrino Photos should become the user's **primary photo library and backup system**.

---

# 2. Core Feature Areas

## A. Photo & Video Library

### Timeline

- [ ] Chronological photo timeline
- [ ] Group photos by day
- [ ] Group photos by month
- [ ] Group photos by year
- [ ] Timeline scrubbing
- [ ] Fast scrolling through large libraries
- [ ] Pinch-to-zoom timeline density
- [ ] Favorites
- [ ] Recently Added
- [ ] Recently Edited
- [ ] Hidden items
- [ ] Recently Deleted
- [ ] Screenshots
- [ ] Screen recordings
- [ ] Live Photos
- [ ] Videos
- [ ] RAW photos
- [ ] Burst photos
- [ ] Panoramas
- [ ] Portrait photos
- [ ] Slow-motion videos
- [ ] Time-lapse videos

### Library Views

- [ ] Photos
- [ ] Albums
- [ ] Favorites
- [ ] People
- [ ] Places
- [ ] Map
- [ ] Memories
- [ ] Shared
- [ ] Videos
- [ ] Recently Added
- [ ] Recently Deleted

---

# 3. Import & Camera Roll Integration

## iOS Photos Integration

- [ ] Request Photos library permissions
- [ ] Import existing Apple Photos library
- [ ] Import selected photos
- [ ] Import entire library
- [ ] Incremental import
- [ ] Detect previously imported photos
- [ ] Preserve original creation dates
- [ ] Preserve GPS metadata
- [ ] Preserve camera metadata
- [ ] Preserve Live Photos
- [ ] Preserve albums where possible
- [ ] Preserve favorite status
- [ ] Preserve edits where possible
- [ ] Detect duplicates
- [ ] Import RAW files
- [ ] Import videos
- [ ] Background import
- [ ] Import progress
- [ ] Pause/resume import
- [ ] Retry failed imports

## Automatic Backup

- [ ] Automatically back up new photos
- [ ] Automatically back up new videos
- [ ] Background upload
- [ ] Wi-Fi-only option
- [ ] Cellular upload option
- [ ] Charging-only option
- [ ] Low-power behavior
- [ ] Upload queue
- [ ] Retry failed uploads
- [ ] Upload status
- [ ] Per-item upload status
- [ ] Backup history

---

# 4. Cloud Storage

Neutrino Photos should use **Neutrino Drive** as its underlying storage layer.

### Storage

- [ ] Original-quality storage
- [ ] Optimized storage
- [ ] Thumbnail generation
- [ ] Multiple image resolutions
- [ ] Video transcoding
- [ ] Streaming video
- [ ] Progressive downloads
- [ ] Offline originals
- [ ] Offline optimized copies
- [ ] Storage usage dashboard

### Encryption

- [ ] End-to-end encryption
- [ ] Client-side encryption keys
- [ ] Encrypted thumbnails
- [ ] Encrypted originals
- [ ] Encrypted metadata
- [ ] Secure key storage in iOS Keychain
- [ ] Key backup/recovery
- [ ] Device authorization
- [ ] Key rotation
- [ ] Multi-device key synchronization
- [ ] Recovery workflow

Privacy should be a first-class feature rather than an optional setting.

---

# 5. Search

Search should eventually be one of Neutrino Photos' strongest features.

## Basic Search

- [ ] Filename
- [ ] Date
- [ ] Month
- [ ] Year
- [ ] Location
- [ ] Album
- [ ] Favorite
- [ ] Media type
- [ ] Camera
- [ ] Lens
- [ ] File type

## Semantic Search

- [ ] Search for objects
- [ ] Search for animals
- [ ] Search for food
- [ ] Search for vehicles
- [ ] Search for buildings
- [ ] Search for landscapes
- [ ] Search for activities
- [ ] Search for events
- [ ] Search by visual similarity

Examples:

> "dogs"

> "beach"

> "photos of cars"

> "pictures from Disneyland"

> "sunsets"

> "photos of John at the beach"

## Face Recognition

- [ ] Detect faces
- [ ] Cluster faces
- [ ] User names
- [ ] Rename people
- [ ] Merge people
- [ ] Separate incorrectly merged people
- [ ] Search by person
- [ ] People timeline
- [ ] People albums

Prefer running face processing **locally on the device or through an explicitly privacy-preserving Neutrino processing pipeline**.

---

# 6. Places & Maps

- [ ] GPS metadata extraction
- [ ] Location clustering
- [ ] Location search
- [ ] Places view
- [ ] Interactive map
- [ ] Photos displayed on map
- [ ] Location timeline
- [ ] Search by city
- [ ] Search by country
- [ ] Search by landmark
- [ ] Correct photo location
- [ ] Remove location metadata
- [ ] Privacy controls for location

Example:

**California → Yosemite → 142 photos**

---

# 7. Albums

## Manual Albums

- [ ] Create album
- [ ] Rename album
- [ ] Delete album
- [ ] Add photos
- [ ] Remove photos
- [ ] Reorder photos
- [ ] Album cover
- [ ] Album description

## Smart Albums

- [ ] Date-based albums
- [ ] Location-based albums
- [ ] Person-based albums
- [ ] Object-based albums
- [ ] Favorite-based albums
- [ ] Search-based albums
- [ ] Automatically updated albums

Example:

**"California Trips"**

Automatically includes photos matching:

- California
- Trips
- 2024–2026

---

# 8. Memories

Create automatic collections similar to Apple Photos Memories and Google Photos.

- [ ] This Day
- [ ] This Week
- [ ] Years Ago
- [ ] Trips
- [ ] Events
- [ ] People
- [ ] Places
- [ ] Seasonal memories
- [ ] Best photos
- [ ] Recent highlights

### Memory Presentation

- [ ] Full-screen slideshow
- [ ] Automatic music
- [ ] Transitions
- [ ] Titles
- [ ] Captions
- [ ] Automatically generated story
- [ ] Edit memory
- [ ] Add/remove photos
- [ ] Change music
- [ ] Share memory

---

# 9. Editing

## Basic Editing

- [ ] Crop
- [ ] Rotate
- [ ] Flip
- [ ] Straighten
- [ ] Perspective correction
- [ ] Exposure
- [ ] Brightness
- [ ] Contrast
- [ ] Highlights
- [ ] Shadows
- [ ] Saturation
- [ ] Vibrance
- [ ] Temperature
- [ ] Tint
- [ ] Sharpness
- [ ] Definition
- [ ] Noise reduction
- [ ] Vignette

## Filters

- [ ] Presets
- [ ] Adjustable filter intensity
- [ ] Custom presets
- [ ] Save editing presets

## Advanced Editing

- [ ] Selective adjustments
- [ ] Brush adjustments
- [ ] Blur
- [ ] Background blur
- [ ] Red-eye removal
- [ ] Object removal
- [ ] Background removal
- [ ] AI enhancement
- [ ] Upscaling

## Non-Destructive Editing

Every edit should preserve the original.

- [ ] Store edit instructions
- [ ] Revert edits
- [ ] Compare original
- [ ] Edit history
- [ ] Re-edit from original

---

# 10. AI Features

AI should be introduced progressively.

### AI Organization

- [ ] Object recognition
- [ ] Scene recognition
- [ ] Face recognition
- [ ] Landmark recognition
- [ ] Text recognition
- [ ] Document recognition
- [ ] Screenshot detection
- [ ] Receipt detection
- [ ] Pet detection

### AI Search

- [ ] Natural-language search
- [ ] Semantic image search
- [ ] Combined text + visual search
- [ ] Search suggestions

### AI Editing

- [ ] Remove objects
- [ ] Remove distractions
- [ ] Enhance photo
- [ ] Improve lighting
- [ ] Blur background
- [ ] Best-shot selection

### AI Assistance

- [ ] Automatic captions
- [ ] Photo descriptions
- [ ] Album descriptions
- [ ] Memory generation
- [ ] Duplicate detection
- [ ] Similar-photo detection
- [ ] Best-photo selection

---

# 11. Duplicate & Photo Cleanup

- [ ] Exact duplicate detection
- [ ] Near-duplicate detection
- [ ] Similar photo detection
- [ ] Screenshots cleanup
- [ ] Blurry photo detection
- [ ] Bad exposure detection
- [ ] Large video identification
- [ ] Unused photo identification

### Cleanup Assistant

Show:

> **Free up 3.8 GB**

- 412 duplicate photos
- 128 screenshots
- 43 blurry photos
- 17 large videos

Allow the user to review before deletion.

---

# 12. Sharing

## Basic Sharing

- [ ] Share individual photo
- [ ] Share multiple photos
- [ ] Share videos
- [ ] Share albums
- [ ] Share memories

## Neutrino Sharing

- [ ] Shared albums
- [ ] Shared libraries
- [ ] Invite users
- [ ] View-only access
- [ ] Contributor access
- [ ] Download permissions
- [ ] Expiring links
- [ ] Password-protected links

## Collaborative Albums

- [ ] Multiple contributors
- [ ] Add photos
- [ ] Comments
- [ ] Likes/favorites
- [ ] Notifications
- [ ] Album owner controls

---

# 13. Metadata

Display and edit:

- [ ] Date/time
- [ ] Location
- [ ] Camera
- [ ] Lens
- [ ] Exposure
- [ ] ISO
- [ ] Aperture
- [ ] Focal length
- [ ] File size
- [ ] Resolution
- [ ] MIME type
- [ ] Filename

### Metadata Editing

- [ ] Change date
- [ ] Change time
- [ ] Change location
- [ ] Remove location
- [ ] Edit title
- [ ] Add caption
- [ ] Add keywords

---

# 14. iOS Integration

- [ ] Photos framework integration
- [ ] Share Sheet
- [ ] Files integration
- [ ] Document Picker
- [ ] Widgets
- [ ] Live Activities where appropriate
- [ ] Background processing
- [ ] Background uploads
- [ ] Spotlight indexing
- [ ] Siri/App Intents
- [ ] Shortcuts
- [ ] Quick Actions
- [ ] iPad multitasking
- [ ] iPad keyboard shortcuts
- [ ] External display support

### App Intents

Examples:

> "Show my photos from Yosemite."

> "Back up my photos."

> "Show photos of my dog."

> "Create an album from my vacation photos."

---

# 15. Offline Support

Neutrino Photos should remain useful without an internet connection.

- [ ] Offline browsing
- [ ] Offline search of indexed content
- [ ] Offline albums
- [ ] Offline editing
- [ ] Upload queue
- [ ] Download queue
- [ ] Automatic synchronization
- [ ] Conflict resolution
- [ ] Network-aware synchronization

---

# 16. Sync Architecture

The application should use an asynchronous synchronization model.

### Local

iOS maintains:

- Photo database
- Thumbnail cache
- Metadata index
- Search index
- Pending uploads
- Pending downloads
- Pending edits

### Cloud

Neutrino maintains:

- Original files
- Derived images
- Videos
- Encrypted metadata
- Albums
- Sharing information
- Search/indexing information where privacy architecture permits

### Sync

- [ ] Incremental synchronization
- [ ] Delta updates
- [ ] Upload queue
- [ ] Download queue
- [ ] Retry handling
- [ ] Conflict detection
- [ ] Conflict resolution
- [ ] Multi-device synchronization
- [ ] Device synchronization status

---

# 17. Settings

### Backup

- [ ] Backup enabled/disabled
- [ ] Wi-Fi only
- [ ] Cellular backup
- [ ] Charging-only backup
- [ ] Original vs optimized
- [ ] Video backup settings

### Privacy

- [ ] Face recognition
- [ ] AI processing
- [ ] Location processing
- [ ] Metadata sharing
- [ ] Analytics
- [ ] Encryption status

### Storage

- [ ] Cloud usage
- [ ] Local cache usage
- [ ] Offline storage
- [ ] Clear cache
- [ ] Storage optimization

### Account

- [ ] Neutrino account
- [ ] Devices
- [ ] Encryption keys
- [ ] Sessions
- [ ] Storage plan

---

# 18. Roadmap

## Phase 0 — Architecture & Foundation

**Goal:** Establish the technical foundation.

- [ ] Define Photos data model
- [ ] Define Drive integration
- [ ] Define encryption architecture
- [ ] Define synchronization protocol
- [ ] Define local database
- [ ] Define thumbnail architecture
- [ ] Define media processing pipeline
- [ ] Define background task architecture
- [ ] Define upload/download queues
- [ ] Define key management
- [ ] Define error/retry architecture
- [ ] Create SwiftUI application shell
- [ ] Integrate Neutrino authentication
- [ ] Integrate Neutrino Drive

**Milestone:** App can authenticate and communicate with Neutrino infrastructure.

---

# Phase 1 — MVP Photo Library

**Goal:** Build a usable private photo backup application.

### Library

- [ ] Photos timeline
- [ ] Photo grid
- [ ] Full-screen viewer
- [ ] Zoom
- [ ] Swipe navigation
- [ ] Videos
- [ ] Favorites
- [ ] Albums

### Import

- [ ] iOS Photos access
- [ ] Selective import
- [ ] Full-library import
- [ ] Duplicate detection
- [ ] Background upload
- [ ] Upload queue
- [ ] Upload progress

### Cloud

- [ ] Original uploads
- [ ] Thumbnail generation
- [ ] Cloud storage
- [ ] Download
- [ ] Basic synchronization

### Security

- [ ] E2E encryption
- [ ] Keychain integration
- [ ] Device key registration

**Milestone:** User can install Neutrino Photos, authenticate, import their library, securely back it up, and browse it from the cloud.

---

# Phase 2 — Complete Photo Library

**Goal:** Reach parity with the fundamental Apple Photos experience.

- [ ] Timeline improvements
- [ ] Months/years navigation
- [ ] Recently Added
- [ ] Recently Deleted
- [ ] Hidden photos
- [ ] Screenshots
- [ ] Videos
- [ ] RAW
- [ ] Live Photos
- [ ] Burst photos
- [ ] Metadata viewer
- [ ] Metadata editing
- [ ] Map view
- [ ] Places
- [ ] Favorites
- [ ] Smart albums
- [ ] Offline mode

**Milestone:** Neutrino Photos becomes a legitimate daily photo-library replacement.

---

# Phase 3 — Editing

**Goal:** Match the essential Apple Photos editing experience.

- [ ] Crop
- [ ] Rotate
- [ ] Straighten
- [ ] Exposure
- [ ] Color adjustments
- [ ] Filters
- [ ] Video trimming
- [ ] Non-destructive editing
- [ ] Revert edits
- [ ] Compare original
- [ ] Edit history

Then add:

- [ ] Object removal
- [ ] Background blur
- [ ] AI enhancement

**Milestone:** Users can perform their normal photo-editing workflow without leaving Neutrino Photos.

---

# Phase 4 — Search & Organization

**Goal:** Match Google Photos' organizational capabilities.

- [ ] Full-text metadata search
- [ ] Date search
- [ ] Location search
- [ ] Object recognition
- [ ] Face detection
- [ ] People clusters
- [ ] Named people
- [ ] Semantic search
- [ ] Similar-photo search
- [ ] Smart albums
- [ ] Duplicate detection

**Milestone:** Users can reliably find photos without manually organizing them.

---

# Phase 5 — Memories & AI

**Goal:** Turn the library into an intelligent photo experience.

- [ ] Memories
- [ ] Automatic collections
- [ ] Trips
- [ ] Events
- [ ] People memories
- [ ] This Day
- [ ] Best photos
- [ ] AI captions
- [ ] Natural-language search
- [ ] AI photo descriptions
- [ ] AI cleanup
- [ ] AI editing

**Milestone:** Neutrino Photos proactively helps users discover and manage their library.

---

# Phase 6 — Sharing

**Goal:** Build a complete alternative to Apple/Google photo sharing.

- [ ] Shared albums
- [ ] Collaborative albums
- [ ] Invitations
- [ ] Comments
- [ ] Likes
- [ ] Shared links
- [ ] Expiring links
- [ ] Password-protected links
- [ ] Permissions
- [ ] Family/shared libraries

**Milestone:** Users can share their photos entirely through Neutrino.

---

# Phase 7 — Multi-Device Neutrino Ecosystem

**Goal:** Make Neutrino Photos significantly better than a standalone iOS photo app.

### Neutrino Web

- [ ] Full web photo library
- [ ] Search
- [ ] Albums
- [ ] Editing
- [ ] Sharing

### Neutrino Desktop

- [ ] Desktop photo library
- [ ] Automatic backup
- [ ] Local library synchronization
- [ ] Bulk management

### Neutrino Drive

- [ ] Photos stored as Drive objects
- [ ] Browse photos through Drive
- [ ] Open photos from Drive
- [ ] Move/import photos between Drive folders
- [ ] Photo metadata integration

### Neutrino Docs/Other Apps

- [ ] Insert photos into documents
- [ ] Insert photos into presentations
- [ ] Insert photos into spreadsheets
- [ ] Photo picker shared across Neutrino applications

**Milestone:** Photos becomes a core Neutrino service rather than an isolated application.

---

# Phase 8 — Advanced AI & Power Features

These should come after the fundamentals are extremely reliable.

- [ ] Advanced semantic search
- [ ] Natural-language photo queries
- [ ] AI-generated albums
- [ ] AI-generated memories
- [ ] Automatic best-shot selection
- [ ] Advanced object removal
- [ ] Generative editing
- [ ] Photo restoration
- [ ] Upscaling
- [ ] Automatic color correction
- [ ] Duplicate/similarity clustering
- [ ] Document detection
- [ ] Receipt detection
- [ ] Screenshot intelligence
- [ ] Advanced family organization

---

# 19. Recommended MVP Scope

I would **not** try to build all of Google Photos and Apple Photos initially.

The first production MVP should contain:

### Must Have

1. Neutrino authentication
2. E2E encryption
3. iOS Photos integration
4. Full-library import
5. Automatic backup
6. Background uploads
7. Photo timeline
8. Photo viewer
9. Albums
10. Favorites
11. Videos
12. Search by date
13. Search by filename/metadata
14. Thumbnail generation
15. Cloud synchronization
16. Offline browsing
17. Recently Deleted
18. Storage management
19. Basic metadata
20. Basic sharing

### Version 1.1

- [ ] Maps
- [ ] Places
- [ ] Smart albums
- [ ] Duplicate detection
- [ ] Basic editing
- [ ] Live Photos
- [ ] RAW
- [ ] Shared albums

### Version 1.5

- [ ] Face recognition
- [ ] People
- [ ] Object recognition
- [ ] Semantic search
- [ ] Memories
- [ ] AI organization

### Version 2.0

- [ ] AI editing
- [ ] Advanced sharing
- [ ] Family libraries
- [ ] Web integration
- [ ] Desktop integration
- [ ] Advanced AI search
- [ ] Full Neutrino ecosystem integration

---

# 20. Feature Priority

| Area | MVP | V1 | V2 |
|---|---|---|---|
| Photo Library | ★★★ | | |
| Automatic Backup | ★★★ | | |
| Encryption | ★★★ | | |
| Sync | ★★★ | | |
| Albums | ★★★ | | |
| Search | ★★ | ★★★ | |
| Editing | ★ | ★★★ | ★★★ |
| Maps | | ★★★ | |
| People | | ★★ | ★★★ |
| AI Search | | ★★ | ★★★ |
| Memories | | ★★ | ★★★ |
| Sharing | ★ | ★★★ | ★★★ |
| Duplicate Detection | | ★★★ | |
| AI Editing | | | ★★★ |
| Family Libraries | | | ★★★ |
| Desktop | | ★★ | ★★★ |
| Web | ★ | ★★ | ★★★ |
| Drive Integration | ★★★ | ★★★ | ★★★ |

---

# 21. Key Product Differentiators

Neutrino Photos should not attempt to win solely by copying Apple Photos or Google Photos.

Its strongest differentiators should be:

### 1. Privacy First

**Your photos, your keys, your data.**

End-to-end encryption should be fundamental to the architecture.

### 2. Cross-Platform Library

One library across:

- iPhone
- iPad
- Mac
- Windows/Linux
- Web

### 3. Neutrino Ecosystem

Photos become available throughout Neutrino:

**Photos → Drive → Docs → Sheets → Slides**

### 4. Open Storage Model

Users should understand exactly where their photos are stored and how much storage they're using.

### 5. Excellent Migration

Make it extremely easy to move from:

- Apple Photos
- Google Photos
- Local folders
- Existing cloud storage

### 6. No Vendor Lock-In

A user should be able to export their entire library, including:

- Originals
- Videos
- Metadata
- Albums
- Dates
- Locations
- Captions

### 7. Local-First Experience

The app should feel fast even when the network is slow or unavailable.

---

# 22. Long-Term Goal

The ultimate Neutrino Photos experience should look something like:

**Open app → everything is already there.**

The user shouldn't have to think about:

- Where photos are stored
- Whether they've been backed up
- Which device they're on
- How to find an old picture
- How to organize thousands of photos
- How to share an album
- Whether their photos are private

Neutrino Photos should quietly handle all of that while giving the user **complete ownership and control of their photo library**.