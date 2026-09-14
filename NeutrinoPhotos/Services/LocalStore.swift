import Foundation
import SQLite3
import os.log

// MARK: - LocalStoreError

enum LocalStoreError: LocalizedError {
    case cannotOpen(String)
    case statementFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let message):      return "Could not open the local library: \(message)"
        case .statementFailed(let message): return "Local library error: \(message)"
        }
    }
}

// MARK: - LocalStore

/// The device's copy of the library: one SQLite database, one table that matters, and the
/// migrations that got it here.
///
/// ## Why SQLite, directly
///
/// Epic 0 left the choice open between GRDB, Core Data, and raw SQLite. The deciding factor it
/// named is timeline query performance at 100,000 rows, and all three answer that identically —
/// they are all SQLite, and the query plan is the thing that matters. What differs is what else
/// comes with them. Core Data brings a managed object graph, faulting, and an undo manager this app
/// has no use for, and its migration story is the part of Core Data most likely to lose somebody's
/// data. GRDB is an excellent library and a third-party dependency for what amounts to four tables
/// and eleven statements.
///
/// So: `import SQLite3`, which is in the SDK, and about three hundred lines that are all visible.
/// The rule that keeps that honest is that nothing clever is allowed to live here — no query
/// builder, no object mapping, no lazy loading. If this file ever wants those, it wants GRDB.
///
/// ## What makes the timeline query fast
///
/// `photo(is_trashed, is_archived, timeline_date DESC)`. The timeline is exactly one query — live,
/// unarchived, newest first — and that index answers it without a sort. `timeline_date` is stored
/// rather than computed as `COALESCE(capture_date, created_at)` at query time, because an
/// expression cannot be the leading column of an ordinary index and a 100,000-row sort is what the
/// epic is trying to avoid.
///
/// ## What this is not
///
/// Not a sync engine. Rows are replaced wholesale by whatever the server last said, there is no
/// cursor, no tombstone, and no conflict rule — those are Epic 10's, and inventing half of one here
/// would be worse than not having it. What this *is* is the answer to "what should the timeline
/// draw before the network answers", and the place a rendition index can outlive a launch.
///
/// An actor, so the file handle has exactly one owner and callers get their serialization for free.
actor LocalStore {

    // MARK: - Schema

    /// Applied in order; `user_version` records how far this database has got. Append only — an
    /// edit to an existing migration is a change that already-installed devices will never run.
    private static let migrations: [String] = [
        // 1 — the library, its renditions, and a scratch table for ids that are not photographs.
        """
        CREATE TABLE photo (
            id                  TEXT PRIMARY KEY NOT NULL,
            file_id             TEXT NOT NULL,
            file_name           TEXT NOT NULL,
            mime_type           TEXT NOT NULL,
            size_bytes          INTEGER NOT NULL,
            thumbnail           TEXT,
            thumbnail_mime_type TEXT,
            is_starred          INTEGER NOT NULL DEFAULT 0,
            is_archived         INTEGER NOT NULL DEFAULT 0,
            is_trashed          INTEGER NOT NULL DEFAULT 0,
            capture_date        REAL,
            created_at          REAL NOT NULL,
            updated_at          REAL NOT NULL,
            timeline_date       REAL NOT NULL,
            metadata            TEXT
        );
        CREATE INDEX photo_timeline ON photo(is_trashed, is_archived, timeline_date DESC);
        CREATE INDEX photo_file ON photo(file_id);

        CREATE TABLE rendition (
            file_id           TEXT NOT NULL,
            kind              TEXT NOT NULL,
            rendition_file_id TEXT NOT NULL,
            PRIMARY KEY (file_id, kind)
        );

        CREATE TABLE meta (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """,

        // 2 — what has been imported, and what is still queued to be (Epic 6).
        //
        // Two tables with two different lifetimes. `imported_asset` is the *ledger*: it outlives
        // every run and is what makes a second full import report zero new items. `import_queue` is
        // one run's work list, replaced when a run starts and read back after a relaunch — it is
        // the whole of "the import survives termination".
        """
        CREATE TABLE imported_asset (
            key              TEXT PRIMARY KEY NOT NULL,
            local_identifier TEXT,
            fingerprint      TEXT,
            photo_id         TEXT,
            imported_at      REAL NOT NULL
        );
        CREATE INDEX imported_asset_fingerprint ON imported_asset(fingerprint);

        CREATE TABLE import_queue (
            local_identifier TEXT PRIMARY KEY NOT NULL,
            sort_index       INTEGER NOT NULL,
            state            TEXT NOT NULL,
            attempts         INTEGER NOT NULL DEFAULT 0,
            last_error       TEXT,
            is_video         INTEGER NOT NULL DEFAULT 0,
            estimated_bytes  INTEGER NOT NULL DEFAULT 0,
            album_titles     TEXT
        );
        CREATE INDEX import_queue_state ON import_queue(state, sort_index);
        """,

        // 3 — when a trashed item was deleted (Epic 9).
        //
        // Needed on the device rather than only on the server because Recently Deleted is one of the
        // views a cold launch with no signal draws from the cache, and a countdown that only exists
        // in the listing response would show "30 days left" for everything until the network
        // answered. Nullable with no default: an item cached by an older build has no timestamp and
        // shows no countdown, which is honest — `TrashRetention` returns nil rather than guessing.
        """
        ALTER TABLE photo ADD COLUMN deleted_at REAL;
        """,
    ]

    /// What ``migrations`` adds up to. Asserted in tests so an appended migration that forgets to
    /// bump this is caught before a device runs it.
    static var schemaVersion: Int { migrations.count }

    // MARK: - Meta keys

    enum MetaKey {
        /// The Drive folder holding this account's encrypted preview renditions, so finding it is
        /// a listing once rather than on every launch.
        static let renditionsFolderID = "renditions.folderID"
        /// When the rendition index was last read from Drive.
        static let renditionsSyncedAt = "renditions.syncedAt"
        /// The Drive folder holding the encrypted paired videos of imported Live Photos.
        static let livePhotosFolderID = "livePhotos.folderID"
        /// When the device's photo library was last scanned for a full-library import, so the next
        /// run can say what "since last time" means.
        static let lastLibraryScanAt = "import.lastScanAt"
        /// When a full-library run last drained to nothing.
        static let lastLibraryImportAt = "import.lastCompletedAt"
    }

    // MARK: - Private

    private let database: OpaquePointer
    private let url: URL

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "LocalStore")

    // MARK: - Init

    /// Opens (or creates) the database at `url` and brings it up to ``schemaVersion``.
    init(url: URL) throws {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw LocalStoreError.cannotOpen(message)
        }
        self.database = handle

        // The library is a cache of the server's truth, so durability is worth less here than not
        // stalling a scroll: WAL plus NORMAL means a write does not fsync, and the worst a crash
        // can cost is the last listing, which the next launch fetches anyway.
        Self.exec(handle, "PRAGMA journal_mode = WAL;")
        Self.exec(handle, "PRAGMA synchronous = NORMAL;")
        Self.exec(handle, "PRAGMA foreign_keys = ON;")

        // Static, and given the handle explicitly, rather than an isolated method called on a
        // half-built actor. Both spellings run identically today; only this one is still legal
        // under the Swift 6 language mode.
        try Self.migrate(handle)
    }

    /// The database this app ships with: Application Support, excluded from backup.
    ///
    /// Not `Library/Caches`: the system may empty that at any moment, and a timeline that
    /// occasionally forgets everything it knew is worse than one that never cached. Excluded from
    /// iCloud backup all the same, because every row is re-fetchable and one of the columns is a
    /// thumbnail.
    static func makeDefault() throws -> LocalStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var url = base.appendingPathComponent("NeutrinoPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return try LocalStore(url: url.appendingPathComponent("library.sqlite"))
    }

    deinit {
        sqlite3_close_v2(database)
    }

    // MARK: - Migration

    nonisolated private static func migrate(_ database: OpaquePointer) throws {
        let current = Int(scalar(database, "PRAGMA user_version;") ?? 0)
        guard current < migrations.count else { return }

        for (index, migration) in migrations.enumerated() where index >= current {
            try transaction(database) {
                try execute(database, migration)
                // Interpolated rather than bound: PRAGMA does not take parameters, and the value is
                // an array index rather than anything a caller supplied.
                try execute(database, "PRAGMA user_version = \(index + 1);")
            }
        }
    }

    /// Where the database lives, and what it costs — for the Settings storage breakdown. The `-wal`
    /// and `-shm` companions count: they are the database as much as the main file is.
    func sizeOnDisk() -> Int64 {
        ["", "-wal", "-shm"].reduce(into: Int64(0)) { total, suffix in
            let path = url.path + suffix
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64
            total += size ?? 0
        }
    }

    // MARK: - Library

    /// Replaces the cached library with `items`, in one transaction.
    ///
    /// Wholesale rather than a diff, because the listing endpoint answers with the whole library
    /// and anything a diff could add — knowing what changed — is Epic 10's job and needs a cursor
    /// this has no access to. Trashed rows are left alone: they come from a different endpoint.
    func replaceLibrary(with items: [MediaItem]) throws {
        try transaction {
            try execute("DELETE FROM photo WHERE is_trashed = 0;")
            for item in items { try insert(item, trashed: false) }
        }
    }

    /// Replaces the cached Recently Deleted listing.
    func replaceTrash(with items: [MediaItem]) throws {
        try transaction {
            try execute("DELETE FROM photo WHERE is_trashed = 1;")
            for item in items { try insert(item, trashed: true) }
        }
    }

    /// Writes one item, replacing whatever was there — a favourite toggled, an upload registered.
    func save(_ item: MediaItem, trashed: Bool = false) throws {
        try transaction { try insert(item, trashed: trashed) }
    }

    /// The live library, newest first, archived items included — the same shape
    /// ``PhotoLibraryService/allItems`` holds, so hydrating it is an assignment.
    func libraryItems() throws -> [MediaItem] {
        try items(trashed: false)
    }

    func trashedItems() throws -> [MediaItem] {
        try items(trashed: true)
    }

    /// How many live photographs are cached — the cheap question, answered without building rows.
    func libraryCount() -> Int {
        Int(Self.scalar(database, "SELECT COUNT(*) FROM photo WHERE is_trashed = 0;") ?? 0)
    }

    private func items(trashed: Bool) throws -> [MediaItem] {
        // The index is (is_trashed, is_archived, timeline_date DESC), so this is a range scan in
        // index order with no sort step — which is the whole reason the column exists.
        let sql = """
        SELECT id, file_id, file_name, mime_type, size_bytes, thumbnail, thumbnail_mime_type,
               is_starred, is_archived, capture_date, created_at, updated_at, metadata, deleted_at
        FROM photo WHERE is_trashed = ? ORDER BY timeline_date DESC;
        """
        var items: [MediaItem] = []
        try query(sql, bind: { statement in
            sqlite3_bind_int(statement, 1, trashed ? 1 : 0)
        }, row: { statement in
            items.append(Self.item(from: statement))
        })
        return items
    }

    private func insert(_ item: MediaItem, trashed: Bool) throws {
        let sql = """
        INSERT OR REPLACE INTO photo
            (id, file_id, file_name, mime_type, size_bytes, thumbnail, thumbnail_mime_type,
             is_starred, is_archived, is_trashed, capture_date, created_at, updated_at,
             timeline_date, metadata, deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try run(sql) { statement in
            bind(statement, 1, item.id)
            bind(statement, 2, item.fileID)
            bind(statement, 3, item.fileName)
            bind(statement, 4, item.mimeType)
            sqlite3_bind_int64(statement, 5, item.sizeBytes)
            bind(statement, 6, item.thumbnailBase64)
            bind(statement, 7, item.thumbnailMIMEType)
            sqlite3_bind_int(statement, 8, item.isStarred ? 1 : 0)
            sqlite3_bind_int(statement, 9, item.isArchived ? 1 : 0)
            sqlite3_bind_int(statement, 10, trashed ? 1 : 0)
            bind(statement, 11, item.captureDate?.timeIntervalSince1970)
            sqlite3_bind_double(statement, 12, item.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 13, item.updatedAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 14, item.timelineDate.timeIntervalSince1970)
            bind(statement, 15, item.metadata.flatMap(Self.encodeMetadata))
            bind(statement, 16, item.deletedAt?.timeIntervalSince1970)
        }
    }

    /// Forgets one item entirely — what a permanent delete leaves behind, which is nothing.
    ///
    /// Distinct from writing it back with `is_trashed = 1`: that is a soft delete and the row has to
    /// survive it. This is the row going away, so a cold launch does not hydrate a photograph the
    /// account no longer has.
    func delete(id: String) throws {
        try run("DELETE FROM photo WHERE id = ?;") { statement in
            bind(statement, 1, id)
        }
    }

    private static func item(from statement: OpaquePointer) -> MediaItem {
        MediaItem(
            id: text(statement, 0) ?? "",
            fileID: text(statement, 1) ?? "",
            fileName: text(statement, 2) ?? "",
            mimeType: text(statement, 3) ?? "application/octet-stream",
            sizeBytes: sqlite3_column_int64(statement, 4),
            thumbnailBase64: text(statement, 5),
            thumbnailMIMEType: text(statement, 6),
            isStarred: sqlite3_column_int(statement, 7) != 0,
            isArchived: sqlite3_column_int(statement, 8) != 0,
            captureDate: date(statement, 9),
            createdAt: date(statement, 10) ?? Date(timeIntervalSince1970: 0),
            updatedAt: date(statement, 11) ?? Date(timeIntervalSince1970: 0),
            deletedAt: date(statement, 13),
            metadata: text(statement, 12).flatMap(decodeMetadata)
        )
    }

    // MARK: - Renditions

    /// The Drive file holding `rendition` of `fileID`, if this device knows of one.
    func renditionFileID(forFile fileID: String, rendition: MediaRendition) -> String? {
        var result: String?
        try? query("SELECT rendition_file_id FROM rendition WHERE file_id = ? AND kind = ?;",
                   bind: { statement in
                       self.bind(statement, 1, fileID)
                       self.bind(statement, 2, rendition.rawValue)
                   }, row: { statement in
                       result = Self.text(statement, 0)
                   })
        return result
    }

    func setRenditionFileID(_ renditionFileID: String, forFile fileID: String,
                            rendition: MediaRendition) throws {
        try run("INSERT OR REPLACE INTO rendition (file_id, kind, rendition_file_id) VALUES (?, ?, ?);") {
            statement in
            bind(statement, 1, fileID)
            bind(statement, 2, rendition.rawValue)
            bind(statement, 3, renditionFileID)
        }
    }

    /// Replaces the whole rendition index with what a Drive listing just reported.
    func replaceRenditions(with index: [String: String], rendition: MediaRendition) throws {
        try transaction {
            try run("DELETE FROM rendition WHERE kind = ?;") { bind($0, 1, rendition.rawValue) }
            for (fileID, renditionFileID) in index {
                try run("INSERT OR REPLACE INTO rendition (file_id, kind, rendition_file_id) VALUES (?, ?, ?);") {
                    statement in
                    bind(statement, 1, fileID)
                    bind(statement, 2, rendition.rawValue)
                    bind(statement, 3, renditionFileID)
                }
            }
        }
    }

    // MARK: - The import ledger

    /// Every `PHAsset.localIdentifier` this device has already imported.
    ///
    /// Read whole, once, because the question it answers is asked once per asset during a scan —
    /// fifty thousand times over an acceptance library — and a point query per asset would turn a
    /// scan into fifty thousand round trips through this actor. The set costs a few megabytes at
    /// that size, which is the trade this makes knowingly.
    func importedAssetIdentifiers() throws -> Set<String> {
        var identifiers: Set<String> = []
        try query("SELECT local_identifier FROM imported_asset WHERE local_identifier IS NOT NULL;",
                  row: { statement in
                      if let value = Self.text(statement, 0) { identifiers.insert(value) }
                  })
        return identifiers
    }

    /// Whether these exact bytes have been uploaded before.
    ///
    /// A point query rather than a set, because unlike the identifier this is asked once per item
    /// being *imported* rather than once per item being scanned — by which time the item's bytes
    /// have already been read off disk and hashed, and one indexed lookup is free beside that.
    func hasImportedFingerprint(_ fingerprint: String) -> Bool {
        var found = false
        try? query("SELECT 1 FROM imported_asset WHERE fingerprint = ? LIMIT 1;",
                   bind: { self.bind($0, 1, fingerprint) },
                   row: { _ in found = true })
        return found
    }

    /// The photo record an already-imported asset became, if it is known.
    func importedPhotoID(forAsset localIdentifier: String) -> String? {
        var result: String?
        try? query("SELECT photo_id FROM imported_asset WHERE local_identifier = ? LIMIT 1;",
                   bind: { self.bind($0, 1, localIdentifier) },
                   row: { result = Self.text($0, 0) })
        return result
    }

    func importedCount() -> Int {
        Int(Self.scalar(database, "SELECT COUNT(*) FROM imported_asset;") ?? 0)
    }

    /// Records one import.
    ///
    /// - Parameter localIdentifier: nil for an item picked in the photo picker on a device with no
    ///   library access — there is no asset to name, and the fingerprint is the only key there is.
    ///   The row is keyed by the identifier when there is one so that re-importing the same asset
    ///   updates its row rather than adding a second, and by its hash when there is not.
    func recordImport(localIdentifier: String?, fingerprint: String?, photoID: String?,
                      at date: Date = Date()) throws {
        guard let key = localIdentifier ?? fingerprint.map({ "sha256:" + $0 }) else { return }
        try run("""
                INSERT OR REPLACE INTO imported_asset
                    (key, local_identifier, fingerprint, photo_id, imported_at)
                VALUES (?, ?, ?, ?, ?);
                """) { statement in
            bind(statement, 1, key)
            bind(statement, 2, localIdentifier)
            bind(statement, 3, fingerprint)
            bind(statement, 4, photoID)
            sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        }
    }

    /// Bulk-records fingerprints with no asset behind them — the one-time migration of the
    /// `UserDefaults` list this app kept before there was a table for it.
    func recordImportedFingerprints(_ fingerprints: [String]) throws {
        try transaction {
            for fingerprint in fingerprints {
                try recordImport(localIdentifier: nil, fingerprint: fingerprint, photoID: nil)
            }
        }
    }

    func clearImportLedger() throws {
        try execute("DELETE FROM imported_asset;")
    }

    // MARK: - The import queue

    /// Replaces the queue with a new run's work list.
    ///
    /// Wholesale, including over a queue a previous run left failures in — which is correct rather
    /// than lossy: a scan queues everything the ledger has never seen, and an item that failed last
    /// time was, by definition, never recorded as imported. It comes straight back, with its
    /// attempt count reset, which is what somebody scanning again is asking for.
    func replaceImportQueue(with items: [ImportQueueItem]) throws {
        try transaction {
            try execute("DELETE FROM import_queue;")
            for item in items { try insert(item) }
        }
    }

    /// Adds items to the front of the queue, leaving everything already in it alone.
    ///
    /// This is what a hand-picked selection needs and ``replaceImportQueue(with:)`` cannot give it.
    /// A scan owns the whole queue — it *is* the work list — but somebody who picked forty
    /// photographs out of the device-library grid has not asked to discard the two thousand an
    /// interrupted full-library run still has pending, and replacing the queue would do exactly
    /// that, silently.
    ///
    /// "Front" is meant literally: the rows are given sort indices below the lowest one in the
    /// table, so a run already in flight takes them next rather than after the rest of the library.
    /// Somebody who just tapped Upload on forty pictures is watching for those forty.
    ///
    /// An item already in the queue is replaced rather than duplicated — `local_identifier` is the
    /// primary key — so re-picking something that failed earlier retries it, with its attempt count
    /// reset. Re-picking something already uploaded costs nothing either: the ledger check inside
    /// the run skips it without reading a byte off disk.
    func prependImportQueue(with items: [ImportQueueItem]) throws {
        guard !items.isEmpty else { return }
        try transaction {
            // NULL on an empty table, which `scalar` reports as 0 — the right base either way.
            let lowest = Self.scalar(database, "SELECT MIN(sort_index) FROM import_queue;") ?? 0
            for (offset, item) in items.enumerated() {
                var row = item
                row.sortIndex = Int(lowest) - items.count + offset
                try insert(row)
            }
        }
    }

    private func insert(_ item: ImportQueueItem) throws {
        try run("""
                INSERT OR REPLACE INTO import_queue
                    (local_identifier, sort_index, state, attempts, last_error, is_video,
                     estimated_bytes, album_titles)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """) { statement in
            bindQueueRow(statement, item)
        }
    }

    private func bindQueueRow(_ statement: OpaquePointer, _ item: ImportQueueItem) {
        bind(statement, 1, item.localIdentifier)
        sqlite3_bind_int(statement, 2, Int32(item.sortIndex))
        bind(statement, 3, item.state.rawValue)
        sqlite3_bind_int(statement, 4, Int32(item.attempts))
        bind(statement, 5, item.lastError)
        sqlite3_bind_int(statement, 6, item.isVideo ? 1 : 0)
        sqlite3_bind_int64(statement, 7, item.estimatedBytes)
        bind(statement, 8, Self.encodeTitles(item.albumTitles))
    }

    /// The next items to attempt, oldest position first.
    func nextPendingImportItems(limit: Int = 1) throws -> [ImportQueueItem] {
        var items: [ImportQueueItem] = []
        try query("""
                  SELECT local_identifier, sort_index, state, attempts, last_error, is_video,
                         estimated_bytes, album_titles
                  FROM import_queue WHERE state = 'pending' ORDER BY sort_index ASC LIMIT ?;
                  """,
                  bind: { sqlite3_bind_int($0, 1, Int32(limit)) },
                  row: { items.append(Self.queueItem(from: $0)) })
        return items
    }

    /// Everything that has failed, for the list the user can retry from. Bounded, because a run
    /// that failed on every one of fifty thousand items should not also try to draw them all.
    func failedImportItems(limit: Int = 200) throws -> [ImportQueueItem] {
        var items: [ImportQueueItem] = []
        try query("""
                  SELECT local_identifier, sort_index, state, attempts, last_error, is_video,
                         estimated_bytes, album_titles
                  FROM import_queue WHERE state = 'failed' ORDER BY sort_index ASC LIMIT ?;
                  """,
                  bind: { sqlite3_bind_int($0, 1, Int32(limit)) },
                  row: { items.append(Self.queueItem(from: $0)) })
        return items
    }

    /// The whole queue as counts and byte totals, in one pass over the index.
    func importQueueCounts() -> ImportQueueCounts {
        var counts = ImportQueueCounts()
        try? query("""
                   SELECT state, COUNT(*), COALESCE(SUM(estimated_bytes), 0)
                   FROM import_queue GROUP BY state;
                   """, row: { statement in
            let state = ImportQueueItem.State(rawValue: Self.text(statement, 0) ?? "")
            let count = Int(sqlite3_column_int64(statement, 1))
            let bytes = sqlite3_column_int64(statement, 2)
            switch state {
            case .pending:
                counts.pending = count
                counts.pendingBytes = bytes
            case .failed:
                counts.failed = count
                counts.failedBytes = bytes
            case .done:
                counts.done = count
                counts.finishedBytes += bytes
            case .skipped:
                counts.skipped = count
                counts.finishedBytes += bytes
            case nil:
                break
            }
        })
        return counts
    }

    /// Records how one attempt went.
    func updateImportItem(_ localIdentifier: String, state: ImportQueueItem.State,
                          attempts: Int, error: String? = nil) throws {
        try run("""
                UPDATE import_queue SET state = ?, attempts = ?, last_error = ?
                WHERE local_identifier = ?;
                """) { statement in
            bind(statement, 1, state.rawValue)
            sqlite3_bind_int(statement, 2, Int32(attempts))
            bind(statement, 3, error)
            bind(statement, 4, localIdentifier)
        }
    }

    /// Puts failed rows back in the queue.
    ///
    /// - Parameter maximumAttempts: nil re-queues everything, which is what the Retry button does.
    ///   A number re-queues only what has not been tried that many times — the automatic pass at
    ///   the end of a run, which must not spin forever on an item that will never upload.
    /// - Returns: how many rows were re-queued.
    @discardableResult
    func requeueFailedImportItems(maximumAttempts: Int? = nil) throws -> Int {
        let sql = maximumAttempts == nil
            ? "UPDATE import_queue SET state = 'pending' WHERE state = 'failed';"
            : "UPDATE import_queue SET state = 'pending' WHERE state = 'failed' AND attempts < ?;"
        try run(sql) { statement in
            if let maximumAttempts { sqlite3_bind_int(statement, 1, Int32(maximumAttempts)) }
        }
        return Int(sqlite3_changes(database))
    }

    func clearImportQueue() throws {
        try execute("DELETE FROM import_queue;")
    }

    private static func queueItem(from statement: OpaquePointer) -> ImportQueueItem {
        ImportQueueItem(
            localIdentifier: text(statement, 0) ?? "",
            sortIndex: Int(sqlite3_column_int64(statement, 1)),
            state: ImportQueueItem.State(rawValue: text(statement, 2) ?? "") ?? .pending,
            attempts: Int(sqlite3_column_int64(statement, 3)),
            lastError: text(statement, 4),
            isVideo: sqlite3_column_int(statement, 5) != 0,
            estimatedBytes: sqlite3_column_int64(statement, 6),
            albumTitles: decodeTitles(text(statement, 7))
        )
    }

    /// Album titles travel as a JSON array rather than as a delimited string: a title is whatever
    /// the user typed in Apple Photos, and every separator character worth choosing is one somebody
    /// has an album named after.
    private static func encodeTitles(_ titles: [String]) -> String? {
        guard !titles.isEmpty, let data = try? JSONEncoder().encode(titles) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeTitles(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // MARK: - Meta

    func string(forKey key: String) -> String? {
        var result: String?
        try? query("SELECT value FROM meta WHERE key = ?;",
                   bind: { self.bind($0, 1, key) },
                   row: { result = Self.text($0, 0) })
        return result
    }

    func setString(_ value: String?, forKey key: String) throws {
        guard let value else {
            try run("DELETE FROM meta WHERE key = ?;") { bind($0, 1, key) }
            return
        }
        try run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?);") { statement in
            bind(statement, 1, key)
            bind(statement, 2, value)
        }
    }

    // MARK: - Clearing

    /// Empties every table, keeping the schema. What "sign out" and "clear cache" both want: the
    /// database itself is not the problem, the account's photographs in it are.
    ///
    /// The import ledger and queue go with them, and that is deliberate rather than incidental: the
    /// next account to sign in on this device has none of these photographs, so a ledger saying
    /// they are all uploaded would leave that account with an empty library and an import that
    /// reports nothing to do.
    func clear() throws {
        try transaction {
            try execute("""
                        DELETE FROM photo; DELETE FROM rendition; DELETE FROM meta;
                        DELETE FROM imported_asset; DELETE FROM import_queue;
                        """)
        }
        // Returns the freed pages to the filesystem — without it the file keeps a full library's
        // worth of space after a sign-out, which is exactly what the user asked to get back.
        exec("VACUUM;")
    }

    // MARK: - Metadata coding

    private static func encodeMetadata(_ metadata: MediaMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeMetadata(_ json: String) -> MediaMetadata? {
        try? JSONDecoder().decode(MediaMetadata.self, from: Data(json.utf8))
    }

    // MARK: - SQLite plumbing
    //
    // Deliberately small and deliberately dumb. Everything above states its SQL in full; nothing
    // here builds any.

    /// Binds `SQLITE_TRANSIENT`, so SQLite copies the string rather than holding a pointer into a
    /// Swift value that is about to go out of scope. Getting this wrong reads freed memory, and
    /// does so intermittently, which is the worst possible way to find out.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_double(statement, index, value)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    private static func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    /// Prepares, binds, steps once, finalizes — every write in this file.
    private func run(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LocalStoreError.statementFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalStoreError.statementFailed(lastError())
        }
    }

    /// Prepares, binds, and steps until the rows run out, calling `row` for each.
    private func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in },
                       row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LocalStoreError.statementFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    /// Runs one or more statements with no parameters and no results — the migrations.
    private func execute(_ sql: String) throws {
        try Self.execute(database, sql)
    }

    nonisolated private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError(database)
            sqlite3_free(error)
            throw LocalStoreError.statementFailed(message)
        }
    }

    /// `execute` for the statements whose failure is not worth propagating — the PRAGMAs, which are
    /// a performance setting rather than a correctness one.
    nonisolated private static func exec(_ database: OpaquePointer, _ sql: String) {
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func exec(_ sql: String) {
        Self.exec(database, sql)
    }

    nonisolated private static func scalar(_ database: OpaquePointer, _ sql: String) -> Int64? {
        var result: Int64?
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            result = sqlite3_column_int64(statement, 0)
        }
        return result
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    ///
    /// The reason a two-thousand-item listing lands in tens of milliseconds rather than seconds:
    /// without this, every insert is its own transaction and its own trip to the filesystem.
    private func transaction(_ body: () throws -> Void) throws {
        try Self.transaction(database, body)
    }

    nonisolated private static func transaction(_ database: OpaquePointer,
                                                _ body: () throws -> Void) throws {
        try execute(database, "BEGIN IMMEDIATE;")
        do {
            try body()
            try execute(database, "COMMIT;")
        } catch {
            exec(database, "ROLLBACK;")
            throw error
        }
    }

    private func lastError() -> String {
        Self.lastError(database)
    }

    nonisolated private static func lastError(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}
