import SwiftUI

/// One server-list entry, as a form.
///
/// **Writes straight through**, like every other surface in this app: no Apply, nothing to
/// cancel, no pending state that can disagree with the file. The one field that cannot
/// simply be assigned is the name, because renaming has to carry `binding.N` and
/// `order.<name>.*` with it — so it commits on blur rather than per keystroke, and
/// `ServerList.rename(_:to:movingKeysIn:)` does the moving.
struct ServerEditor: View {
    let model: AppModel
    let entry: ServerEntry

    /// The Dashboard's selection, so a rename can take it along.
    ///
    /// Without it the list selects a name that no longer exists the moment the entry is
    /// renamed, the detail pane falls back to "no server selected", and this view is torn
    /// down — during which SwiftUI writes its fields' last values back through their
    /// bindings, under the *old* name. That resurrected the entry it had just renamed away
    /// from, leaving two. Found in the acceptance run, as a duplicate in `servers.conf`.
    @Binding var selection: String?

    /// The name being typed. Held separately because a half-typed name is not yet a valid
    /// identifier — `lib` on the way to `libera` would rename the entry three times and
    /// drag the user's bindings along for each one.
    @State private var draftName: String
    @State private var nameError: String?
    @FocusState private var isEditingName: Bool

    @State private var serverPassword: String = ""
    @State private var accountPassword: String = ""

    init(model: AppModel, entry: ServerEntry, selection: Binding<String?> = .constant(nil)) {
        self.model = model
        self.entry = entry
        self._selection = selection
        self._draftName = State(initialValue: entry.name)
    }

    var body: some View {
        Form {
            identity
            connection
            authentication
            onConnect
            actions
        }
        .formStyle(.grouped)
        .onAppear(perform: loadSecrets)
    }

    // MARK: - Sections

