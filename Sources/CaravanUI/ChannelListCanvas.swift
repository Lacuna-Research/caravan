import IRCProtocol
import SwiftUI

/// What `/list` answers with: every channel on the network, filtered down to the one you
/// were looking for.
///
/// **A canvas, not a buffer** (§10) — no header band, no input box, no activity state — and
/// **one canvas rather than one per network**, with the network as a picker in its own
/// header. A channel list is consulted rather than kept, and a permanent tree row per
/// network for something opened twice a month is the wrong trade against §12's tree.
///
/// The whole surface is built around one number: Libera answers `LIST` with about
/// twenty-two thousand channels. Rows arrive coalesced (``ChannelDirectory``), the filter is
/// recomputed once per arrival rather than once per row, and the search is plain substring
/// matching over a corpus folded on the way in.
struct ChannelListCanvas: View {
    let model: AppModel

    @State private var query = ChannelListQuery()
    /// What the user has typed, before the debounce hands it to ``query``.
    @State private var searchText = ""
    @State private var minimumText = ""
    @State private var maximumText = ""
    @State private var sortOrder = [KeyPathComparator(\ChannelListing.members, order: .reverse)]
    @State private var selection = Set<IRCChannelName>()
    /// The filtered, sorted rows the table draws. Recomputed on a change to its three
    /// inputs rather than inside `body`, so an unrelated redraw does not re-sort
    /// twenty-two thousand rows.
    @State private var rows: [ChannelListing] = []
    @State private var isConfirmingBulkJoin = false

    private var connection: ConnectionViewModel? { model.channelListConnection }
    private var directory: ChannelDirectory? { connection?.channelDirectory }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filters
            Divider()
            table
            Divider()
            footer
        }
        .onChange(of: directory?.listings ?? [], initial: true) { _, _ in recompute() }
        .onChange(of: query) { _, _ in recompute() }
        .onChange(of: sortOrder) { _, _ in recompute() }
        // **The debounce.** A keystroke must not cost a pass over the whole list; a pause
        // in typing may. `.task(id:)` cancels the pending sleep on the next character,
        // which is the entire mechanism.
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            query.text = searchText
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if model.connections.count > 1 {
                Picker("Network", selection: networkBinding) {
                    ForEach(model.connections) { connection in
                        Text(connection.networkName).tag(connection.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            } else if let connection {
                Text(connection.networkName).font(.headline)
            }

            Spacer()

            if directory?.isCollecting == true {
                ProgressView().controlSize(.small)
                // Honest about what the button does: `LIST` has no cancel in the protocol,
                // and the rest of the reply is coming whatever is clicked here.
                Button("Stop Collecting") { directory?.stopCollecting() }
                    .help("Stops filling this list. The server sends the rest regardless.")
            } else {
                Button(directory?.listings.isEmpty == false ? "Refresh" : "Get List") {
                    Task { await requestList() }
                }
                .disabled(connection?.isConnected != true)
            }
        }
        .padding(10)
    }

    private var networkBinding: Binding<UUID?> {
        Binding(
            get: { model.channelListConnection?.id },
            set: { model.channelListNetwork = $0 }
        )
    }

    // MARK: - Filters

    private var filters: some View {
        HStack(spacing: 12) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 280)

            Toggle("Names", isOn: $query.searchesNames).toggleStyle(.checkbox)
            Toggle("Topics", isOn: $query.searchesTopics).toggleStyle(.checkbox)

            Divider().frame(height: 16)

            Text("Members")
            boundField("min", text: $minimumText) { query.minimumMembers = $0 }
            Text("–").foregroundStyle(.secondary)
            boundField("max", text: $maximumText) { query.maximumMembers = $0 }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// An empty field means *no bound*, which is not the same as zero — a minimum of zero
    /// and no minimum happen to agree, but a maximum of zero hides everything.
    private func boundField(
        _ prompt: String,
        text: Binding<String>,
        set: @escaping (Int?) -> Void
    ) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .onChange(of: text.wrappedValue) { _, new in
                set(new.isEmpty ? nil : Int(new))
            }
    }

    // MARK: - Table

    @ViewBuilder
    private var table: some View {
        if rows.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Channel", value: \.name) { listing in
                    Text(listing.displayName).font(.system(.body, design: .monospaced))
                }
                .width(min: 140, ideal: 200)

                TableColumn("Members", value: \.members) { listing in
                    Text(listing.members.formatted())
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 70, max: 100)

                TableColumn("Topic", value: \.topic) { listing in
                    Text(listing.topic).lineLimit(1).truncationMode(.tail)
                }
            }
            .contextMenu(forSelectionType: IRCChannelName.self) { names in
                Button(names.count > 1 ? "Join \(names.count) Channels" : "Join") {
                    join(names)
                }
            } primaryAction: { names in
                // Table's primary action *is* the double-click.
                join(names)
            }
            // The keyboard half of the same act. A table you can arrow through but only
            // leave with the mouse is a table that stops halfway.
            .onKeyPress(.return) {
                guard !selection.isEmpty else { return .ignored }
                join(selection)
                return .handled
            }
            .confirmationDialog(
                "Join \(selection.count) channels?",
                isPresented: $isConfirmingBulkJoin
            ) {
                Button("Join \(selection.count)") { performJoin(selection) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each opens a window and announces you to the channel.")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if connection == nil {
            Text("Connect to a network to browse its channels.")
                .foregroundStyle(.secondary)
        } else if directory?.isCollecting == true {
            ProgressView("Asking the server…")
        } else if directory?.listings.isEmpty != false {
            VStack(spacing: 10) {
                Text("No channel list yet.").foregroundStyle(.secondary)
                Button("Get List") { Task { await requestList() } }
                    .disabled(connection?.isConnected != true)
            }
        } else {
            Text("No channel matches these filters.").foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(summary).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if connection?.isConnected == false {
                Label("Not connected — joining is unavailable", systemImage: "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let total = directory?.listings.count ?? 0
        guard total > 0 else { return "" }
        let shown = rows.count
        let suffix = directory?.isCollecting == true ? ", still arriving" : ""
        return shown == total
            ? "\(total.formatted()) channels\(suffix)"
            : "\(shown.formatted()) of \(total.formatted()) channels\(suffix)"
    }

    // MARK: - Actions

    private func recompute() {
        let listings = directory?.listings ?? []
        rows = query.apply(to: listings).sorted(using: sortOrder)
    }

    private func requestList() async {
        guard let connection else { return }
        await model.submit("/list", from: nil, on: connection)
    }

    /// Prompt 9's Open All rule, at the same threshold and for the same reason: five is
    /// where a click that opens windows stops being obviously what you meant.
    private func join(_ names: Set<IRCChannelName>) {
        guard !names.isEmpty else { return }
        if names.count > 5 {
            selection = names
            isConfirmingBulkJoin = true
            return
        }
        performJoin(names)
    }

    private func performJoin(_ names: Set<IRCChannelName>) {
        guard let connection else { return }
        Task { await model.join(channels: Array(names), on: connection) }
    }
}
