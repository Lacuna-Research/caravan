import Foundation

/// Moves `caravan.conf`'s durable keys from `host:port` to a ``NetworkName``.
///
/// Two families key on a network, both written before there was a stable name for one:
///
/// - `binding.3 = irc.libera.chat:6697/#swift` — which buffer ⌘3 reaches (§11).
/// - `order.irc.libera.chat:6697.channels = #swift,#vapor` — the manual tree order (§12).
///
/// Both used `host:port`, plus `[bouncer-network-id]` where there was one, because that was
/// the only durable identifier available. **These keys are public API**, so this is a
/// migration rather than a format change: nothing is dropped because it is in the old form,
/// and a binding whose server is not in the list *creates* that server rather than being
/// discarded. Somebody who bound ⌘3 last week should find ⌘3 working this week and the
/// network it names sitting in their server list.
///
/// Idempotent, and cheap: a file already migrated has no key in the old form to match, so
/// the second launch does nothing.
public enum NetworkKeyMigration {
    /// A network as the old scheme named it.
    struct OldKey: Hashable {
        let host: String
        let port: UInt16
        let bouncerNetwork: String

        /// Parses `irc.libera.chat:6697` and `soju.example.org:6697[libera]`.
        ///
        /// Returns `nil` for anything that is *not* the old form — which is how a name
        /// already migrated is left alone, since a `ServerEntry` name can hold neither a
        /// colon nor a bracket.
        init?(_ raw: String) {
            var rest = Substring(raw)
            var bouncer = ""
            if rest.hasSuffix("]"), let open = rest.lastIndex(of: "[") {
                bouncer = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
                rest = rest[rest.startIndex..<open]
            }
            // Split on the *last* colon: a bare IPv6 literal has several, and while
            // nothing wrote one, refusing to parse it would silently drop the binding.
            guard let colon = rest.lastIndex(of: ":"),
                let port = UInt16(rest[rest.index(after: colon)...]),
                colon > rest.startIndex
            else { return nil }
            self.host = String(rest[rest.startIndex..<colon])
            self.port = port
            self.bouncerNetwork = bouncer
        }
    }

    /// Rewrites both key families in `settings`, creating any entry `servers` is missing.
    ///
    /// - Returns: the names of entries created because a key referred to a server that was
    ///   not in the list. Reported rather than silent: an entry appearing in the Dashboard
    ///   that the user never added should be explicable.
    @discardableResult
    @MainActor
    public static func run(settings: ConfigFile, servers: ServerList) -> [String] {
        var created: [String] = []
        var mapping: [String: String] = [:]

        func name(for old: OldKey) -> String {
            if let existing = mapping[identifier(old)] { return existing }
            let match = servers.entries.first {
                $0.host.lowercased() == old.host.lowercased() && $0.port == old.port
                    && $0.bouncerNetwork == old.bouncerNetwork
            }
            let resolved: String
            if let match {
                resolved = match.name
            } else {
                // Nothing matches, so the binding predates the list. Make the server it
                // names rather than dropping it — the alternative is a shortcut that
                // stops working for a reason the user cannot see.
                let preferred =
                    old.bouncerNetwork.isEmpty
                    ? NetworkName.suggestion(forHost: old.host)
                    : NetworkName.sanitised(old.bouncerNetwork)
                resolved = NetworkName.unique(preferred, taken: servers.names)
                servers.save(
                    ServerEntry(
                        name: resolved,
                        host: old.host,
                        port: old.port,
                        bouncerNetwork: old.bouncerNetwork
                    )
                )
                created.append(resolved)
            }
            mapping[identifier(old)] = resolved
            return resolved
        }

        for digit in BufferBindings.digits {
            let key = BufferBindings.key(for: digit)
            guard let raw = settings.string(key),
                let binding = BufferBinding(rawValue: raw),
                let old = OldKey(binding.network)
            else { continue }
            let migrated = BufferBinding(network: name(for: old), buffer: binding.buffer)
            settings.set(migrated.rawValue, forKey: key)
        }

        for key in settings.keys(withPrefix: "order.") {
            guard let (network, section) = splitOrderKey(key), let old = OldKey(network),
                let value = settings.string(key)
            else { continue }
            settings.set(nil, forKey: key)
            settings.set(value, forKey: BufferOrder.key(network: name(for: old), section: section))
        }

        return created
    }

    /// Moves both families from one name to another. A user renaming their own entry.
    @MainActor
    static func rename(_ old: String, to new: String, in settings: ConfigFile) {
        for digit in BufferBindings.digits {
            let key = BufferBindings.key(for: digit)
            guard let raw = settings.string(key), let binding = BufferBinding(rawValue: raw),
                binding.network == old
            else { continue }
            settings.set(
                BufferBinding(network: new, buffer: binding.buffer).rawValue,
                forKey: key
            )
        }
        for key in settings.keys(withPrefix: "order.\(old).") {
            guard let (_, section) = splitOrderKey(key), let value = settings.string(key)
            else { continue }
            settings.set(nil, forKey: key)
            settings.set(value, forKey: BufferOrder.key(network: new, section: section))
        }
    }

    /// `order.<network>.<section>` → its two parts.
    ///
    /// Split on the **last** dot, not the first: the old form put `host:port` in the middle
    /// and hosts are full of dots. A migrated name has none, so this keeps working after
    /// the migration as well as before it.
    private static func splitOrderKey(_ key: String) -> (String, BufferOrder.Section)? {
        let body = key.dropFirst("order.".count)
        guard let dot = body.lastIndex(of: "."),
            let section = BufferOrder.Section(rawValue: String(body[body.index(after: dot)...]))
        else { return nil }
        let network = String(body[body.startIndex..<dot])
        return network.isEmpty ? nil : (network, section)
    }

    private static func identifier(_ old: OldKey) -> String {
        "\(old.host.lowercased()):\(old.port)[\(old.bouncerNetwork)]"
    }
}
