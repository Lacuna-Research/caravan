import IRCProtocol
import SwiftUI

/// What `/list` answers with: every channel on the network, filtered down to the one you
/// were looking for.
///
/// **A canvas, not a buffer** (§10) — no header band, no input box, no activity state — and
/// **one per network**, reached from the row at the top of that network's group in the tree.
/// A channel list is a property of a network the same way its channels are, so the network
/// is the row you clicked rather than a picker to find inside the canvas.
///
/// Rows arrive coalesced (``ChannelDirectory``), the filter is recomputed once per arrival
/// rather than once per row, and the search is plain substring matching over a corpus folded
/// on the way in — because the list can be thousands of channels arriving in a few seconds.
struct ChannelListCanvas: View {
    let model: AppModel
    let connection: ConnectionViewModel

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

    private var directory: ChannelDirectory { connection.channelDirectory }

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
        .onChange(of: directory.listings, initial: true) { _, _ in recompute() }
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

    /// The network is named here as well as in the tree, because the canvas detaches into a
    /// window of its own — where the tree is not there to say which one this is.
    private var header: some View {
        HStack(spacing: 12) {
            Text(connection.networkName).font(.headline)

            Spacer()

            if directory.isCollecting {
                ProgressView().controlSize(.small)
                // Honest about what the button does: `LIST` has no cancel in the protocol,
                // and the rest of the reply is coming whatever is clicked here.
                Button("Stop Collecting") { directory.stopCollecting() }
                    .help("Stops filling this list. The server sends the rest regardless.")
            } else {
                Button(directory.listings.isEmpty ? "Get List" : "Refresh") {
                    Task { await requestList() }
                }
                .disabled(!connection.isConnected)
            }
        }
        .padding(10)
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
        if directory.isCollecting {
            ProgressView("Asking the server…")
        } else if directory.listings.isEmpty {
            VStack(spacing: 10) {
                Text("No channel list yet.").foregroundStyle(.secondary)
                Button("Get List") { Task { await requestList() } }
                    .disabled(!connection.isConnected)
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
            if !connection.isConnected {
                Label("Not connected — joining is unavailable", systemImage: "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let total = directory.listings.count
        guard total > 0 else { return "" }
        let shown = rows.count
        let suffix = directory.isCollecting ? ", still arriving" : ""
        return shown == total
            ? "\(total.formatted()) channels\(suffix)"
            : "\(shown.formatted()) of \(total.formatted()) channels\(suffix)"
    }

    // MARK: - Actions

    private func recompute() {
        rows = query.apply(to: directory.listings).sorted(using: sortOrder)
    }

    private func requestList() async {
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
        Task { await model.join(channels: Array(names), on: connection) }
    }
}
