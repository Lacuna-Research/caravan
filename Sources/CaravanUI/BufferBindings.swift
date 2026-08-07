import Foundation
import IRCProtocol
import IRCSession
import Observation

/// Which buffer each of ⌘1–9 reaches (GUI-DESIGN-NOTES.md §11).
///
/// Five rules from the design notes, all of them load-bearing:
///
/// - **Nothing is bound by default.** Bindings are made deliberately, from the tree row's
///   context menu.
/// - **A binding attaches to a buffer *identity*, not to a live window.** Otherwise
///   parting a channel or bouncing a connection silently drops it, and persistent memory
///   is the entire point.
/// - **Nine global slots, not nine per network.** ⌘3 means the same buffer everywhere,
///   always — the digit never lies, which is the whole value of binding by hand.
/// - **Bindings survive restarts**, in the plain-text config.
/// - **Assigning does not reorder anything.** "Pinned" here means remembered, not
///   Chrome-style pinned; the tree order is untouched and the row only gains its digit.
@MainActor
@Observable
public final class BufferBindings {
    /// Digit (1–9) to the buffer it names. Sparse: an unbound digit is simply absent.
    public private(set) var slots: [Int: BufferBinding] = [:]

    @ObservationIgnored private let config: ConfigFile

    /// `binding.1 = irc.libera.chat:6697/#swift`. One key per digit, so a hand-edited file
    /// can drop a single line to clear one.
    static func key(for digit: Int) -> String { "binding.\(digit)" }

    public static let digits = 1...9

    public init(config: ConfigFile) {
        self.config = config
        for digit in Self.digits {
            guard let raw = config.string(Self.key(for: digit)),
                let binding = BufferBinding(rawValue: raw)
            else { continue }
            slots[digit] = binding
        }
    }

    public func binding(for digit: Int) -> BufferBinding? { slots[digit] }

    /// The digit a buffer holds, for the tree to show. `nil` for the vast majority.
    public func digit(for binding: BufferBinding?) -> Int? {
        guard let binding else { return nil }
        return slots.first { $0.value == binding }?.key
    }

    /// Binds a digit, taking it off whatever held it before.
    ///
    /// **A buffer holds at most one digit and a digit at most one buffer.** Binding
    /// `#swift` to ⌘3 when it already holds ⌘5 moves it rather than giving it two, because
    /// a buffer reachable by two digits makes the tree's own display of the digit a lie.
    public func bind(_ binding: BufferBinding, to digit: Int) {
        guard Self.digits.contains(digit) else { return }
        if let existing = self.digit(for: binding), existing != digit { clear(existing) }
        slots[digit] = binding
        config.set(binding.rawValue, forKey: Self.key(for: digit))
    }

    public func clear(_ digit: Int) {
        guard slots.removeValue(forKey: digit) != nil else { return }
        config.set(nil, forKey: Self.key(for: digit))
    }
}

/// A buffer named durably enough to survive a restart: which network, and which buffer on
/// it.
///
/// **The network is `host:port`, plus the bouncer network id where there is one** — not
/// the display name. `ConnectionViewModel.displayName` comes from `ISUPPORT NETWORK=`,
/// which the server owns and can change under you, and `id` is a fresh `UUID` every
/// launch. `host:port` is what the user typed and what `AppModel.connect(using:)` already
/// treats as network identity when it decides two connections are the same network.
///
/// `PLAN.md`'s "Still open" carries the question of a *user-facing* stable network name;
/// stage 2's server-list prompt answers it, and these keys migrate to it then. Written
/// down rather than left implicit because `caravan.conf`'s keys are public API.
public struct BufferBinding: Hashable, Sendable {
    /// `irc.libera.chat:6697`, or `soju.example.org:6697[libera]` for a bouncer network.
    public let network: String
    /// `#swift`, `bob`, or empty for the network's status window.
    public let buffer: String

    public init(network: String, buffer: String) {
        self.network = network
        self.buffer = buffer
    }

