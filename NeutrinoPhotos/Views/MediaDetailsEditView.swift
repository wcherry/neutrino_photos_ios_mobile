import SwiftUI

// MARK: - MediaDetailsEditView

/// Editing what a photograph says about itself: when it was taken, a title and a caption.
///
/// The date is the edit that matters most and the one with consequences — the timeline sorts on
/// it, so a scan from 1998 dated the day it was scanned moves to 1998 when corrected. The footer
/// says so, because a photograph disappearing from the top of the library is otherwise alarming.
struct MediaDetailsEditView: View {

    let item: MediaItem

    @EnvironmentObject private var library: PhotoLibraryService
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var captureDate: Date
    @State private var title: String
    @State private var caption: String
    @State private var isSaving = false
    @State private var error: String?

    init(item: MediaItem) {
        self.item = item
        _captureDate = State(initialValue: item.timelineDate)
        _title = State(initialValue: item.metadata?.title ?? "")
        _caption = State(initialValue: item.metadata?.caption ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Taken", selection: $captureDate,
                               in: ...Date.distantFuture,
                               displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("Your library is sorted by this date, so changing it moves the photo.")
                }

                Section("Title") {
                    TextField(item.displayName, text: $title)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    TextField("Add a caption", text: $caption, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Caption")
                } footer: {
                    // Said plainly because it is true and not obvious: the photograph is end-to-end
                    // encrypted, and these words are not.
                    Text("Titles and captions are stored with your library's searchable index, "
                         + "which isn't end-to-end encrypted.")
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await library.editDetails(id: item.id, captureDate: captureDate,
                                          title: title, caption: caption,
                                          publishingLocation: settings.publishesLocationMetadata)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
