import IRCProtocol
import IRCSession
import Observation

/// One channel window: its scrollback, and the last state snapshot the session sent.
///
/// Holds no transition logic. Every membership change arrives as a whole ``Channel`` on
/// ``IRCEvent/channelChanged(_:)``, so the nick list here is a copy of the session's
/// answer rather than a second implementation of it — which is the only way the two can
/// be guaranteed to agree.
@MainActor
@Observable
public final class ChannelBuffer: Identifiable {
    public let name: IRCChannelName

    /// A controller per buffer, as prompt 7 already arranged: a channel window is a
    /// second scrollback, not a rework of the first.
    public let log = MessageLogController()

    /// This window's input box and command history. Both belong to the buffer rather
    /// than to the view, or switching away and back would lose the line being written and
    /// leave the history attached to the wrong window.
    public let input = InputState()

    public private(set) var channel: Channel

    /// `nonisolated` because `Identifiable` is not: the identity is the immutable name,
    /// so reading it off the main actor is safe and SwiftUI's diffing needs it to be.
    public nonisolated var id: IRCChannelName { name }

    init(name: IRCChannelName) {
        self.name = name
        self.channel = Channel(name: name)
    }

    func update(_ channel: Channel) {
        self.channel = channel
    }

    /// Whether we are in the channel. Drives the greyed "not in here right now" state,
    /// which a parted, kicked or disconnected buffer all share.
    public var isJoined: Bool { channel.isJoined }

    public var members: [Member] { channel.orderedMembers }

    public var memberCount: Int { channel.memberCount }

    /// The topic, or `nil` when the channel has none to show.
    public var topicText: String? {
        guard let topic = channel.topic, !topic.isEmpty else { return nil }
        return topic.text
    }
}
