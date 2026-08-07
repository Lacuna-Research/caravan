import IRCProtocol

/// One upstream network a bouncer is holding for us.
///
/// From soju's `soju.im/bouncer-networks`: the bouncer stays connected to several networks
/// and this is how a client finds out which. The attributes are carried whole, like
/// `ServerCapabilities.rawTokens`, because the set is open — soju adds keys and a client
/// that discarded the ones it did not recognise could not show the user what the bouncer
/// actually said.
public struct BouncerNetwork: Sendable, Equatable, Identifiable {
    /// The bouncer's own identifier, which is what `BOUNCER BIND` takes.
    public let id: String

    /// Every attribute, by name. `name`, `host`, `state` and `error` have accessors; the
    /// rest are here for a UI that wants to show them.
    public private(set) var attributes: [String: String]

    public init(id: String, attributes: [String: String] = [:]) {
        self.id = id
        self.attributes = attributes
    }

    /// What to call it in the tree: the network's own name, falling back to its host, and
    /// to the bare id if the bouncer sent neither.
    public var displayName: String {
        if let name = attributes["name"], !name.isEmpty { return name }
        if let host = attributes["host"], !host.isEmpty { return host }
        return id
    }

    public var host: String? { attributes["host"] }

    /// `connected`, `connecting` or `disconnected`, as the bouncer sees the upstream. This
    /// is the bouncer's connection, not ours — we may be attached to a network the bouncer
    /// has itself lost.
    public var state: State {
        State(rawValue: attributes["state"] ?? "") ?? .unknown
    }

    /// Why the bouncer's own connection failed, when it says.
    public var error: String? {
        attributes["error"].flatMap { $0.isEmpty ? nil : $0 }
    }

    public enum State: String, Sendable, Equatable {
        case connected
        case connecting
        case disconnected
        /// The bouncer did not say, or said something this build does not know.
        case unknown
    }

    /// Applies an update, which carries only the attributes that changed.
    ///
    /// An attribute whose value is empty is *removed*, per the extension: that is how the
    /// bouncer clears an `error` once the upstream comes back.
    mutating func apply(attributes updates: [String: String]) {
        for (key, value) in updates {
            if value.isEmpty {
                attributes.removeValue(forKey: key)
            } else {
                attributes[key] = value
            }
        }
    }

    /// Parses the attribute list of a `BOUNCER NETWORK` message.
    ///
    /// `name=Libera;host=irc.libera.chat;state=connected`, with `\` escaping as `ISUPPORT`
    /// uses. A field with no `=` is a valueless attribute and is kept as an empty string,
    /// which is also how the extension spells "remove this attribute".
    static func parse(attributes list: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for field in list.split(separator: ";", omittingEmptySubsequences: true) {
            guard let separator = field.firstIndex(of: "=") else {
                attributes[String(field)] = ""
                continue
            }
            let name = String(field[field.startIndex..<separator])
            guard !name.isEmpty else { continue }
            attributes[name] = ServerCapabilities.unescape(
                String(field[field.index(after: separator)...])
            )
        }
        return attributes
    }
}

/// A `BOUNCER` message, parsed.
///
/// Only the replies a client receives. The commands it sends — `BIND`, `LISTNETWORKS` —
/// are built in ``IRCSession`` and need no type of their own.
enum BouncerReply: Sendable, Equatable {
    /// `BOUNCER NETWORK <netid> <attributes>`, or `<netid> *` for a network removed.
    case network(id: String, attributes: [String: String]?)

    init?(message: IRCMessage) {
        guard message.command.isVerb("BOUNCER"), message.parameters.count >= 3,
            message.parameters[0].uppercased() == "NETWORK"
        else { return nil }
        let id = message.parameters[1]
        guard !id.isEmpty else { return nil }
        // A bare `*` where the attributes go means the network is gone.
        if message.parameters[2] == "*" {
            self = .network(id: id, attributes: nil)
            return
        }
        self = .network(id: id, attributes: BouncerNetwork.parse(attributes: message.parameters[2]))
    }
}
