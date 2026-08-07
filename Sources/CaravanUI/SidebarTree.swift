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
                ChannelRow(buffer: buffer)
                    .tag(
                        AppModel.SidebarItem.channel(
                            connection: connection.id,
                            channel: buffer.name
                        )
                    )
            }
        } label: {
            NetworkRow(connection: connection)
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
                }
        }
    }
}

/// The network row: connection state, and the door to the status buffer.
private struct NetworkRow: View {
    let connection: ConnectionViewModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(indicatorColour)
                .frame(width: 7, height: 7)
                .accessibilityLabel(connection.statusSummary)
            Text(connection.displayName)
                .lineLimit(1)
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

/// A channel row. Keeps its `#`, and greys out when we are not in the channel.
private struct ChannelRow: View {
    let buffer: ChannelBuffer

    var body: some View {
        Text(buffer.name.raw)
            .lineLimit(1)
            // One "you are not in here right now" appearance, whether we parted, were
            // kicked, or the network dropped — not three.
            .foregroundStyle(buffer.isJoined ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .help(buffer.isJoined ? buffer.topicText ?? buffer.name.raw : "Not in this channel")
    }
}
