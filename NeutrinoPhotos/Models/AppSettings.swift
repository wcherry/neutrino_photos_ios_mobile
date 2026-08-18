import SwiftUI

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
    }

    // MARK: - Reset

    func resetToDefaults() {
        theme = .system
        timelineGrouping = .day
        showArchived = false
        wifiOnlyUploads = true
    }
}
