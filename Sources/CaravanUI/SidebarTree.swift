import IRCProtocol
import SwiftUI

/// The buffer tree: channels nested under their network, always.
///
/// Two rules from the design notes shape every line of this:
///
/// - **Every row is an ordinary selectable row.** Networks are not smaller, and not
///   styled as section headers — same text size as channels, differentiated by decoration
///   only. A row that looks like a header but behaves as an item is a contradiction users
///   have been trained out of by Finder and Mail.
/// - **The network row *is* the status buffer's entry.** mIRC carried a separate status
///   node beneath the network; folding them together removes a row and a concept.
///
/// The tree is monospaced, unlike every other macOS sidebar. Both sigils are one cell
/// wide, so `#` forms a clean column and names never shift.
struct SidebarTree: View {
    /// The sigil a query row wears, where a channel wears its own `#`.
    static let querySigil = "•"

    @Bindable var model: AppModel

    @Environment(\.chatFont) private var chatFont

    var body: some View {
        List(selection: $model.selection) {
            // One group per network, and a bouncer's upstream networks are siblings of the
            // direct ones rather than nested under it. Nesting would make the tree two
            // levels deep for a bouncer and one for a direct connection, which is exactly
            // the UI caring which mode is in play.
            ForEach(model.connections) { connection in
                NetworkGroup(model: model, connection: connection)
            }
        }
        .listStyle(.sidebar)
        .font(chatFont)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            settingsAndDebugRow
        }
    }

    /// The canvas's row, pinned to the bottom of the tree.
    ///
    /// In the tree without being a buffer: the tree is a navigation list rather than
    /// strictly a list of buffers (§10). Pinned rather than listed, because it must not
    /// drift below thirty channels — and it carries no activity dot, because activity is
    /// a concept belonging to buffers only.
    private var settingsAndDebugRow: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                model.showSettingsAndDebug()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .frame(width: 7)
                    Text("Settings & Debug")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(chatFont)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(model.isShowingCanvas ? Color.accentColor.opacity(0.2) : Color.clear)
        }
        .background(.bar)
    }
}

/// One network and its channels.
///
/// Its own view so the expansion binding can hang off the *connection* rather than off a
/// single flag on the app — with two networks open, one flag collapses both.
private struct NetworkGroup: View {
    let model: AppModel
    @Bindable var connection: ConnectionViewModel

    var body: some View {
        DisclosureGroup(isExpanded: $connection.isExpanded) {
            ForEach(connection.channels) { buffer in
                let item = AppModel.SidebarItem.channel(
                    connection: connection.id,
                    channel: buffer.name
                )
                ChannelRow(
                    buffer: buffer,
                    digit: model.bindings.digit(for: model.binding(for: item))
                )
                .tag(item)
                .contextMenu { BindToMenu(model: model, item: item) }
            }
            // **Queries after channels, in the same list** (§12). Not a labelled section:
            // one flat list keeps channel positions stable as transient PMs come and go,
            // without spending a row of chrome on a header.
            ForEach(connection.queries) { buffer in
                let item = AppModel.SidebarItem.query(
                    connection: connection.id,
                    nick: buffer.nick
                )
                QueryRow(buffer: buffer, digit: model.bindings.digit(for: model.binding(for: item)))
                    .tag(item)
                    .contextMenu {
                        Button("Close Conversation") {
                            connection.closeQuery(buffer.nick)
                        }
                        Divider()
                        BindToMenu(model: model, item: item)
                    }
            }
        } label: {
            NetworkRow(
                connection: connection,
                digit: model.bindings.digit(for: model.binding(for: .status(connection.id)))
            )
            .tag(AppModel.SidebarItem.status(connection.id))
            .contextMenu {
                Button(connection.isConnected ? "Disconnect" : "Connect") {
                    Task {
                        if connection.isConnected {
                            await connection.disconnect()
                        } else {
                            await connection.connect()
                        }
                    }
                }
                Button("Close Network") {
                    Task { await model.close(connection) }
                }
                Divider()
                BindToMenu(model: model, item: .status(connection.id))
            }
        }
    }
}

/// `Bind to ▸ 1…9`, with the taken digits shown as taken (§11).
///
/// **A submenu rather than a bespoke affordance**, and deliberately so: the design notes
/// call this "the general pattern for the app, not a one-off" — many features will compete
/// for discoverability, and a consistent submenu is the answer to all of them rather than a
/// different control each time.
private struct BindToMenu: View {
    let model: AppModel
    let item: AppModel.SidebarItem

    var body: some View {
        if let binding = model.binding(for: item) {
            let current = model.bindings.digit(for: binding)
            Menu("Bind to") {
                ForEach(Array(BufferBindings.digits), id: \.self) { digit in
                    Button(label(for: digit, current: current)) {
                        model.bindings.bind(binding, to: digit)
                    }
                }
                if let current {
                    Divider()
                    Button("Unbind ⌘\(current)") { model.bindings.clear(current) }
                }
            }
        }
    }

