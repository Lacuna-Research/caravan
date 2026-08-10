import Foundation
import Observation

/// One server the user keeps, identified by its ``NetworkName``.
///
/// **The name is the identity, not a label.** It is what `binding.N` and `order.<name>.*`
/// key on, and what stage 3 will address buffers with — so renaming one has to move those
/// keys, which is `ServerList.rename(_:to:)`'s job rather than a caller's.
///
/// **No passwords here.** The server password and the account password go to the
/// `CredentialStore`, keyed on the host, exactly as the Connect sheet put them there. This
/// struct records the *shape* of the credential — which mechanism, which account — and
/// never the secret, which is the same split `ConnectionSettings` documents.
public struct ServerEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var host: String
    public var port: UInt16
    public var useTLS: Bool

    /// What the Dashboard files this entry under. Empty means ungrouped, which sorts
    /// first — a user with three servers should not have to invent a group.
    public var group: String

    /// A nickname for this network only, or empty to use the global identity from the
    /// Options Connect tab. Per-server *overrides* rather than per-server settings: §15.5's
    /// convention is global first, and this is the one field people genuinely differ on
    /// between networks.
    public var nick: String

    /// Channels joined once registration completes, in order.
    public var autojoin: [String]

    /// Command lines run on connect, in order, exactly as if typed.
    ///
    /// Stored and run as *commands*, `/msg NickServ …`, not as raw wire lines: it is the
    /// same path a user's own typing takes, so anything they can type they can perform.
    public var perform: [String]

    public var connectsOnStartup: Bool
    public var isFavourite: Bool

    public var authentication: ConnectionSettings.AuthenticationChoice
    public var account: String
    public var certificateLabel: String

    /// The bouncer network this entry binds to, or empty for a direct connection.
    public var bouncerNetwork: String

    public var id: String { name }

    public init(
        name: String,
        host: String,
        port: UInt16 = 6697,
        useTLS: Bool = true,
        group: String = "",
        nick: String = "",
        autojoin: [String] = [],
        perform: [String] = [],
        connectsOnStartup: Bool = false,
        isFavourite: Bool = false,
        authentication: ConnectionSettings.AuthenticationChoice = .none,
        account: String = "",
        certificateLabel: String = "",
        bouncerNetwork: String = ""
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.group = group
        self.nick = nick
        self.autojoin = autojoin
        self.perform = perform
        self.connectsOnStartup = connectsOnStartup
        self.isFavourite = isFavourite
        self.authentication = authentication
        self.account = account
        self.certificateLabel = certificateLabel
        self.bouncerNetwork = bouncerNetwork
    }

    /// Whether this entry has enough to dial.
    public var isValid: Bool {
        NetworkName.isValid(name) && !host.isEmpty && port > 0
    }
}

/// The servers the user keeps, in `$XDG_CONFIG_HOME/caravan/servers.conf`.
///
/// **Its own file, not `caravan.conf`.** Same format and the same `ConfigFile` machinery —
/// write straight through on change, rewrite only the lines you own, survive being hand
/// edited — but a separate file, because ten entries of eleven fields each would bury the
/// handful of scalars a user actually goes to the settings file to change. The precedent is
/// `known_hosts`: a list of records has a different shape and a different lifecycle from a
/// page of settings, and separating them is what keeps both readable.
///
/// Keys are `<name>.<field>`, which parses on the first dot — and is exactly why
/// ``NetworkName`` forbids a dot inside a name.
@MainActor
@Observable
public final class ServerList {
    public static let shared = ServerList(seedingDefaults: true)

    /// Sorted for display: ungrouped first, then by group, then by name. Derived rather
    /// than stored, so a hand-edited file needs no ordering key to look tidy.
    public var entries: [ServerEntry] {
        storage.values.sorted {
            ($0.group.lowercased(), $0.name) < ($1.group.lowercased(), $1.name)
        }
    }

    private var storage: [String: ServerEntry] = [:]

    @ObservationIgnored private let config: ConfigFile

    public var url: URL { config.url }

    /// `$XDG_CONFIG_HOME/caravan/servers.conf`, beside `caravan.conf`.
    public static var defaultURL: URL {
        ConfigFile.directory.appending(path: "servers.conf")
    }

    /// - Parameter seedingDefaults: whether a **first run** should be given
    ///   ``DefaultServers``. Off by default so a test gets the empty list it asked for, and
    ///   on for ``shared``, which is the only one a person ever sees.
    public init(
        config: ConfigFile = ConfigFile(url: ServerList.defaultURL),
        seedingDefaults: Bool = false
    ) {
        self.config = config
        self.storage = Self.read(config)
        if seedingDefaults { seedDefaultsOnFirstRun() }
    }

    /// Writes ``DefaultServers`` into the file, but only when there is no file at all.
    ///
    /// **"First run" means the file does not exist, not that it holds nothing.** A user who
    /// deletes every entry has said something, and a client that answers by putting ten
    /// networks back is a client arguing with them. The distinction costs one `fileExists`
    /// and is the difference between a starting point and a nag.
    ///
    /// Written through rather than held in memory, because the file is the truth here:
    /// `servers.conf` is documented, hand-editable and a public path, and defaults that
    /// existed only in the binary would be defaults the user cannot see, diff or delete.
    private func seedDefaultsOnFirstRun() {
        guard !FileManager.default.fileExists(atPath: config.url.path) else { return }
        for entry in DefaultServers.entries {
            save(entry)
        }
    }

    public func entry(named name: String) -> ServerEntry? { storage[name] }

    public var names: Set<String> { Set(storage.keys) }

