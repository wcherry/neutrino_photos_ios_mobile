import SwiftUI

// MARK: - LoginView

/// Sign-in against the Neutrino account.
///
/// Credentials go straight to `AuthService` and are never held in the Keychain, `UserDefaults`, or
/// anywhere else; only the tokens the exchange returns are persisted.
struct LoginView: View {

    @EnvironmentObject private var authService: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var serverHost = AuthService.baseURL
    @State private var showServerField = false

    @FocusState private var focusedField: Field?

    private enum Field { case email, password, server }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { submit() }
                } header: {
                    header
                } footer: {
                    if let error = authService.loginError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if authService.isLoggingIn {
                                ProgressView()
                            } else {
                                Text("Sign In").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }

                Section {
                    DisclosureGroup("Server", isExpanded: $showServerField) {
                        TextField("https://neutrino.example.com", text: $serverHost)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .server)
                            .onChange(of: serverHost) { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                                UserDefaults.standard.set(trimmed, forKey: AuthService.serverHostKey)
                            }
                    }
                } footer: {
                    // Naming the device here is honest about what signing in registers, and matches
                    // what the account's device list will show.
                    Text("This device will register as \u{201C}\(DeviceIdentity.deviceName)\u{201D}.")
                }
            }
            .navigationTitle("Neutrino Photos")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Sign in to your Neutrino account")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .textCase(nil)
    }

    // MARK: - Actions

    private var canSubmit: Bool {
        !authService.isLoggingIn
            && !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            await authService.login(email: email.trimmingCharacters(in: .whitespaces),
                                    password: password)
            // Cleared whether or not the attempt succeeded — a failed login should not leave the
            // password sitting in a live view's state.
            password = ""
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthService())
}
