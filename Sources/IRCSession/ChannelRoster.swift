import IRCProtocol

/// Every channel this connection knows about, and the transitions that change them.
///
/// Pure and synchronous: given these events in this order, exactly this state. That is
/// what makes the awkward cases — a `QUIT` touching three channels, a nick collision
/// under `rfc1459` casemapping, `NAMES` arriving in batches — testable without a socket.
///
/// Lives inside ``IRCSession``; the world outside sees ``Channel`` snapshots.
struct ChannelRoster {
    /// Channels in join order. A channel is removed only when its buffer is closed.
    private(set) var order: [IRCChannelName] = []

    private(set) var channels: [IRCChannelName: Channel] = [:]

    /// Our own nick, folded under the current mapping. Decides self-join from other-join.
    private(set) var ownNick: IRCNick

    private var capabilities: ServerCapabilities

    /// `NAMES` batches waiting for their 366.
    ///
    /// Accumulated rather than applied per batch: 353 arrives several times for one
    /// channel, and replacing the membership on each would make the nick list flicker
    /// through partial states on every join.
    private var pendingNames: [IRCChannelName: [Member]] = [:]

    init(ownNick: String, capabilities: ServerCapabilities = ServerCapabilities()) {
        self.capabilities = capabilities
        self.ownNick = IRCNick(ownNick, mapping: capabilities.caseMapping)
    }

    /// Channels in join order, as snapshots.
    var snapshots: [Channel] { order.compactMap { channels[$0] } }

    subscript(name: IRCChannelName) -> Channel? { channels[name] }

    // MARK: - Capabilities

    /// Adopts new capabilities, re-keying everything if the casemapping moved.
    ///
    /// `IRCNick` and `IRCChannelName` fold on construction and compare only within the
    /// same mapping, which is what makes them safe dictionary keys — and what makes a
    /// mapping change a re-key rather than a no-op. A reconnect resets `ISUPPORT` to its
    /// defaults, so this runs on every connection whether or not the server moved.
    mutating func updateCapabilities(_ newCapabilities: ServerCapabilities) {
        let mappingChanged = newCapabilities.caseMapping != capabilities.caseMapping
        let prefixesChanged = newCapabilities.prefixes != capabilities.prefixes
        capabilities = newCapabilities
        guard mappingChanged || prefixesChanged else { return }

        let mapping = newCapabilities.caseMapping
        ownNick = IRCNick(ownNick.raw, mapping: mapping)
        pendingNames = [:]

        var remapped: [IRCChannelName: Channel] = [:]
        remapped.reserveCapacity(channels.count)
        var remappedOrder: [IRCChannelName] = []
        remappedOrder.reserveCapacity(order.count)
        for name in order {
            guard let channel = channels[name] else { continue }
            let updated = channel.remapped(mapping: mapping, prefixes: newCapabilities.prefixes)
            remapped[updated.name] = updated
            remappedOrder.append(updated.name)
        }
        channels = remapped
        order = remappedOrder
    }

    /// Renames ourselves. Called for our own `NICK` and on registration.
    mutating func setOwnNick(_ nick: String) {
        ownNick = IRCNick(nick, mapping: capabilities.caseMapping)
    }

    // MARK: - Buffer lifecycle

    /// Drops a channel entirely, which only closing its buffer does.
    @discardableResult
    mutating func remove(_ name: IRCChannelName) -> Bool {
        guard channels.removeValue(forKey: name) != nil else { return false }
        order.removeAll { $0 == name }
        pendingNames.removeValue(forKey: name)
        return true
    }

    // MARK: - Transitions

