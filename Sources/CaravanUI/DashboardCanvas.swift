import SwiftUI

/// The server list, and the app's front door (§13).
///
/// **A canvas, not a buffer** — the same kind of surface as Settings & Debug (§10), and
/// therefore a peer row *above* the networks rather than the root of the tree. The two
/// canvases bracket the buffer list, which keeps the tree's root level meaningful and stops
/// one click collapsing everything.
///
/// **It is also the empty state.** First run lands here with nothing connected, which is
/// why there is no onboarding flow and no wizard: the thing a new user needs is a list with
/// an Add button, and that is the same thing an existing user needs.
///
/// Statistics, ping times, netsplit logs and activity graphs are all §13's "way down the
/// road" and are stage 4's; the part that matters early is the list and connecting.
struct DashboardCanvas: View {
    let model: AppModel

    @State private var selection: String?
    @State private var isAdding = false

    private var entries: [ServerEntry] { model.servers.entries }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detail
                .frame(minWidth: 380)
        }
        .onAppear {
            // Land on something: a detail pane showing nothing beside a list with rows in
            // it reads as broken rather than as unselected.
            if selection == nil { selection = entries.first?.name }
        }
    }

    // MARK: - The list

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(grouped, id: \.name) { group in
                        Section(group.name.isEmpty ? "Servers" : group.name) {
                            ForEach(group.entries) { entry in
                                ServerRow(entry: entry, isOpen: isOpen(entry))
                                    .tag(entry.name)
                                    .onTapGesture(count: 2) { connect(entry) }
                                    .contextMenu { menu(for: entry) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack(spacing: 8) {
                Button("Add Server", systemImage: "plus") { add() }
                    .labelStyle(.titleAndIcon)
                Spacer()
            }
            .padding(10)
            .background(.bar)
        }
    }

    /// Ungrouped first, then alphabetically — the order `ServerList.entries` already
    /// produces, chunked so `Section` can draw the headings.
    private var grouped: [(name: String, entries: [ServerEntry])] {
        var groups: [(name: String, entries: [ServerEntry])] = []
        for entry in entries {
            if groups.last?.name == entry.group {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((entry.group, [entry]))
            }
        }
        return groups
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No servers yet", systemImage: "network")
        } description: {
            Text("Add a server to connect to. Caravan keeps the list in servers.conf.")
        } actions: {
            Button("Add Server") { add() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for entry: ServerEntry) -> some View {
        Button(isOpen(entry) ? "Go to \(entry.name)" : "Connect") { connect(entry) }
        Button(entry.isFavourite ? "Remove from Favourites" : "Add to Favourites") {
            var updated = entry
            updated.isFavourite.toggle()
            model.servers.save(updated)
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.servers.remove(entry.name)
            if selection == entry.name { selection = entries.first?.name }
        }
    }

    // MARK: - The detail

    @ViewBuilder
    private var detail: some View {
        if let name = selection, let entry = model.servers.entry(named: name) {
            ServerEditor(model: model, entry: entry, selection: $selection)
                // Rebuilt per entry: the editor holds the fields being typed into, and
                // SwiftUI would otherwise carry one server's half-typed host into the next.
                .id(entry.name)
        } else {
            ContentUnavailableView(
                "No server selected",
                systemImage: "sidebar.left",
                description: Text("Pick a server on the left, or add one.")
            )
        }
    }

    private func isOpen(_ entry: ServerEntry) -> Bool {
        model.connections.contains { $0.networkName == entry.name }
    }

    private func connect(_ entry: ServerEntry) {
        Task { await model.connect(to: entry) }
    }

    /// A new entry, named from nothing in particular and immediately editable.
    ///
    /// Created rather than drafted: the list writes through like every other surface in
    /// this app, so there is nothing to cancel and no pending state — the same rule the
    /// Options tabs follow. An unwanted one is deleted from the same menu.
    private func add() {
        let name = NetworkName.unique("new-server", taken: model.servers.names)
        model.servers.save(ServerEntry(name: name, host: ""))
        selection = name
        isAdding = true
    }
}

/// One row: the name, its group's business, and whether it is open right now.
private struct ServerRow: View {
    let entry: ServerEntry
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Green for open, matching the tree's network row exactly — the same fact
            // shown the same way in both places.
            Circle()
                .fill(isOpen ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                Text(entry.host.isEmpty ? "no host yet" : entry.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // **Said on the row, not only in the editor.** Two of the shipped defaults —
            // Undernet and QuakeNet — offer no TLS at all, and a cleartext connection the
            // user cannot see is the part actually worth avoiding. Marked for any entry
            // without TLS, not just those two: a hand-written one deserves the same warning.
            if !entry.useTLS && !entry.host.isEmpty {
                Image(systemName: "lock.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Not encrypted — this network offers no TLS")
                    .accessibilityLabel("Not encrypted")
            }
            if entry.isFavourite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Favourite")
            }
            if entry.connectsOnStartup {
                Image(systemName: "power")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Connects on startup")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
