import SwiftUI
import UIKit

// MARK: - SlideshowFrame

/// One photograph as a slideshow shows it: what the phone draws and what it sends to the external
/// display.
///
/// Carries the decoded image rather than the ``MediaItem``, so the external display needs nothing
/// from the library, the cache or the key vault — the phone has already done the decrypting, and
/// the second screen only has to draw.
struct SlideshowFrame: Equatable {
    let itemID: String
    /// The best picture so far: the grid thumbnail while the preview downloads, then the preview.
    /// Nil until the first of those arrives.
    let image: UIImage?
    /// The photograph could not be loaded at all — most often no key on this device.
    let isUnavailable: Bool

    /// Identity on the image rather than its pixels: the thumbnail giving way to the sharp preview
    /// is a change worth drawing, and comparing two decoded bitmaps would be absurd.
    static func == (lhs: SlideshowFrame, rhs: SlideshowFrame) -> Bool {
        lhs.itemID == rhs.itemID && lhs.image === rhs.image && lhs.isUnavailable == rhs.isUnavailable
    }
}

// MARK: - ExternalDisplayService

/// Showing a slideshow on a second screen — an AirPlay receiver, a USB-C or Lightning adapter.
///
/// iOS hands an external display to the app as a scene of its own, with the
/// `windowExternalDisplayNonInteractive` role. Left unclaimed, the system mirrors the phone, which
/// puts the controls, the status bar and a portrait-shaped picture on the television. Claimed, the
/// room sees only the photograph and the phone is free to be the remote: the current photo, the
/// next one, the pace and the transition.
///
/// The one exception to "nothing reaches for a singleton" in this app — see
/// ``NeutrinoPhotosApp``. The scene delegate that owns the external window is instantiated by
/// UIKit, so there is no initializer to inject through. The app injects this same instance into the
/// view tree, so every SwiftUI caller still receives it as an environment object.
///
/// The same shape as Neutrino Slides' presenter, deliberately: one app's TV behaviour should not
/// surprise somebody who has used the other's.
@MainActor
final class ExternalDisplayService: ObservableObject {

    static let shared = ExternalDisplayService()

    // MARK: - Published state

    /// Whether an external display scene is connected and showing this app's window.
    @Published private(set) var isConnected = false

    /// Whether a slideshow is running. Outside one the display shows a holding screen.
    @Published private(set) var isPresenting = false
    /// The photograph on the external display.
    @Published private(set) var frame: SlideshowFrame?
    @Published private(set) var transition: SlideshowTransition = .dissolve
    /// Zoom, pan and flip on the photograph, as set on the phone.
    @Published private(set) var adjustment = PhotoAdjustment.identity
    /// Which way the last move went, so a directional transition plays the same way round on both
    /// screens.
    @Published private(set) var isAdvancing = true
    /// Changes with every ``begin(transition:)``, so the external view rebuilds for a new slideshow
    /// rather than animating from the last photograph of the previous one.
    @Published private(set) var sessionID = UUID()

    init() {}

    // MARK: - Connection

    /// Called by ``ExternalDisplaySceneDelegate``.
    func displayDidConnect() {
        isConnected = true
    }

    /// Called by ``ExternalDisplaySceneDelegate``.
    func displayDidDisconnect() {
        isConnected = false
    }

    // MARK: - Slideshow

    /// Starts sending a slideshow to the external display.
    ///
    /// Safe to call with no display connected: the state is kept, so a display plugged in
    /// mid-slideshow picks up at the current photograph.
    func begin(transition: SlideshowTransition) {
        self.transition = transition
        isPresenting = true
        frame = nil
        adjustment = .identity
        isAdvancing = true
        sessionID = UUID()
    }

    /// Puts a photograph on the external display. Ignored outside a slideshow.
    func show(_ frame: SlideshowFrame, isAdvancing: Bool) {
        guard isPresenting, frame != self.frame else { return }
        // A different photograph starts unzoomed; a sharper picture of the same one keeps its zoom.
        if frame.itemID != self.frame?.itemID { adjustment = .identity }
        self.isAdvancing = isAdvancing
        self.frame = frame
    }

    func setAdjustment(_ adjustment: PhotoAdjustment) {
        guard isPresenting, adjustment != self.adjustment else { return }
        self.adjustment = adjustment
    }

    func setTransition(_ transition: SlideshowTransition) {
        guard isPresenting else { return }
        self.transition = transition
    }

    /// Stops the slideshow; the external display goes back to its holding screen.
    func end() {
        isPresenting = false
        frame = nil
        adjustment = .identity
        isAdvancing = true
    }
}

// MARK: - ExternalDisplaySceneDelegate

/// Owns the window on an external display.
///
/// Named by ``PhotosAppDelegate`` for scenes with the external-display role only; the app's own
/// scene stays with SwiftUI's `WindowGroup`.
@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let service = ExternalDisplayService.shared
        let host = UIHostingController(rootView: ExternalDisplayView().environmentObject(service))
        host.view.backgroundColor = .black

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.isHidden = false
        self.window = window

        service.displayDidConnect()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        ExternalDisplayService.shared.displayDidDisconnect()
    }
}

// MARK: - PhotosAppDelegate

/// Routes the external-display scene to ``ExternalDisplaySceneDelegate``, and answers the
/// orientation question for ``OrientationLock``.
///
/// Every other role gets a plain configuration, which SwiftUI fills in with its own delegate — so
/// the `WindowGroup` in ``NeutrinoPhotosApp`` behaves exactly as it did without this.
@MainActor
final class PhotosAppDelegate: NSObject, UIApplicationDelegate {

    /// Once implemented, this replaces the Info.plist orientation list rather than narrowing it,
    /// so the unlocked value has to restate it.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.current
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        guard role == .windowExternalDisplayNonInteractive else {
            return UISceneConfiguration(name: nil, sessionRole: role)
        }
        // Named after the Info.plist entry in project.yml, which is what makes iOS offer this
        // scene at all rather than mirroring.
        let configuration = UISceneConfiguration(name: "External Display", sessionRole: role)
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        return configuration
    }
}

// MARK: - OrientationLock

/// Holds the phone in one orientation while it is the slideshow's remote.
///
/// With the photographs on a television the phone is a control panel in somebody's hand, and
/// portrait is the shape its controls are laid out for. Left free, it would turn to landscape every
/// time it was tilted toward the room.
@MainActor
enum OrientationLock {

    /// What Info.plist declares, per idiom.
    static var unlocked: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    private(set) static var current: UIInterfaceOrientationMask = unlocked

    static func lock(_ mask: UIInterfaceOrientationMask) {
        apply(mask)
    }

    static func unlock() {
        apply(unlocked)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        guard mask != current else { return }
        current = mask
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        for scene in scenes {
            // Every controller in the presentation chain: the slideshow is a full-screen cover,
            // and it is the topmost one whose answer UIKit asks for.
            var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
