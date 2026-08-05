import SwiftUI

/// Where a connection is described.
///
/// Last-used values persist through `@AppStorage`, which is a stopgap and marked as one:
/// the real home is the plain-text config under `$XDG_CONFIG_HOME/caravan`, alongside
/// the server list in stage 2. The password is deliberately not persisted — its home is
/// the Keychain, and until that exists, not storing it is the right failure mode.
struct ConnectSheet: View {
    let onConnect: (ConnectionSettings) -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastHost") private var host = "irc.libera.chat"
    @AppStorage("lastPort") private var port = 6697
    @AppStorage("lastUseTLS") private var useTLS = true
    @AppStorage("lastNick") private var nick = ""
    @AppStorage("lastAltNick") private var altNick = ""
    @AppStorage("lastIdent") private var ident = ""
    @AppStorage("lastRealName") private var realName = ""

    @State private var password = ""

    private var settings: ConnectionSettings {
        ConnectionSettings(
            host: host,
            port: UInt16(clamping: port),
            useTLS: useTLS,
            nick: nick,
            altNick: altNick,
            ident: ident,
            realName: realName,
            password: password
        )
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Hostname", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                Toggle("Use TLS", isOn: $useTLS)
                SecureField("Server password (optional)", text: $password)
            }
            Section("Identity") {
                TextField("Nickname", text: $nick)
                TextField("Alternate nickname", text: $altNick)
                TextField("Ident", text: $ident, prompt: Text("Defaults to the nickname"))
                TextField("Real name", text: $realName, prompt: Text("Defaults to the nickname"))
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect(settings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!settings.isValid)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 420, height: 460)
    }
}

#Preview {
    ConnectSheet { _ in }
}