    /// Adds or replaces an entry, writing it through immediately.
    ///
    /// Rejects an invalid name rather than storing something the key scheme cannot round
    /// trip — a `.` in a name would produce `order.my.net.channels`, which parses as the
    /// network `my` and the section `net.channels`.
    @discardableResult
    public func save(_ entry: ServerEntry) -> Bool {
        guard NetworkName.isValid(entry.name) else { return false }
        storage[entry.name] = entry
        write(entry)
        return true
    }

    public func remove(_ name: String) {
        guard storage.removeValue(forKey: name) != nil else { return }
        for field in Field.allCases { config.set(nil, forKey: Self.key(name, field)) }
    }

    /// Renames an entry **and moves everything keyed on the old name with it**.
    ///
    /// The whole reason this is a method rather than `save` with a changed name: `binding.N`
    /// and `order.<name>.{channels,queries}` both key on it, and a rename that left them
    /// behind would silently drop the user's ⌘1–9 and their manual tree order. Those live in
    /// `caravan.conf`, which is a different file, so the caller hands them in.
    @discardableResult
    public func rename(
        _ old: String,
        to new: String,
        movingKeysIn settings: ConfigFile? = nil
    ) -> Bool {
        guard old != new, var entry = storage[old], NetworkName.isValid(new),
            storage[new] == nil
        else { return false }
        remove(old)
        entry.name = new
        save(entry)
        settings.map { NetworkKeyMigration.rename(old, to: new, in: $0) }
        return true
    }

    // MARK: - The file

    /// One key per field. `CaseIterable` so removing an entry can clear every line it owns
    /// without a second list to keep in step.
    enum Field: String, CaseIterable {
        case host
        case port
        case tls
        case group
        case nick
        case autojoin
        case perform
        case connectOnStartup = "connect-on-startup"
        case favourite
        case authentication
        case account
        case certificate
        case bouncerNetwork = "bouncer-network"
    }

    static func key(_ name: String, _ field: Field) -> String { "\(name).\(field.rawValue)" }

    /// **Only what differs from the default is written.** A file the user has not shaped
    /// stays short, and a default that improves in a later version improves for everyone
    /// who never set it — the same rule `ChatSettings` follows.
    private func write(_ entry: ServerEntry) {
        let blank = ServerEntry(name: entry.name, host: entry.host)
        config.set(entry.host, forKey: Self.key(entry.name, .host))
        config.set(Int(entry.port), forKey: Self.key(entry.name, .port))
        config.set(entry.useTLS, forKey: Self.key(entry.name, .tls))
        set(entry.group, .group, on: entry)
        set(entry.nick, .nick, on: entry)
        set(entry.autojoin.joined(separator: " "), .autojoin, on: entry)
        // Semicolons, because a perform line is a command that may contain spaces and the
        // format cannot hold a newline. A command containing a literal `;` is not
        // expressible; `/raw` is the escape hatch, and mIRC has the same limit.
        set(entry.perform.joined(separator: ";"), .perform, on: entry)
        set(entry.account, .account, on: entry)
        set(entry.certificateLabel, .certificate, on: entry)
        set(entry.bouncerNetwork, .bouncerNetwork, on: entry)
        config.set(
            entry.authentication == blank.authentication ? nil : entry.authentication.rawValue,
            forKey: Self.key(entry.name, .authentication)
        )
        config.set(
            entry.connectsOnStartup ? "true" : nil,
            forKey: Self.key(entry.name, .connectOnStartup)
        )
        config.set(entry.isFavourite ? "true" : nil, forKey: Self.key(entry.name, .favourite))
    }

    private func set(_ value: String, _ field: Field, on entry: ServerEntry) {
        config.set(value.isEmpty ? nil : value, forKey: Self.key(entry.name, field))
    }

    private static func read(_ config: ConfigFile) -> [String: ServerEntry] {
        // An entry exists when it has a host; everything else takes a default. That makes
        // a hand-written entry two lines rather than thirteen.
        var entries: [String: ServerEntry] = [:]
        for key in config.keys(withPrefix: "") {
            guard let dot = key.firstIndex(of: "."),
                Field(rawValue: String(key[key.index(after: dot)...])) == .host
            else { continue }
            let name = String(key[key.startIndex..<dot])
            guard NetworkName.isValid(name), let host = config.string(key), !host.isEmpty
            else { continue }
            entries[name] = read(name: name, host: host, from: config)
        }
        return entries
    }

    private static func read(name: String, host: String, from config: ConfigFile) -> ServerEntry {
        func value(_ field: Field) -> String? { config.string(key(name, field)) }
        var entry = ServerEntry(name: name, host: host)
        entry.port = config.int(key(name, .port)).map { UInt16(clamping: $0) } ?? entry.port
        entry.useTLS = config.bool(key(name, .tls)) ?? entry.useTLS
        entry.group = value(.group) ?? ""
        entry.nick = value(.nick) ?? ""
        entry.autojoin = value(.autojoin)?.split(separator: " ").map(String.init) ?? []
        entry.perform =
            value(.perform)?
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        entry.connectsOnStartup = config.bool(key(name, .connectOnStartup)) ?? false
        entry.isFavourite = config.bool(key(name, .favourite)) ?? false
        // An unknown mechanism takes `.none` rather than refusing to launch, the same rule
        // `chat.palette = darkk` follows: a typo costs you the setting, not the app.
        entry.authentication =
            value(.authentication)
            .flatMap(ConnectionSettings.AuthenticationChoice.init(rawValue:)) ?? .none
        entry.account = value(.account) ?? ""
        entry.certificateLabel = value(.certificate) ?? ""
        entry.bouncerNetwork = value(.bouncerNetwork) ?? ""
        return entry
    }
}