    /// `irc.libera.chat:6697/#swift`, and `irc.libera.chat:6697` for a status window.
    ///
    /// The buffer name keeps its `#`, which is what tells a channel from a conversation
    /// without a third field: `#bob` and `bob` are different buffers, and a bare name
    /// could not say which was meant.
    public var rawValue: String {
        buffer.isEmpty ? network : "\(network)/\(buffer)"
    }

    public init?(rawValue: String) {
        // Split on the *first* slash after the network part. A channel name cannot contain
        // one and a host cannot either, so first-slash is unambiguous.
        guard let slash = rawValue.firstIndex(of: "/") else {
            guard !rawValue.isEmpty else { return nil }
            self.init(network: rawValue, buffer: "")
            return
        }
        let network = String(rawValue[rawValue.startIndex..<slash])
        guard !network.isEmpty else { return nil }
        self.init(network: network, buffer: String(rawValue[rawValue.index(after: slash)...]))
    }
}

extension ConnectionViewModel {
    /// How the config names this network.
    ///
    /// Two features key on it now — ⌘1–9 bindings and the manual tree order — which is why
    /// it is no longer called `bindingNetworkKey`. Both inherit the same caveat: it is
    /// `host:port` for want of a stable user-facing network name, and the server-list
    /// prompt migrates both together.
    public var networkKey: String {
        let base = "\(host):\(port)"
        guard let bouncerNetworkID else { return base }
        return "\(base)[\(bouncerNetworkID)]"
    }
}

extension AppModel {
    /// The binding a row would make, or `nil` for the canvas — which is not a buffer and
    /// whose ⌘0 is reserved and not user-assignable (§11).
    public func binding(for item: SidebarItem) -> BufferBinding? {
        switch item {
        case .status(let id):
            guard let connection = connection(id: id) else { return nil }
            return BufferBinding(network: connection.networkKey, buffer: "")
        case .channel(let id, let name):
            guard let connection = connection(id: id) else { return nil }
            return BufferBinding(network: connection.networkKey, buffer: name.raw)
        case .query(let id, let nick):
            guard let connection = connection(id: id) else { return nil }
            return BufferBinding(network: connection.networkKey, buffer: nick.raw)
        case .settingsAndDebug:
            return nil
        }
    }

    /// ⌘1–9. Goes to the bound buffer, **opening it if it is not open** (§11).
    ///
    /// ⌘3 means "take me to `#swift`", not "take me to `#swift` if I happen to already be
    /// there". The guard rail is that auto-joining only happens on a network that is
    /// already connected: a binding must not silently dial out, so a disconnected network
    /// gets its buffer revealed in the greyed not-joined state instead.
    public func activateBinding(digit: Int) async {
        guard let binding = bindings.binding(for: digit) else { return }
        guard
            let connection = connections.first(where: { $0.networkKey == binding.network })
        else {
            // The network is not open at all, so there is no buffer to reveal and nothing
            // to join. Said out loud rather than swallowed — a shortcut that does nothing
            // is indistinguishable from a shortcut that is broken.
            activeConnection?
                .showNotice(
                    "⌘\(digit) is bound to \(binding.rawValue), which is not open",
                    in: selectedTarget
                )
            return
        }
        reveal(await item(for: binding, on: connection))
    }

    /// Resolves a binding to a row, making the buffer if it is not there.
    private func item(for binding: BufferBinding, on connection: ConnectionViewModel) async
        -> SidebarItem
    {
        guard !binding.buffer.isEmpty else { return .status(connection.id) }

        let capabilities = await connection.serverCapabilities
        let target = Target(binding.buffer, capabilities: capabilities)
        switch target {
        case .channel(let name):
            if connection.buffer(named: name) == nil {
                connection.openChannelBuffer(named: name)
                // Only on a live connection. On a dead one the buffer is revealed greyed,
                // which is the same "you are not in here right now" state a parted channel
                // wears — and is emphatically not a silent reconnect.
                if connection.isConnected {
                    await connection.send(
                        IRCMessage(verb: "JOIN", parameters: [name.raw]),
                        from: nil
                    )
                }
            }
            return .channel(connection: connection.id, channel: name)
        case .nick:
            let query = await connection.openQuery(with: binding.buffer)
            return .query(connection: connection.id, nick: query.nick)
        }
    }
}