    /// Nothing is disabled: rebinding a taken digit is a legitimate thing to want, and the
    /// menu says what it would displace rather than refusing.
    private func label(for digit: Int, current: Int?) -> String {
        if digit == current { return "⌘\(digit) ✓" }
        guard let taken = model.bindings.binding(for: digit) else { return "⌘\(digit)" }
        return "⌘\(digit) — \(taken.buffer.isEmpty ? taken.network : taken.buffer)"
    }
}

/// The digit a bound row shows, in the trailing edge of the tree (§11).
///
/// Unbound-by-default has a real discoverability cost, and showing the digit is what pays
/// it down. It is the *only* thing binding changes about a row: no reordering, no move to
/// the top of the group — "pinned" here means remembered.
private struct BindingDigit: View {
    let digit: Int?

    var body: some View {
        if let digit {
            Text("\u{2318}\(digit)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Bound to Command \(digit)")
        }
    }
}

/// The network row: connection state, and the door to the status buffer.
///
/// **When collapsed it wears its children's activity** (§9) — the highest state among
/// them. A collapse that hides activity from you defeats the point of collapsing. When
/// expanded it shows only its own status buffer's, because the children are speaking for
/// themselves right below it.
private struct NetworkRow: View {
    let connection: ConnectionViewModel
    let digit: Int?

    private var activity: BufferActivity {
        connection.isExpanded ? connection.status.activity : connection.rolledUpActivity
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColour)
                .frame(width: 7, height: 7)
                .accessibilityLabel(connection.statusSummary)
            Text(connection.displayName)
                .lineLimit(1)
                .foregroundStyle(Color(activity.colour))
                .fontWeight(activity.isBold ? .bold : .regular)
            Spacer(minLength: 4)
            HighlightBadge(activity: activity)
            BindingDigit(digit: digit)
        }
        .help(connection.statusSummary)
    }

    /// Three states, not two: connecting is worth distinguishing from connected, because
    /// it is the one where waiting is the right thing to do.
    private var indicatorColour: Color {
        switch connection.state {
        case .connected: .green
        case .connecting, .registering, .reconnecting: .orange
        case .disconnected: .secondary
        }
    }
}

/// A conversation row: a bullet, then the nick.
///
/// **A bullet rather than `@`** (§12). In IRC `@` already means channel operator, and this
/// client renders prefix characters throughout — in nick lists and in `<@nick>` message
/// lines. Teaching two meanings for one glyph in the same window is not worth the
/// familiarity. No space after it: the sigil is one cell wide, like `#`, so the two form
/// a column and names never shift.
private struct QueryRow: View {
    let buffer: QueryBuffer
    let digit: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text("\(SidebarTree.querySigil)\(buffer.nick.raw)")
                .lineLimit(1)
                .foregroundStyle(Color(buffer.activity.colour))
                .fontWeight(buffer.activity.isBold ? .bold : .regular)
            Spacer(minLength: 4)
            HighlightBadge(activity: buffer.activity)
            BindingDigit(digit: digit)
        }
        .help("Conversation with \(buffer.nick.raw)")
    }
}

/// A dot for the highlight state, and only for it (§3).
///
/// mIRC's colour-coded states already carry the information; the badge is *additive* for
/// the one state worth interrupting for. A badge on every state is a wall of dots, and a
/// wall of dots is read as decoration.
private struct HighlightBadge: View {
    let activity: BufferActivity

    var body: some View {
        if activity.showsBadge {
            Circle()
                .fill(Color(activity.colour))
                .frame(width: 6, height: 6)
                .accessibilityLabel("Someone said something to you here")
        }
    }
}

/// A channel row. Keeps its `#`, and greys out when we are not in the channel.
private struct ChannelRow: View {
    let buffer: ChannelBuffer
    let digit: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(buffer.name.raw)
                .lineLimit(1)
                .foregroundStyle(nameColour)
                .fontWeight(buffer.activity.isBold ? .bold : .regular)
            Spacer(minLength: 4)
            HighlightBadge(activity: buffer.activity)
            BindingDigit(digit: digit)
        }
        .help(buffer.isJoined ? buffer.topicText ?? buffer.name.raw : "Not in this channel")
    }

    /// **Not-joined outranks activity.** One "you are not in here right now" appearance,
    /// whether we parted, were kicked or the network dropped — and a buffer you are not in
    /// still collects lines from a bouncer's backlog, so the two states really can meet.
    /// Being absent is the more important of the two things to say.
    private var nameColour: AnyShapeStyle {
        guard buffer.isJoined else { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(Color(buffer.activity.colour))
    }
}
