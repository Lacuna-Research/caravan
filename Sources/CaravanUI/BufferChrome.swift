import AppKit
import SwiftUI

/// The scrollback plus its "jump to latest" affordance.
///
/// Shared by every buffer type, so the scroll-lock behaviour cannot drift between the
/// status window and a channel window.
struct ScrollbackView: View {
    let log: MessageLogController

    /// What right-clicking in it can do, or `nil` where there is nothing buffer-shaped to
    /// do — the debug trace, which keeps AppKit's own Copy and Services menu.
    ///
    /// The controller owns the text view, so the menu goes to it rather than to the
    /// representable, which SwiftUI rebuilds freely.
    var actions: BufferActions?

    var body: some View {
        MessageLogView(controller: log)
            // Set on appearance rather than on every update: everything the closure
            // captures is a reference whose identity is fixed for the life of the buffer,
            // and `.id` below already gives each buffer its own appearance.
            .onAppear { log.contextMenu = actions.map { actions in { actions.menu(for: $0) } } }
            // Identity per controller, or SwiftUI reuses the representable across a
            // buffer switch — same view type, same position in the hierarchy — and calls
            // `updateNSView` instead of `makeNSView`. The second live run of the channel
            // window showed one channel's scrollback under another channel's topic and
            // nick list, which is exactly that.
            .id(ObjectIdentifier(log))
            .overlay(alignment: .bottomTrailing) {
                // Only offered when it is needed: while pinned to the bottom there is no
                // "latest" to jump to.
                if !log.isPinnedToBottom {
                    Button {
                        log.scrollToLatest()
                    } label: {
                        Label(
                            log.unseenLineCount > 0
                                ? "\(log.unseenLineCount) new" : "Jump to latest",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(12)
                }
            }
    }
}

/// The band across the top of a buffer.
///
/// **Never hidden, never closable.** A header that can be dismissed is one people dismiss
/// once and then forget exists — so an empty topic gets a placeholder rather than a
/// collapsed band. Long content shrinks to two lines with a disclosure chevron, and the
/// expanded state scrolls rather than growing without bound. That behaviour is
/// deliberately built here rather than in the channel view: prompt 10's status window
/// shows the MOTD in the same band, where multi-line is the rule rather than the edge.
struct HeaderBand<Trailing: View>: View {
    let content: String?
    let placeholder: String
    @Binding var isExpanded: Bool
    @ViewBuilder var trailing: () -> Trailing

    /// Two lines collapsed, and no more than this expanded before it scrolls. Roughly
    /// eight lines at the default size, which is enough for a topic and a long way short
    /// of eating the window.
    private let expandedHeight: CGFloat = 132

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            disclosure
            text
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder
    private var disclosure: some View {
        // Present only when there is something folded away; a chevron that does nothing
        // is worse than no chevron.
        if content != nil {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse header" : "Expand header")
        }
    }

    @ViewBuilder
    private var text: some View {
        if let content {
            if isExpanded {
                ScrollView(.vertical) {
                    Text(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: expandedHeight)
            } else {
                Text(content)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        } else {
            Text(placeholder)
                .foregroundStyle(.secondary)
        }
    }
}

/// A draggable pane divider whose position the caller persists.
///
/// `HSplitView` would draw this for free but keeps the position in its own state, and the
/// nick list's width is a setting the app remembers — one setting, app-wide, not one per
/// buffer.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>

    /// The width at the start of the current drag. `DragGesture` reports a cumulative
    /// translation, so without this the pane would accelerate away.
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { isInside in
                        if isInside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                // The pane is on the trailing edge, so dragging left
                                // makes it wider.
                                width = min(
                                    max(start - value.translation.width, range.lowerBound),
                                    range.upperBound
                                )
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
