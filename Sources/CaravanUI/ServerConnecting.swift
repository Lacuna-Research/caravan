import Foundation
import IRCProtocol
import IRCSession

extension AppModel {
    /// Connects to a server-list entry, or selects it if it is already open.
    ///
    /// **The one route from the list to a live connection.** Everything the entry carries
    /// that the session needs — identity, authentication, the bouncer network — is folded
    /// into a `ConnectionSettings` here, so the entry stays a record and the connection
    /// stays the thing that knows how to dial.
    @discardableResult
    public func connect(to entry: ServerEntry) async -> ConnectionViewModel? {
        guard entry.isValid else { return nil }
        if let existing = connections.first(where: { $0.networkName == entry.name }) {
            reveal(.status(existing.id))
            if case .disconnected = existing.state { await existing.connect() }
            return existing
        }
        let connection = await connect(using: settings(for: entry))
        connection?.networkName = entry.name
        if let connection { await perform(entry, on: connection) }
        return connection
    }

    /// The entry as the connection layer wants it.
    ///
    /// The nickname is the entry's *override* where it has one and the global identity
    /// otherwise — §15.5's global-first convention, with the one field people genuinely
    /// differ on between networks allowed to differ.
    public func settings(for entry: ServerEntry) -> ConnectionSettings {
        var settings = ConnectionSettings.lastUsed(from: config, credentials: credentials)
        settings.host = entry.host
        settings.port = entry.port
        settings.useTLS = entry.useTLS
        if !entry.nick.isEmpty { settings.nick = entry.nick }
        settings.authentication = entry.authentication
        settings.account = entry.account
        settings.certificateLabel = entry.certificateLabel
        settings.bouncerNetwork = entry.bouncerNetwork
        // Keyed on the host, which is where the Connect sheet put them and where
        // `loadSecrets` looks. Reading them for the entry's host rather than the previous
        // one is the whole reason that function is separate.
        settings.loadSecrets(from: credentials)
        return settings
    }

    /// Autojoin and perform, once the connection is actually registered.
    ///
    /// **Waits for registration rather than firing on connect.** A `JOIN` sent before the
    /// server has welcomed you is answered with an error or dropped, which is the classic
    /// way an autojoin list appears to work for the author and not for anyone whose link is
    /// slower. There is no ordering promise between the two beyond perform-then-join:
    /// identifying to services before joining is the case that actually matters, since a
    /// `+r` channel refuses an unidentified user.
    private func perform(_ entry: ServerEntry, on connection: ConnectionViewModel) async {
        guard !entry.perform.isEmpty || !entry.autojoin.isEmpty else { return }
        guard await connection.waitUntilRegistered() else { return }

        for line in entry.perform {
            await submit(line, from: nil, on: connection)
        }
        guard !entry.autojoin.isEmpty else { return }
        // One `JOIN` with a comma list, which is what the command already builds and what
        // a server would rather receive than one line per channel.
        await submit("/join \(entry.autojoin.joined(separator: ","))", from: nil, on: connection)
    }

    /// Renames an entry, and tells any live connection about it.
    ///
    /// **The list alone is not enough.** `ServerList.rename` moves the entry and the two
    /// key families, but a connection already open still answers to the old name — so
    /// `networkKey` would disagree with the freshly-rewritten `binding.N` and ⌘3 would
    /// report the network as not open while it sat there in the tree. Found by renaming a
    /// connected network during the acceptance run.
    @discardableResult
    public func renameServer(_ old: String, to new: String) -> Bool {
        guard servers.rename(old, to: new, movingKeysIn: config) else { return false }
        // Three in-memory copies, all parsed at launch and none of them the file.
        for connection in connections where connection.networkName == old {
            connection.networkName = new
        }
        bindings.renameNetwork(old, to: new)
        bufferOrder.renameNetwork(old, to: new)
        return true
    }

    /// Dials every entry marked connect-on-startup, in list order.
    ///
    /// Sequential rather than concurrent, and deliberately: three simultaneous handshakes
    /// against the same bouncer is the shape of a connection storm, and the wait is a
    /// second per network on a path nobody is watching.
    public func connectStartupServers() async {
        for entry in servers.entries where entry.connectsOnStartup {
            await connect(to: entry)
        }
    }
}

extension ConnectionViewModel {
    /// Waits for registration to finish, or gives up.
    ///
    /// Polled rather than event-driven because the event pump is already consumed by the
    /// view model — a second subscriber would be a second reader of the same stream. The
    /// timeout is what stops an autojoin sitting forever against a server that accepted the
    /// socket and then said nothing.
    func waitUntilRegistered(timeout: Duration = .seconds(30)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if isConnected { return true }
            // **`.notStarted` means "has not begun", not "failed"**, and treating the two
            // alike is why the first live run autojoined nothing: the wait begins before
            // the connection has moved off its initial state, saw a `.disconnected`, and
            // gave up a millisecond in. Every other disconnect reason really is the end.
            if case .disconnected(let reason) = state, !reason.isNotStarted { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
