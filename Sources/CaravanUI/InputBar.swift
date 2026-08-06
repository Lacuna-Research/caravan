import IRCSession
import SwiftUI

/// The input box as a buffer uses it: the field, its placeholder, and the wiring that
/// sends what is in it.
///
/// Shared by every buffer type so the rules that matter — Enter sends, Shift+Enter does
/// not, a paste never does — cannot come out different in one window than another.
struct InputBar: View {
    @Bindable var state: InputState

    /// The window's target, or `nil` for a status window. Decides where plain text goes,
    /// and which commands can resolve an argument they were not given.
    let target: Target?

    let placeholder: String

    /// What Tab completes against here. A closure, so it is answered when Tab is pressed
    /// rather than when the view was built.
    var sources: () -> CompletionSources = { CompletionSources() }

    /// The palette the box draws its own codes in — the buffer's, so what you are writing
    /// looks like what you are about to send.
    var palette: Palette = Palette()

    /// What a Tab-completed nick is followed by.
    var completionStyle: CompletionStyle = CompletionStyle()

    let submit: (String) async -> Void

    @Environment(\.chatFont) private var chatFont

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .font(chatFont)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            InputField(
                text: $state.text,
                onSubmit: send,
                sources: sources,
                palette: palette,
                completionStyle: completionStyle,
                onRecallPrevious: { state.recallPrevious() },
                onRecallNext: { state.recallNext() },
                onEdited: { state.noteEdited() }
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    /// Enter. The only path to the wire.
    private func send() {
        let text = state.text
        // Enter on an empty line does nothing — not an error line, not a blank message.
        guard !text.isEmpty else { return }
        state.record(text)
        Task { await submit(text) }
    }
}
