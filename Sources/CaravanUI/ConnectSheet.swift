import SwiftUI

/// Where a connection is described.
///
/// Last-used values live in the plain-text config at `$XDG_CONFIG_HOME/caravan`, and are
/// written when you connect rather than as you type: "last used" should mean used, not
/// typed and then cancelled.
///
/// **The two password fields come from and go to the Keychain**, keyed on the host, so
/// they arrive filled in. `caravan.conf` holds which host, which account and which
/// mechanism — never the secret.
struct ConnectSheet: View {
    let config: ConfigFile
    let credentials: any CredentialStore
    let onConnect: (ConnectionSettings) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var settings = ConnectionSettings()

    /// The port as a number the field can edit. `UInt16` has no `FormatStyle`, and a
    /// field bound to one that rejected 65536 by refusing to render would be worse than
    /// clamping on the way out.
    @State private var port = 6697

    var body: some View {
        Form {
            Section("Server") {
                TextField("Hostname", text: $settings.host)
                    // Changing the host changes whose credentials these are. Re-read on
                    // the way out of the field rather than per keystroke, which would
                    // hit the Keychain once per letter typed.
                    .onSubmit { settings.loadSecrets(from: credentials) }
                TextField("Port", value: $port, format: .number.grouping(.never))
                Toggle("Use TLS", isOn: $settings.useTLS)
                SecureField("Server password (optional)", text: $settings.password)
            }
            Section("Identity") {
                TextField("Nickname", text: $settings.nick)
                TextField("Alternate nickname", text: $settings.altNick)
                TextField(
                    "Ident",
                    text: $settings.ident,
                    prompt: Text("Defaults to the nickname")
                )
                TextField(
                    "Real name",
                    text: $settings.realName,
                    prompt: Text("Defaults to the nickname")
                )
            }
            authentication
        }
        .onAppear {
            settings = .lastUsed(from: config, credentials: credentials)
            port = Int(settings.port)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    var settings = settings
                    settings.port = UInt16(clamping: port)
                    onConnect(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!settings.isValid || port <= 0)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 460, height: 620)
    }

    /// The fields the chosen method actually uses, and no others.
    ///
    /// A password field beside `EXTERNAL` would be a lie about what is being sent: CertFP
    /// proves who you are with the TLS certificate and puts nothing on the wire.
    @ViewBuilder
    private var authentication: some View {
        Section("Authentication") {
            Picker("Method", selection: $settings.authentication) {
                ForEach(ConnectionSettings.AuthenticationChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            if settings.authentication.needsAccount {
                TextField(
                    "Account",
                    text: $settings.account,
                    prompt: Text("Usually your registered nickname")
                )
            }
            if settings.authentication.needsPassword {
                SecureField("Account password", text: $settings.accountPassword)
            }
            if settings.authentication == .saslExternal {
                TextField(
                    "Certificate",
                    text: $settings.certificateLabel,
                    prompt: Text("Keychain name of the client certificate")
                )
                Text(
                    """
                    The certificate has to be in your login keychain already, and its \
                    fingerprint registered with the network — `/msg NickServ CERT ADD`.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A certificate the system would not validate, and the question that follows.
///
/// Deliberately not an `alert`: a SHA-256 fingerprint is 95 characters and an alert body
/// is not where anyone can compare one. The fingerprint is selectable, because comparing it
/// against one published elsewhere means being able to copy it.
struct TrustSheet: View {
    let request: AppModel.TrustRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(headline, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(request.previousFingerprint == nil ? Color.primary : Color.red)

            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if let subject = request.certificate.subject {
                        row("Subject", subject)
                    }
                    row("SHA-256", request.certificate.sha256Fingerprint)
                    if let previous = request.previousFingerprint {
                        row("Previously", previous)
                    }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Don't Connect", role: .cancel) { request.answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Connect") { request.answer(true) }
                    // Never the default button. The safe answer is the one that happens
                    // when somebody hits Return without reading, and that is not this one.
                    .keyboardShortcut(.none)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private var headline: String {
        request.previousFingerprint == nil
            ? "Caravan cannot verify \(request.host)"
            : "The certificate for \(request.host) has changed"
    }

    private var symbol: String {
        request.previousFingerprint == nil
            ? "lock.trianglebadge.exclamationmark" : "exclamationmark.octagon"
    }

    private var explanation: String {
        request.previousFingerprint == nil
            ? """
            The server presented a certificate the system will not validate — usually a \
            self-signed one. Connect only if this fingerprint is the one the network \
            publishes.
            """
            : """
            This is not the certificate you accepted last time. That happens when a \
            server rotates its certificate, and it also happens when somebody is reading \
            the connection. Check the fingerprint before continuing.
            """
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ConnectSheet(config: .shared, credentials: EphemeralCredentialStore()) { _ in }
}
