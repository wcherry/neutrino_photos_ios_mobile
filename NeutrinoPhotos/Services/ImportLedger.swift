import Foundation
import os.log

// MARK: - ImportLedger

/// What this device has already uploaded, and therefore must not upload again.
///
/// ## Why one record and not two
///
/// There are two ways into this app — the photo picker (Epic 5) and the full-library run (Epic 6) —
/// and if each kept its own record of what it had done, importing a photograph one way and then
/// running the other would upload it twice. So both consult this, and the single most important
/// check in Epic 6's verification ("run the import again → reports 0 new items, adds nothing") is a
/// property of this type rather than of either importer.
///
/// ## Two keys, because neither one is enough
///
/// **`PHAsset.localIdentifier`** is the primary key. It is stable for the life of an install, it is
/// known *before* any bytes are read — which is what lets a re-scan of fifty thousand assets skip
/// forty-nine thousand of them without touching the disk — and it survives the case a hash cannot:
/// the same photograph re-encoded on the way out, so that the bytes differ and the picture does
/// not. It is not stable across devices or across a restore from backup, which is why it is not the
/// only key.
///
/// **SHA-256 of the uploaded bytes** is the second. It catches what the identifier cannot: the same
/// picture imported on a device that never granted photo-library access (there is no asset to name),
/// AirDropped between two phones, or arriving twice from two different places in the roll.
///
/// ## Why the record is local at all
///
/// The server holds ciphertext. It cannot compare two uploads for sameness, and nothing in the API
/// answers "do you already have this picture?" — so de-duplication is the device's job or it is
/// nobody's.
///
/// A `@MainActor` observable rather than an actor: the counters are read from SwiftUI, the sets are
/// small operations on values already in memory, and every write that actually costs anything is a
/// call into ``LocalStore``, which is an actor and does its work there.
@MainActor
final class ImportLedger: ObservableObject {

    // MARK: - Published State

    /// How many items this device has uploaded, for the line in Settings that explains why a second
    /// import of the same photographs does nothing.
    @Published private(set) var count: Int = 0

    // MARK: - Dependencies

    /// Where the record lives between launches. Optional, like everywhere else this appears: a
    /// device whose database would not open keeps the record in memory and in `UserDefaults`, which
    /// is exactly what this app did before there was a table for it.
    private let store: LocalStore?

    private let defaults: UserDefaults

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "ImportLedger")

    /// Asset identifiers, held whole. See ``LocalStore/importedAssetIdentifiers()`` for the size
    /// this costs and why it is worth it.
    private var identifiers: Set<String> = []

    /// Fingerprints, held whole only when there is no database to ask. With one, this stays empty
    /// and the question goes to an indexed column instead.
    private var fingerprints: Set<String> = []

    private var hasHydrated = false

    /// Where this app kept its fingerprints before Epic 6 gave them a table. Read once and migrated
    /// so that upgrading does not re-upload somebody's whole library.
    static let legacyFingerprintsKey = "import.fingerprints"

    // MARK: - Init

    init(store: LocalStore? = nil, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        // Read synchronously so a launch that has not yet hydrated still knows what the previous
        // build recorded. Cheap: it is one array in `UserDefaults`, and on any device that has run
        // this build it is empty because ``hydrate()`` removed it.
        self.fingerprints = Set(defaults.stringArray(forKey: Self.legacyFingerprintsKey) ?? [])
        self.count = fingerprints.count
    }

    // MARK: - Hydration

    /// Loads the record from the database, migrating anything the previous build left in
    /// `UserDefaults`. Runs once; safe to call from anywhere that might be first.
    func hydrate() async {
        guard !hasHydrated else { return }
        hasHydrated = true
        guard let store else { return }

        // The migration first, so that the read below sees it and the legacy list can be dropped in
        // the same launch rather than being re-migrated on every one.
        let legacy = Array(fingerprints)
        if !legacy.isEmpty {
            do {
                try await store.recordImportedFingerprints(legacy)
                defaults.removeObject(forKey: Self.legacyFingerprintsKey)
                fingerprints = []
                logger.debug("migrated \(legacy.count) fingerprints into the local store")
            } catch {
                logger.error("fingerprint migration failed: \(error, privacy: .public)")
            }
        }

        identifiers = (try? await store.importedAssetIdentifiers()) ?? []
        count = await store.importedCount()
        logger.debug("hydrated: \(self.count) imported item(s), \(self.identifiers.count) with an asset")
    }

    // MARK: - Asking

    /// Whether this device has already imported that asset. Synchronous, because it is asked once
    /// per asset while a scan is walking a library and an `await` per item would dominate it.
    func contains(localIdentifier: String) -> Bool {
        identifiers.contains(localIdentifier)
    }

    /// Whether these exact bytes have been uploaded before.
    func contains(fingerprint: String) async -> Bool {
        if fingerprints.contains(fingerprint) { return true }
        guard let store else { return false }
        return await store.hasImportedFingerprint(fingerprint)
    }

    /// The photo record an already-imported asset became, when that is known.
    func photoID(forAsset localIdentifier: String) async -> String? {
        await store?.importedPhotoID(forAsset: localIdentifier)
    }

    // MARK: - Recording

    /// Notes that an item is now in the account.
    ///
    /// Both keys are written when both are known: the identifier is what a re-scan checks, the
    /// fingerprint is what catches the same picture arriving by another route.
    func record(localIdentifier: String?, fingerprint: String?, photoID: String?) async {
        if let localIdentifier { identifiers.insert(localIdentifier) }

        guard let store else {
            // No database: keep the pre-Epic-6 behaviour exactly, so this degrades to a slower app
            // rather than to one that duplicates a library.
            if let fingerprint {
                fingerprints.insert(fingerprint)
                defaults.set(Array(fingerprints), forKey: Self.legacyFingerprintsKey)
            }
            count = fingerprints.count
            return
        }

        do {
            try await store.recordImport(localIdentifier: localIdentifier, fingerprint: fingerprint,
                                         photoID: photoID)
            count = await store.importedCount()
        } catch {
            logger.error("could not record an import: \(error, privacy: .public)")
        }
    }

    // MARK: - Forgetting

    /// Forgets everything, so the same photographs can be uploaded again.
    ///
    /// Offered in Settings beside the explanation, because the record is a convenience rather than
    /// a constraint the user should be stuck inside — a library that lost its cloud copy needs a
    /// way to send it again.
    func forget() async {
        identifiers = []
        fingerprints = []
        defaults.removeObject(forKey: Self.legacyFingerprintsKey)
        try? await store?.clearImportLedger()
        count = 0
    }
}
