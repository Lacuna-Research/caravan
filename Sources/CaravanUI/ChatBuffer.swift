import IRCProtocol
import Observation

/// What every navigable buffer has, whatever shape it is.
///
/// **Earned rather than anticipated.** Stage 1 had one buffer type, prompt 5 added a
/// second, and this prompt needs a third — the per-network status window, which until now
/// was a `MessageLogController` and an `InputState` hanging off `ConnectionViewModel`
/// rather than an object. Three is the point at which the common shape stops being a
/// coincidence.
///
/// Four features want it at once: the flat list of buffers across every network, the
/// activity state each of them carries, the MRU order Ctrl+Tab walks, and the ⌘1–9
/// bindings that attach to a buffer's identity.
///
/// A canvas is deliberately *not* one of these. `Settings & Debug` is selectable in the
/// tree, and has no scrollback, no input and no activity — §10 draws the line between
/// buffers and canvases, and this protocol is which side of it a thing is on.
@MainActor
public protocol ChatBuffer: AnyObject {
    /// This buffer's scrollback.
    var log: MessageLogController { get }

    /// Its input box and command history, which belong to the buffer rather than to the
    /// view — switching away and back must not lose the line being written.
    var input: InputState { get }

    /// How badly it wants your attention. Reset when you look at it.
    var activity: BufferActivity { get set }

    /// What the tree and the quick-switcher call it.
    var displayName: String { get }

    /// Whether this is a private conversation, which decides whether an arriving message
    /// is a highlight or merely a message.
    var isConversation: Bool { get }
}

/// The per-network status window, as a buffer like any other.
///
/// It has always behaved as one — its own scrollback, its own input box and history — and
/// was only ever *shaped* differently because it predated there being more than one kind
/// of buffer. Making it an object costs one indirection and buys the flat list a uniform
/// element instead of a special case in four places.
///
/// `ConnectionViewModel.log` and `.statusInput` still exist and forward here, so nothing
/// that had a perfectly good reference to a network's scrollback had to change.
@MainActor
@Observable
public final class StatusBuffer: ChatBuffer {
    public let log = MessageLogController()
    public let input = InputState()
    public var activity: BufferActivity = .none

    /// The network's name, which is what the tree row shows. Held rather than derived
    /// because `ConnectionViewModel` owns the name and can rename itself when a bouncer
    /// renames a network under us.
    public internal(set) var displayName: String

    /// Never. A status window is where the *network* talks, and a server notice arriving
    /// there is not somebody addressing you.
    public nonisolated var isConversation: Bool { false }

    init(displayName: String) {
        self.displayName = displayName
    }
}

extension ChannelBuffer: ChatBuffer {
    public var displayName: String { name.raw }
    public nonisolated var isConversation: Bool { false }
}

extension QueryBuffer: ChatBuffer {
    public var displayName: String { nick.raw }

    /// The whole reason a private message has a window of its own.
    public nonisolated var isConversation: Bool { true }
}
