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
            if let connection = model.connection {
                DisclosureGroup(isExpanded: $model.isNetworkExpanded) {
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
                }
            }
        }
        .listStyle(.sidebar)
        .font(chatFont)
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
