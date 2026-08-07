import IRCSession
import SwiftUI

/// A channel window: topic band, scrollback, input field, and the nick list beside them.
struct ChannelBufferView: View {
    let model: AppModel
    let buffer: ChannelBuffer

    /// App-wide, not per buffer. One setting to find and one to change, per the
    /// global-first rule the design notes take for everything of this kind — and in the
    /// plain-text config with every other setting, rather than in a second store.
    @Bindable private var settings: ChatSettings

    @State private var isTopicExpanded = false

    @Environment(\.chatFont) private var chatFont

    init(model: AppModel, buffer: ChannelBuffer) {
        self.model = model
        self.buffer = buffer
        self._settings = Bindable(wrappedValue: model.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollbackView(log: buffer.log)
                    Divider()
                    inputField
                }
                if settings.isNickListVisible {
                    ResizeHandle(
                        width: $settings.nickListWidth,
                        range: ChatSettings.nickListWidthRange
                    )
                    NickListPane(buffer: buffer)
                        .frame(width: settings.nickListWidth)
                }
            }
        }
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
            sources: { model.completionSources(in: buffer) },
            palette: settings.palette,
            completionStyle: settings.completionSuffix,
            submit: { text in
                await model.submit(text, from: .channel(buffer.name))
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
