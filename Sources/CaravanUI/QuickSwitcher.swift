import SwiftUI

/// ⌘K: type a few characters, Enter (GUI-DESIGN-NOTES.md §9).
///
/// The answer to "getting to a window you're thinking of", which §9 deliberately keeps
/// separate from "getting to wherever something is happening" (next-unread) and "getting
/// back to where you just were" (Ctrl+Tab). Conflating the three produces something that
/// solves none of them.
///
/// The idiom did not exist in 1995, which is the only reason mIRC lacked it.
struct QuickSwitcher: View {
    @Bindable var model: AppModel

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    @Environment(\.chatFont) private var chatFont

    /// Enough to fill the palette without turning it into the tree.
    private let visibleLimit = 12

    private var matches: [BufferRef] {
        Array(FuzzyMatch.rank(model.allBuffers, query: query).prefix(visibleLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
        }
        .frame(width: 460)
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var field: some View {
        TextField("Go to buffer", text: $query)
            .textFieldStyle(.plain)
            .font(.title3)
            .padding(12)
            .focused($isFieldFocused)
            .onAppear { isFieldFocused = true }
            .onSubmit(activate)
            .onKeyPress(.downArrow) { move(by: 1) }
            .onKeyPress(.upArrow) { move(by: -1) }
            // ⌃N/⌃P alongside the arrows: this is a palette, and the people who reach for
            // one reach for those.
            .onKeyPress(keys: ["n"], phases: .down) { press in
                press.modifiers.contains(.control) ? move(by: 1) : .ignored
            }
            .onKeyPress(keys: ["p"], phases: .down) { press in
                press.modifiers.contains(.control) ? move(by: -1) : .ignored
            }
            .onKeyPress(.escape) {
                model.isShowingQuickSwitcher = false
                return .handled
            }
    }

    @ViewBuilder
    private var results: some View {
        if matches.isEmpty {
            Text(query.isEmpty ? "No buffers open" : "No buffer matches “\(query)”")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, buffer in
                            row(buffer, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture {
                                    highlighted = index
                                    activate()
                                }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) { _, new in
                    withAnimation(.linear(duration: 0.05)) { proxy.scrollTo(new) }
                }
            }
        }
    }

    private func row(_ buffer: BufferRef, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            // The same activity colour the tree uses, so the palette is not a second
            // opinion about which buffers want attention.
            Circle()
                .fill(Color(buffer.activity.colour))
                .frame(width: 7, height: 7)
                .opacity(buffer.activity == .none ? 0 : 1)
            Text(buffer.name)
                .fontWeight(isHighlighted ? .semibold : .regular)
            Spacer(minLength: 8)
            // Always says which network: `#music` on two networks are different rooms.
            Text(buffer.networkName)
                .foregroundStyle(.secondary)
        }
        .font(chatFont)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(.rect)
    }

    private func move(by delta: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        highlighted = (highlighted + delta + matches.count) % matches.count
        return .handled
    }

    private func activate() {
        guard matches.indices.contains(highlighted) else { return }
        model.isShowingQuickSwitcher = false
        model.reveal(matches[highlighted].item)
    }
}
