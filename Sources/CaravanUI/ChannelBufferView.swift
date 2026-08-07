import IRCSession
import SwiftUI

/// A channel window: topic band, scrollback, input field, and the nick list beside them.
struct ChannelBufferView: View {
    let model: AppModel

    /// **The network this window belongs to, not the one the tree has selected.** A
    /// detached channel window is quite often looking at a different network from the main
    /// window, and everything this view sends has to go to the one it is showing.
    let connection: ConnectionViewModel

    let buffer: ChannelBuffer

    /// Which window this view is in, so a sheet opened from it lands on the right one.
    let window: KeyWindow

    /// App-wide, not per buffer. One setting to find and one to change, per the
    /// global-first rule the design notes take for everything of this kind — and in the
    /// plain-text config with every other setting, rather than in a second store.
    @Bindable private var settings: ChatSettings

    @State private var isTopicExpanded = false

    @Environment(\.chatFont) private var chatFont

    init(
        model: AppModel,
        connection: ConnectionViewModel,
        buffer: ChannelBuffer,
        window: KeyWindow = .main
    ) {
        self.model = model
        self.connection = connection
        self.buffer = buffer
        self.window = window
        self._settings = Bindable(wrappedValue: model.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollbackView(log: buffer.log, actions: actions)
                    Divider()
                    inputField
                }
                if settings.isNickListVisible {
                    ResizeHandle(
                        width: $settings.nickListWidth,
                        range: ChatSettings.nickListWidthRange
                    )
                    NickListPane(buffer: buffer, actions: actions)
                        .frame(width: settings.nickListWidth)
                }
            }
        }
    }

    /// Everything this window can do to a nick, a link or itself — one value handed to both
    /// the nick list and the scrollback, which is what keeps the two menus the same menu.
    private var actions: BufferActions {
        BufferActions(
            model: model,
            connection: connection,
            channel: buffer,
            target: .channel(buffer.name),
            window: window
        )
    }

    private var header: some View {
        HeaderBand(
            content: buffer.topicText,
            placeholder: buffer.isJoined
                ? "No topic is set for \(buffer.name.raw)"
                : "You are not in \(buffer.name.raw)",
            isExpanded: $isTopicExpanded
        ) {
            // The nick-list toggle used to live here. §8 puts it in the toolbar, where it
            // is one of the three items the minimal default set names — and the View menu
            // carries it too, so a detached channel window can still reach it.
            EmptyView()
        }
        .font(chatFont)
    }

    private var inputField: some View {
        InputBar(
            state: buffer.input,
            target: .channel(buffer.name),
            placeholder: "Message \(buffer.name.raw), or /command",
            sources: { model.completionSources(in: buffer, on: connection) },
            palette: settings.palette,
            completionStyle: settings.completionSuffix,
            submit: { text in
                await model.submit(text, from: .channel(buffer.name), on: connection)
            }
        )
    }
}

/// The nick list: ordered by `PREFIX` rank then casemapped alphabetical, with a count.
///
/// The order is the session's, arriving whole on each snapshot. Sorting here as well
/// would be a second implementation of the same rule and a chance for the two to differ.
struct NickListPane: View {
    let buffer: ChannelBuffer
    let actions: BufferActions

    @Environment(\.chatFont) private var chatFont

    var body: some View {
        VStack(spacing: 0) {
            Text(memberCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            Divider()
            List(buffer.members, id: \.nick) { member in
                Text(buffer.channel.displayName(for: member))
                    .lineLimit(1)
                    // The whole row, not just its glyphs: a right-click in the empty space
                    // beside a short nick is still a right-click on that person.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    // **Double-click opens a conversation.** The one thing done to a name
                    // often enough that going through a menu for it is friction.
                    .onTapGesture(count: 2) {
                        actions.perform(.command("/query \(member.nick.raw)"))
                    }
                    .contextMenu {
                        BufferMenuItems(target: .nick(member.nick.raw), actions: actions)
                    }
            }
            .listStyle(.plain)
            .font(chatFont)
        }
    }

    private var memberCountLabel: String {
        guard buffer.isJoined else { return "not joined" }
        let count = buffer.memberCount
        return count == 1 ? "1 member" : "\(count) members"
    }
}