    /// Applies one event, returning the channels it changed.
    ///
    /// The return value is what the session broadcasts snapshots for, and it is a list
    /// rather than one name because a single `QUIT` or `NICK` reaches every channel shared
    /// with that user.
    mutating func apply(_ event: IRCEvent) -> [IRCChannelName] {
        switch event {
        case .joined(let channel, let who, let account, let realName):
            return applyJoin(channel: channel, who: who, account: account, realName: realName)

        case .parted(let channel, let who, _):
            return applyDeparture(channel: channel, nick: nickOf(who))

        case .kicked(let channel, _, let nick, _):
            return applyDeparture(channel: channel, nick: nick)

        case .quit(let who, _):
            return applyQuit(nick: nickOf(who))

        case .nickChanged(let who, let newNick):
            return applyNickChange(from: nickOf(who), to: newNick)

        case .namesReply(let channel, let names):
            return applyNames(channel: channel, names: names)

        case .endOfNames(let channel):
            return commitNames(channel: channel)

        case .topicChanged(let channel, let who, let topic):
            guard channels[channel] != nil else { return [] }
            channels[channel]?.setTopic(topic, setBy: who.flatMap { $0.nick })
            return [channel]

        case .topicAuthor(let channel, let nick, let setAt):
            guard channels[channel] != nil else { return [] }
            channels[channel]?.setTopicAuthor(nick, setAt: setAt)
            return [channel]

        case .channelModes(let channel, let changes):
            guard channels[channel] != nil else { return [] }
            channels[channel]?.setModes(changes)
            return [channel]

        case .modeChanged(let target, _, let changes):
            guard case .channel(let name) = target, channels[name] != nil else { return [] }
            for change in changes {
                channels[name]?.apply(change)
            }
            return [name]

        case .stateChanged(let state):
            return applyStateChange(state)

        case .awayChanged(let who, let message):
            return edit(nick: nickOf(who)) { $0.isAway = message != nil }

        case .accountChanged(let who, let account):
            return edit(nick: nickOf(who)) { $0.account = account }

        case .hostChanged(let who, let user, let host):
            return edit(nick: nickOf(who)) {
                $0.user = user
                $0.host = host
            }

        case .realNameChanged(let who, let realName):
            return edit(nick: nickOf(who)) { $0.realName = realName }

        case .raw, .registered, .message, .numeric, .clientError, .clientNotice,
            .joinFailed, .channelChanged, .channelClosed,
            .capabilitiesChanged, .authenticated, .standardReply, .invited,
            .batchStarted, .batchEnded, .bouncerNetworks, .ctcpRequest, .ctcpReply:
            // `.joinFailed` changes nothing: a join that failed left no state behind, and
            // the channel it names may be one we have never seen. `.invited` likewise —
            // an invitation is not a membership. A CTCP is addressed to the client rather
            // than to a channel, even when it arrives via one.
            return []
        }
    }

    /// Applies an edit to one person wherever they are, returning the channels it touched.
    ///
    /// The shape every `person changed` capability needs: `chghost`, `setname`,
    /// `away-notify` and `account-notify` all describe someone rather than a channel, and
    /// the client sees them in every channel it shares with them.
    private mutating func edit(nick: String, _ change: (inout Member) -> Void)
        -> [IRCChannelName]
    {
        let key = IRCNick(nick, mapping: capabilities.caseMapping)
        var changed: [IRCChannelName] = []
        for name in order where channels[name]?.contains(key) == true {
            channels[name]?.updateMember(key, change)
            changed.append(name)
        }
        return changed
    }

    private func nickOf(_ source: IRCSource) -> String {
        source.nick ?? source.wireForm
    }

    private mutating func applyJoin(
        channel name: IRCChannelName,
        who: IRCSource,
        account: String?,
        realName: String?
    ) -> [IRCChannelName] {
        let nick = IRCNick(nickOf(who), mapping: capabilities.caseMapping)
        let isSelf = nick == ownNick

        if channels[name] == nil {
            guard isSelf else {
                // Someone joining a channel we are not in is not ours to track. It reaches
                // the status window as `.raw` either way.
                return []
            }
            channels[name] = Channel(
                name: name,
                prefixes: capabilities.prefixes,
                mapping: capabilities.caseMapping
            )
            order.append(name)
        }

        if isSelf {
            // Rejoining a buffer that outlived its membership: the old member list is a
            // memory of who was there before, not who is there now. `NAMES` follows.
            channels[name]?.clearMembers()
            channels[name]?.isJoined = true
        }
        channels[name]?.addMember(
            Member(
                nick: nick,
                user: who.user,
                host: who.host,
                account: account,
                realName: realName
            )
        )
        return [name]
    }

