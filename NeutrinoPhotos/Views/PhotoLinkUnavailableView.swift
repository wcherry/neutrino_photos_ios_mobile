import SwiftUI

// MARK: - PhotoLinkUnavailableView

/// What a `/open/photo/<id>` link shows when this account's library doesn't hold that photo —
/// Epic 13's verification step 8: a clear screen, not a crash or an endless spinner.
///
/// Deliberately does not say *which* of the reasons applies. The app cannot tell "deleted" from
/// "somebody else's" without asking the server about a file it may have no right to know exists.
struct PhotoLinkUnavailableView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("This photo isn't available")
                    .font(.title3.weight(.semibold))
                Text("It may have been deleted, or it belongs to an account you're not signed in "
                     + "to on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
