import Foundation
import UIKit

// MARK: - DeviceIdentity

/// This installation's identity, as the Neutrino auth service records it.
///
/// There is no separate device-registration endpoint on the server: a device registers itself by
/// naming itself in the `X-Device-Name` header when it logs in, which is what populates
/// `device_name` on the session row that `GET /api/v1/auth/sessions` later lists and
/// `DELETE /api/v1/auth/sessions/{id}` revokes. Registration is therefore a property of login, not
/// a call of its own — and this type is what login sends.
enum DeviceIdentity {

    // MARK: - Keys

    static let deviceNameKey = "nphoto.device_name"

    // MARK: - Device name

    /// The name this device registers under, e.g. "Will's iPhone — Neutrino Photos".
    ///
    /// A user-set override wins; otherwise the device's own name is used. The app name is appended
    /// so the sessions list distinguishes this app from Drive, Docs, and Notes on the same
    /// hardware, which otherwise all report the identical `UIDevice.name`.
    static var deviceName: String {
        if let custom = UserDefaults.standard.string(forKey: deviceNameKey),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return "\(UIDevice.current.name) — Neutrino Photos"
    }

    /// Overrides the registered device name. Passing nil (or blank) restores the default.
    static func setDeviceName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: deviceNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: deviceNameKey)
        }
    }

    /// Header sent on login. Kept here so `AuthService` and its tests agree on it.
    static let deviceNameHeader = "X-Device-Name"
}