    /// A `PART` or a `KICK`. Ours empties the channel and leaves the buffer behind.
    private mutating func applyDeparture(channel name: IRCChannelName, nick: String)
        -> [IRCChannelName]
    {
        guard channels[name] != nil else { return [] }
        let key = IRCNick(nick, mapping: capabilities.caseMapping)
        if key == ownNick {
            channels[name]?.isJoined = false
            channels[name]?.clearMembers()
            pendingNames.removeValue(forKey: name)
            return [name]
        }
        return channels[name]?.removeMember(key) != nil ? [name] : []
    }

    private mutating func applyQuit(nick: String) -> [IRCChannelName] {
        let key = IRCNick(nick, mapping: capabilities.caseMapping)
        var changed: [IRCChannelName] = []
        for name in order where channels[name]?.contains(key) == true {
            channels[name]?.removeMember(key)
            changed.append(name)
        }
        return changed
    }

    private mutating func applyNickChange(from oldNick: String, to newNick: String)
        -> [IRCChannelName]
    {
        let mapping = capabilities.caseMapping
        let oldKey = IRCNick(oldNick, mapping: mapping)
        let newKey = IRCNick(newNick, mapping: mapping)
        if oldKey == ownNick { ownNick = newKey }

        var changed: [IRCChannelName] = []
        for name in order where channels[name]?.contains(oldKey) == true {
            channels[name]?.renameMember(from: oldKey, to: newKey)
            changed.append(name)
        }
        return changed
    }

    /// One 353 batch.
    ///
    /// Every leading prefix character is consumed, not just the first, which is what
    /// `multi-prefix` needs: a parser that stops after one turns `@+bob` into a member
    /// called `+bob` the moment the capability is negotiated.
    ///
    /// What follows is a bare nick, or — under `userhost-in-names` — a whole
    /// `nick!user@host`. Split unconditionally rather than on the capability: a `!` cannot
    /// appear in a nick, so the shape says which form it is and the roster needs no second
    /// copy of what was negotiated.
    private mutating func applyNames(channel name: IRCChannelName, names: [String])
        -> [IRCChannelName]
    {
        guard channels[name] != nil else { return [] }
        let mapping = capabilities.caseMapping
        var batch = pendingNames[name] ?? []
        for entry in names where !entry.isEmpty {
            var rest = Substring(entry)
            var modes: Set<Character> = []
            while let first = rest.first, let mode = capabilities.mode(forPrefix: first) {
                modes.insert(mode)
                rest = rest.dropFirst()
            }
            guard !rest.isEmpty else { continue }
            let source = IRCSource(prefix: String(rest))
            batch.append(
                Member(
                    nick: IRCNick(source.nick ?? String(rest), mapping: mapping),
                    user: source.user,
                    host: source.host,
                    modes: modes
                )
            )
        }
        pendingNames[name] = batch
        // Nothing is visible until 366: a half-applied nick list is worse than a late one.
        return []
    }

    private mutating func commitNames(channel name: IRCChannelName) -> [IRCChannelName] {
        guard channels[name] != nil else { return [] }
        guard let batch = pendingNames.removeValue(forKey: name) else {
            // 366 with no batches is an empty channel, which is a real answer.
            channels[name]?.replaceMembers([])
            return [name]
        }
        // `JOIN` may have arrived for someone between the 353 and the 366, so the batch is
        // merged over what is there rather than replacing it wholesale.
        var merged = batch
        let known = Set(batch.map(\.nick))
        if let existing = channels[name]?.orderedMembers {
            merged.append(contentsOf: existing.filter { !known.contains($0.nick) })
        }
        channels[name]?.replaceMembers(merged)
        return [name]
    }

    /// Losing the connection empties every channel but keeps every buffer. Nothing
    /// vanishes because wifi dropped.
    private mutating func applyStateChange(_ state: SessionState) -> [IRCChannelName] {
        guard case .disconnected = state else { return [] }
        var changed: [IRCChannelName] = []
        for name in order where channels[name]?.isJoined == true {
            channels[name]?.isJoined = false
            channels[name]?.clearMembers()
            changed.append(name)
        }
        pendingNames.removeAll()
        return changed
    }
}
