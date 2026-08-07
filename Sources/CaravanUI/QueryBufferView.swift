import IRCSession
import SwiftUI

/// A conversation window: header band, scrollback, input field.
///
/// A channel window minus the nick list, which is not a simplification but the point —
/// there are two people here and one of them is you, so a pane listing them would be a
/// pane restating the title.
struct QueryBufferView: View {
    let model: AppModel

    /// This window's network. See ``ChannelBufferView/connection``.
    let connection: ConnectionViewModel

    let buffer: QueryBuffer

    /// Which window this view is in, so a sheet opened from it lands on the right one.
    var window: KeyWindow = .main

    @State private var isContextExpanded = false

    @Environment(\.chatFont) private var chatFont

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollbackView(log: buffer.log, actions: actions)
            Divider()
            inputField
        }
    }

    /// No channel, so no membership items: `/op` in a conversation has nothing to name.
    private var actions: BufferActions {
        BufferActions(
            model: model,
            connection: connection,
            channel: nil,
            target: .nick(buffer.nick),
            window: window
        )
    }

    /// The band shows *conversational context* rather than a topic (§14): how much has
    /// been said, and the two ends of it. Three lines at most, which the band shrinks to
    /// two — the same shrink the MOTD needs, reused rather than rebuilt.
    private var header: some View {
        HeaderBand(
            content: buffer.contextSummary,
            placeholder: buffer.contextPlaceholder,
            isExpanded: $isContextExpanded
        ) {
            EmptyView()
        }
        .font(chatFont)
    }

    private var inputField: some View {
        InputBar(
            state: buffer.input,
            target: .nick(buffer.nick),
            placeholder: "Message \(buffer.nick.raw), or /command",
            // The two people in the room. Tab-completing the person you are talking to is
            // the one completion a conversation window has any use for.
            sources: {
                model.completionSources(
                    nicks: [buffer.nick.raw, connection.currentNick],
                    on: connection
                )
            },
            palette: model.settings.palette,
            completionStyle: model.settings.completionSuffix,
            submit: { text in
                await model.submit(text, from: .nick(buffer.nick), on: connection)
            }
        )
    }
}
