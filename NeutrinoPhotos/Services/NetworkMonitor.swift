import Foundation
import Network
import os.log

// MARK: - NetworkMonitor

/// Publishes whether the device has a usable network path, and whether that path is metered.
///
/// A photo library is the one Neutrino app where the *kind* of connection matters as much as its
/// presence: an import is megabytes per picture, so "Upload over Wi-Fi only" is a setting people
/// actually reach for. `isExpensive` is what makes it enforceable.
///
/// Backed by `NWPathMonitor`, which reports on a background queue — every update is hopped back
/// onto the main actor before it touches published state.
@MainActor
final class NetworkMonitor: ObservableObject {

    // MARK: - Published State

    /// Optimistic default: assume connectivity until `NWPathMonitor` says otherwise, so the first
    /// library load after launch is not needlessly suppressed.
    @Published private(set) var isOnline: Bool = true

    /// True on a metered path — cellular, or a personal hotspot. An expensive path is still
    /// *online*, it is just one the user may not want a 4 MB photograph sent over.
    @Published private(set) var isExpensive: Bool = false

    /// True when the system is in Low Data Mode.
    @Published private(set) var isConstrained: Bool = false

    // MARK: - Computed

    /// Whether an upload should start right now, honouring the user's Wi-Fi-only preference.
    func shouldUpload(wifiOnly: Bool) -> Bool {
        guard isOnline else { return false }
        return !wifiOnly || !isExpensive
    }

    // MARK: - Private

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoPhotos",
                                category: "NetworkMonitor")

    /// `NWPathMonitor` cannot be restarted once cancelled, so a fresh instance is created by every
    /// `start()` and released by `stop()`.
    private var monitor: NWPathMonitor?

    private let queue = DispatchQueue(label: "com.neutrino.photos.networkmonitor")

    // MARK: - Init

    /// - Parameter autoStart: pass `false` in unit tests to keep the process free of a live path
    ///   monitor; `setPathForTesting(...)` then drives the published values.
    init(autoStart: Bool = true) {
        if autoStart { start() }
    }

    // MARK: - Lifecycle

    /// Begins observing the system's network path. Safe to call repeatedly.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = (path.status == .satisfied)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            // The handler fires on `queue`; hop to the main actor before publishing.
            Task { @MainActor [weak self] in
                self?.apply(isOnline: online, isExpensive: expensive, isConstrained: constrained)
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        logger.debug("NetworkMonitor started")
    }

    /// Stops observing. Safe to call when not started.
    func stop() {
        guard let monitor else { return }
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        self.monitor = nil
        logger.debug("NetworkMonitor stopped")
    }

    // MARK: - Test Hooks

    #if DEBUG
    /// Drives the published values without a real network path.
    func setPathForTesting(isOnline: Bool, isExpensive: Bool = false, isConstrained: Bool = false) {
        apply(isOnline: isOnline, isExpensive: isExpensive, isConstrained: isConstrained)
    }
    #endif

    // MARK: - Private Helpers

    private func apply(isOnline value: Bool, isExpensive expensive: Bool, isConstrained constrained: Bool) {
        if isExpensive != expensive { isExpensive = expensive }
        if isConstrained != constrained { isConstrained = constrained }
        guard isOnline != value else { return }
        isOnline = value
        logger.debug("connectivity changed: isOnline=\(value, privacy: .public)")
    }
}
