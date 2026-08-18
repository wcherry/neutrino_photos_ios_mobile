import SwiftUI
import UniformTypeIdentifiers

// MARK: - KeyImportView

/// Brings the account's end-to-end encryption key onto this device.
///
/// Two ways in, both of which start on the web app's Settings > Encryption page: the key file it
/// exports, or its contents pasted. (The sibling apps also scan a PIN-protected QR code; that path
/// needs the camera and a decrypt step, and is not in this build.)
///
/// The key is validated before it is stored — a public and private half that do not pair would
/// otherwise be discovered later, as an upload nobody can ever decrypt.
struct KeyImportView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var pastedText = ""
    @State private var showsFileImporter = false
    @State private var error: String?
    @State private var imported = false

    // MARK: - Body

    var body: some View {
        List {
            Section {
                Button {
                    showsFileImporter = true
                } label: {
                    Label("Choose Key File", systemImage: "doc.badge.plus")
                }
            } header: {
                Text("From a file")
            } footer: {
                Text("The JSON file the Neutrino web app exports from Settings > Encryption.")
            }

            Section {
                TextEditor(text: $pastedText)
                    .frame(minHeight: 120)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Import Pasted Key") { importPasted() }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Paste")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if imported {
                Section {
                    Label("Key imported", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }

            Section {
                Text("""
                     The key is stored in this device's Keychain, marked so it is never carried to \
                     another device in an iCloud backup. Neutrino never receives it.
                     """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Encryption Key")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showsFileImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleFile(result)
        }
    }

    // MARK: - Import

    private func importPasted() {
        store(Data(pastedText.utf8))
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            // A file picked from another app arrives as a security-scoped URL: without this the
            // read fails with a permission error that reads like a corrupt file.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            store(try Data(contentsOf: url))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func store(_ data: Data) {
        do {
            let bundle = try KeyImportService.importKey(from: data)
            KeyImportService.storeKeys(bundle)
            error = nil
            imported = true
            pastedText = ""
        } catch {
            self.error = error.localizedDescription
            imported = false
        }
    }
}