    private var identity: some View {
        Section("Name") {
            TextField("Name", text: $draftName)
                .focused($isEditingName)
                .onSubmit(commitName)
                .onChange(of: isEditingName) { _, editing in
                    if !editing { commitName() }
                }
            if let nameError {
                Label(nameError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(
                "How Caravan refers to this network — in the tree, in your \u{2318}1–9 "
                    + "bindings, and as `\(draftName.isEmpty ? "name" : draftName)/#channel` "
                    + "from a script. Lower case, no dots or slashes. Renaming brings your "
                    + "bindings and window order with it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("Group", text: binding(\.group))
            Toggle("Favourite", isOn: binding(\.isFavourite))
        }
    }

    private var connection: some View {
        Section("Connection") {
            TextField("Hostname", text: binding(\.host))
            TextField("Port", value: binding(\.port), format: .number.grouping(.never))
            Toggle("Use TLS", isOn: binding(\.useTLS))
            SecureField("Server password (optional)", text: $serverPassword)
                .onChange(of: serverPassword) { store(.serverPassword, serverPassword) }
            TextField("Bouncer network", text: binding(\.bouncerNetwork))
            Text(
                "Only for a bouncer that cannot list its own networks. Caravan finds them "
                    + "by itself where the bouncer supports it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var authentication: some View {
        Section("Authentication") {
            Picker("Method", selection: binding(\.authentication)) {
                ForEach(ConnectionSettings.AuthenticationChoice.allCases) {
                    Text($0.label).tag($0)
                }
            }
            if entry.authentication.needsAccount {
                TextField("Account", text: binding(\.account))
            }
            if entry.authentication.needsPassword {
                SecureField("Password", text: $accountPassword)
                    .onChange(of: accountPassword) { store(.account, accountPassword) }
            }
            if entry.authentication == .saslExternal {
                TextField("Certificate label", text: binding(\.certificateLabel))
                Text(
                    "The name of a client certificate already in your login keychain. "
                        + "Caravan does not create one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // Said on the surface, not only in the source, because it is the sentence a
            // user weighing whether to type a password here needs to have read.
            Label(
                "Passwords go to the macOS Keychain. servers.conf never holds one.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var onConnect: some View {
        Section("On connect") {
            Toggle("Connect on startup", isOn: binding(\.connectsOnStartup))
            LabeledContent("Join channels") {
                TextField(
                    "#swift #vapor",
                    text: Binding(
                        get: { entry.autojoin.joined(separator: " ") },
                        set: { value in
                            // Spaces or commas, because people type a channel list both
                            // ways and neither is wrong.
                            let names = value.split(whereSeparator: { $0 == " " || $0 == "," })
                            update { $0.autojoin = names.map(String.init) }
                        }
                    )
                )
                .labelsHidden()
            }
            LabeledContent("Perform") {
                TextField(
                    "/msg NickServ identify \u{2026}",
                    text: Binding(
                        get: { entry.perform.joined(separator: "; ") },
                        set: { value in
                            update {
                                $0.perform =
                                    value
                                    .split(separator: ";")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            }
                        }
                    )
                )
                .labelsHidden()
            }
            Text(
                "Commands run once the server has welcomed you, before the channels are "
                    + "joined — which is the order that matters, since a `+r` channel turns "
                    + "away anyone who has not identified. Separate them with `;`."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        Section {
            HStack {
                Button(isOpen ? "Go to \(entry.name)" : "Connect") {
                    Task { await model.connect(to: entry) }
                }
                // **No default action.** A form full of text fields must not have a button
                // that fires on Return: the live run typed a new name, pressed Return to
                // commit it, and connected instead. Nothing here needs a default — the
                // editor writes through, so Connect is the one deliberate act on the pane.
                .disabled(!entry.isValid)
                Spacer()
                Button("Delete Server", role: .destructive) {
                    model.servers.remove(entry.name)
                }
            }
        }
    }

    // MARK: - Plumbing

    private var isOpen: Bool {
        model.connections.contains { $0.networkName == entry.name }
    }

    /// A binding straight onto the stored entry: read from the list, write through it.
    ///
    /// The list is the single copy. A `@State` mirror of the entry would be a second one,
    /// and two copies of a setting is the thing this app has avoided everywhere else.
    private func binding<Value>(
        _ path: WritableKeyPath<ServerEntry, Value>
    ) -> Binding<Value> {
        Binding(
            get: { entry[keyPath: path] },
            set: { value in update { $0[keyPath: path] = value } }
        )
    }

    /// **Refuses to write an entry that is no longer in the list.** A binding firing during
    /// teardown — which is how SwiftUI returns a field to its last value — would otherwise
    /// recreate an entry that had just been renamed or deleted.
    private func update(_ change: (inout ServerEntry) -> Void) {
        guard model.servers.entry(named: entry.name) != nil else { return }
        var updated = entry
        change(&updated)
        model.servers.save(updated)
    }

    /// Renames, or explains why not.
    ///
    /// Refuses rather than mangling: silently turning `My Server` into `my-server` would
    /// leave the user with an identifier they did not choose, in the one field whose whole
    /// job is to be theirs.
    private func commitName() {
        let candidate = draftName.trimmingCharacters(in: .whitespaces)
        guard candidate != entry.name else {
            nameError = nil
            return
        }
        guard NetworkName.isValid(candidate) else {
            nameError =
                "Names use lower-case letters, digits, `-` and `_` — no spaces, dots or "
                + "slashes. Try \u{201C}\(NetworkName.sanitised(candidate))\u{201D}."
            draftName = entry.name
            return
        }
        guard model.servers.entry(named: candidate) == nil else {
            nameError = "There is already a server called \(candidate)."
            draftName = entry.name
            return
        }
        nameError = nil
        guard model.renameServer(entry.name, to: candidate) else { return }
        // The list has to follow, or the selection names a row that is gone.
        selection = candidate
    }

    private func loadSecrets() {
        // Timed because it is two synchronous Keychain calls on the main thread, and
        // `SecItemCopyMatching` is entitled to block — see `PLAN.md`'s **Still open**.
        TimingLog.measure("editor: read \(entry.name) secrets from the keychain") {
            serverPassword = model.credentials.password(.serverPassword, host: entry.host) ?? ""
            accountPassword = model.credentials.password(.account, host: entry.host) ?? ""
        }
    }

    private func store(_ kind: CredentialKind, _ value: String) {
        guard !entry.host.isEmpty else { return }
        model.credentials.setPassword(value.isEmpty ? nil : value, kind, host: entry.host)
    }
}
