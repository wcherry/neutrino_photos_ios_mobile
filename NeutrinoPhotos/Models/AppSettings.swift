import SwiftUI
import NeutrinoCore

// MARK: - AppTheme

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// What to hand SwiftUI's `.preferredColorScheme`. `nil` follows the device.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - AppSettings

/// The user's preferences, persisted in `UserDefaults`.
///
/// Only settings that actually change what the app does live here. A photo app accumulates toggles
/// quickly — original-versus-optimized storage, charging-only backup, per-album sync — and every
/// one of those belongs with the feature it governs rather than being written now as a switch that
/// silently does nothing.
///
/// `@Published` rather than `@AppStorage` so a single observable object can be injected into the
/// view tree and, more importantly, constructed against a throwaway `UserDefaults` suite in
/// tests — `@AppStorage` reads `.standard` unconditionally.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Keys

    enum Keys {
        static let theme            = "settings.theme"
        static let timelineGrouping = "settings.timelineGrouping"
        static let showArchived     = "settings.showArchived"
        static let wifiOnlyUploads  = "settings.wifiOnlyUploads"
        static let publishesLocation = "settings.publishesLocation"
        static let importsLiveMotion = "settings.importsLiveMotion"
        static let hidesUploadedDeviceItems = "settings.hidesUploadedDeviceItems"
    }

    // MARK: - Published settings

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// Days / Months / Years. Also decides how many columns the grid draws.
    @Published var timelineGrouping: TimelineGrouping {
        didSet { defaults.set(timelineGrouping.rawValue, forKey: Keys.timelineGrouping) }
    }

    /// Whether archived photographs appear in the main timeline. Off by default, which is the
    /// point of archiving them.
    @Published var showArchived: Bool {
        didSet { defaults.set(showArchived, forKey: Keys.showArchived) }
    }

    /// When on, an import waits for Wi-Fi rather than sending originals over cellular. Enforced in
    /// `PhotoImportService` against `NetworkMonitor.isExpensive`.
    @Published var wifiOnlyUploads: Bool {
        didSet { defaults.set(wifiOnlyUploads, forKey: Keys.wifiOnlyUploads) }
    }

    /// Whether a photograph's coordinates are sent to Neutrino along with the rest of its metadata.
    ///
    /// Off by default, and the one setting in this app whose default is a privacy position rather
    /// than a convenience. The picture itself is end-to-end encrypted and the server cannot read a
    /// pixel of it; the metadata index is *not* encrypted, because the server has to be able to sort
    /// and search it. Sending coordinates therefore hands Neutrino a list of where the user has
    /// been, next to a library it otherwise cannot open — which is a real trade and belongs to them
    /// rather than to a default.
    ///
    /// Nothing is lost locally either way: ``MediaMetadataExtractor`` reads the coordinates on this
    /// device and ``LocalStore`` keeps them, so the info panel shows a location whether or not it
    /// was published. What publishing buys is the same location on the user's *other* devices, and
    /// the Places view and map search that will read `GET /api/v1/photos/map`.
    @Published var publishesLocationMetadata: Bool {
        didSet { defaults.set(publishesLocationMetadata, forKey: Keys.publishesLocation) }
    }

    /// Whether a Live Photo's paired video is uploaded beside its still.
    ///
    /// On by default — a Live Photo imported without its motion is not the thing the user took, and
    /// preserving it is what makes it restorable to Apple Photos as a Live Photo. Offered as a
    /// switch because the motion is roughly the size of the still again, over the whole library.
    @Published var importsLivePhotoMotion: Bool {
        didSet { defaults.set(importsLivePhotoMotion, forKey: Keys.importsLiveMotion) }
    }

    /// Whether the device-library album hides items this device has already uploaded.
    ///
    /// Off by default, so the album is what its title says — the photos on this iPhone — rather than
    /// a filtered view somebody has to work out the rule of. Turning it on is what makes the album a
    /// worklist: everything left on screen is something that is not yet backed up. Both readings are
    /// legitimate, which is why it is a switch and not a decision made here.
    @Published var hidesUploadedDeviceItems: Bool {
        didSet { defaults.set(hidesUploadedDeviceItems, forKey: Keys.hidesUploadedDeviceItems) }
    }

    // MARK: - Private

    private let defaults: UserDefaults

    // MARK: - Init

    /// - Parameter defaults: injected in tests so a run cannot disturb the real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        self.timelineGrouping = TimelineGrouping(
            rawValue: defaults.string(forKey: Keys.timelineGrouping) ?? ""
        ) ?? .day
        self.showArchived = defaults.object(forKey: Keys.showArchived) as? Bool ?? false
        // Defaults to on: an unattended import of a camera roll over cellular is a data bill, and
        // this is the more forgiving mistake of the two.
        self.wifiOnlyUploads = defaults.object(forKey: Keys.wifiOnlyUploads) as? Bool ?? true
        // Defaults off: see the property. Opting *in* to sending location is a decision; opting out
        // of it after the fact does not un-send what has already gone.
        self.publishesLocationMetadata =
            defaults.object(forKey: Keys.publishesLocation) as? Bool ?? false
        self.importsLivePhotoMotion =
            defaults.object(forKey: Keys.importsLiveMotion) as? Bool ?? true
        self.hidesUploadedDeviceItems =
            defaults.object(forKey: Keys.hidesUploadedDeviceItems) as? Bool ?? false
    }

    // MARK: - Reset

    func resetToDefaults() {
        theme = .system
        timelineGrouping = .day
        showArchived = false
        wifiOnlyUploads = true
        publishesLocationMetadata = false
        importsLivePhotoMotion = true
        hidesUploadedDeviceItems = false
    }
}
