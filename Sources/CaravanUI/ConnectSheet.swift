import SwiftUI

/// Where a connection is described.
///
/// Last-used values live in the plain-text config at `$XDG_CONFIG_HOME/caravan`, and are
/// written when you connect rather than as you type: "last used" should mean used, not
/// typed and then cancelled. The password is deliberately not persisted at all — its home
/// is the Keychain, and until that exists, not storing it is the right failure mode.
struct ConnectSheet: View {
    let config: ConfigFile
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
        }
        .onAppear {
            settings = .lastUsed(from: config)
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
        .frame(width: 420, height: 460)
    }
}

#Preview {
    ConnectSheet(config: .shared) { _ in }
}
