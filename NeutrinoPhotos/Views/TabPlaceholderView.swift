import SwiftUI

// MARK: - TabPlaceholderView

/// What a tab shows when the epic behind it hasn't landed.
///
/// The shell has a fixed shape — Library, Albums, Search, Settings — so tabs don't appear and
/// disappear under the user's thumb as flags flip between builds. That means some tab may have
/// nothing behind it, and this is what stands there: the name of the thing, and a sentence saying
/// it isn't built rather than a blank screen or a spinner that never resolves.
struct TabPlaceholderView: View {

    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    TabPlaceholderView(title: "Search isn't here yet",
                       systemImage: "magnifyingglass",
                       message: "Finding a photo by name, date, or camera needs an index of the library on this device.")
}
