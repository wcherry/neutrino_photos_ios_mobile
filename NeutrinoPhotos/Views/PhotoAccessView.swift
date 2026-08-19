import SwiftUI

// MARK: - PhotoAccessView

/// What the app may do with the device's own photo library, and how to change it.
///
/// Access is offered rather than demanded. Importing works without it — `PhotosPicker` selects out
/// of process and needs no permission at all — so this screen's job is to say what granting it would
/// *add*, not to stand between the user and their photographs. Nothing here prompts until a button
/// is pressed.
///
/// The three states that are not "full access" each get a different route back, because they are
/// different situations: not yet asked gets the prompt, limited gets the picker that widens the
/// selection, denied gets Settings, and restricted gets an explanation and no button — a device
/// under Screen Time or an MDM profile has no switch for the user to find.
struct PhotoAccessView: View {

    @EnvironmentObject private var deviceLibrary: DevicePhotoLibrary

    @State private var isRequesting = false

    var body: some View {
        List {
            statusSection
            whatItAddsSection
            comingSection
        }
        .navigationTitle("Photo Library")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            deviceLibrary.refresh()
            deviceLibrary.refreshItemCount()
        }
        .onChange(of: deviceLibrary.access) { _ in
            deviceLibrary.refreshItemCount()
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Access", value: deviceLibrary.access.displayName)
            if deviceLibrary.access.isUsable, let count = deviceLibrary.itemCount {
                LabeledContent(deviceLibrary.access == .limited ? "Items shared" : "Items on device",
                               value: "\(count)")
            }
            action
        } header: {
            Text("This Device")
        } footer: {
            Text(footerText)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch deviceLibrary.access {
        case .notDetermined:
            Button("Allow Photo Access") {
                isRequesting = true
                Task {
                    await deviceLibrary.requestAccess()
                    deviceLibrary.refreshItemCount()
                    isRequesting = false
                }
            }
            .disabled(isRequesting)
        case .limited:
            // The only way to widen a limited grant from inside the app: Settings offers the whole
            // library or nothing, and there is no way back to the picker except this call.
            Button("Select More Photos…") { deviceLibrary.presentLimitedPicker() }
            settingsLink(title: "Change in Settings")
        case .denied:
            // No second Allow button: iOS shows the system alert once per install and every call
            // after that returns the standing answer without displaying anything, so a button that
            // appeared to ask again would do nothing at all.
            settingsLink(title: "Open Settings")
        case .authorized, .restricted:
            EmptyView()
        }
    }

    private func settingsLink(title: String) -> some View {
        Button(title) {
            guard let url = DevicePhotoLibrary.settingsURL else { return }
            UIApplication.shared.open(url)
        }
    }

    private var footerText: String {
        switch deviceLibrary.access {
        case .notDetermined:
            return """
                   Importing works without this. Photo access adds what the picker cannot hand \
                   over — see below — and is what full-library import and automatic backup will \
                   need.
                   """
        case .authorized:
            return "Imports carry across everything Apple Photos knows about an item."
        case .limited:
            return """
                   You've shared some of your photo library. Everything works over exactly those \
                   items; the rest are invisible to this app, including to a future full-library \
                   import.
                   """
        case .denied:
            return """
                   Neutrino Photos can't see your photo library. Importing still works — the \
                   picker runs outside the app — but imported items keep only what their own file \
                   says, so a screenshot arrives dated today and a Live Photo arrives without its \
                   motion.
                   """
        case .restricted:
            return """
                   Photo access is turned off by a Screen Time or device management restriction, \
                   which this app can't change. Importing through the picker still works.
                   """
        }
    }

    // MARK: - What it adds

    private var whatItAddsSection: some View {
        Section {
            row("calendar", "The date it was taken", """
                A screenshot, a screen recording, or an edited export carries no EXIF date, so \
                without this it files itself under the day you uploaded it.
                """)
            row("heart", "Favorites", """
                Items you starred in Apple Photos arrive starred here.
                """)
            row("livephoto", "Live Photos", """
                The paired video is uploaded beside the still, so the motion is preserved and can \
                be saved back as a real Live Photo.
                """)
            row("camera.aperture", "RAW originals", """
                The picker hands back a JPEG rendering of a DNG. This gets the file your camera \
                actually wrote.
                """)
            row("mappin.and.ellipse", "Location", """
                Read from the library for pictures whose own GPS data was stripped by an editor.
                """)
        } header: {
            Text("What Access Adds")
        } footer: {
            Text("Everything here degrades rather than breaks. Without access, an import uses what the picture's own file says.")
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Not yet

    /// Named rather than implied. Access is the doorway to two epics that are not in this build, and
    /// a user who grants it should not be left wondering why nothing started importing.
    private var comingSection: some View {
        Section {
            HStack {
                Image(systemName: FeatureFlags.automaticBackup ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(FeatureFlags.automaticBackup ? .green : .secondary)
                Text("Automatic backup of new photos")
            }
            HStack {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text("Import the whole library at once")
            }
        } header: {
            Text("Not Here Yet")
        } footer: {
            Text("""
                 Both need this permission and neither is in this build. Until then, importing is \
                 what you pick in the photo picker.
                 """)
        }
    }
}
