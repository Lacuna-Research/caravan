import Foundation
import Testing

@testable import CaravanUI

@MainActor
private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "caravan-servers-\(UUID().uuidString)")
        .appending(path: name)
}

/// Every key in a config file, so an assertion about keys cannot be fooled by a value that
/// happens to contain the same characters.
@MainActor
private func keys(in url: URL) -> [String] {
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return text.components(separatedBy: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        return String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
}

/// The stable name every durable key hangs off.
@MainActor
@Suite("Network names")
struct NetworkNameTests {
    @Test("the shape is constrained, and for reasons")
    func validity() {
        #expect(NetworkName.isValid("libera"))
        #expect(NetworkName.isValid("libera-2"))
        #expect(NetworkName.isValid("my_net9"))
        #expect(!NetworkName.isValid(""))
        // No slash: `libera/#swift` is the addressing form, and a name with one in it
        // could not be told from a name plus a buffer.
        #expect(!NetworkName.isValid("a/b"))
        // No dot: `order.<name>.channels` puts the name in the middle of a dotted key.
        #expect(!NetworkName.isValid("irc.libera.chat"))
        // No upper case, so two entries cannot differ by case alone.
        #expect(!NetworkName.isValid("Libera"))
        #expect(!NetworkName.isValid("has space"))
        #expect(!NetworkName.isValid(String(repeating: "a", count: 33)))
    }

    @Test(
        "a host suggests the word a person would have picked",
        arguments: [
            ("irc.libera.chat", "libera"),
            ("chat.freenode.net", "freenode"),
            ("soju.example.org", "soju"),
            ("irc.example.co.uk", "example"),
            ("localhost", "localhost"),
            ("127.0.0.1", "127-0-0-1"),
        ]
    )
    func suggestions(host: String, expected: String) {
        #expect(NetworkName.suggestion(forHost: host) == expected)
    }

    @Test("anything can be made into a name")
    func sanitising() {
        #expect(NetworkName.sanitised("My Server!") == "my-server")
        #expect(NetworkName.sanitised("  ...  ") == "")
        #expect(NetworkName.sanitised("a//b") == "a-b")
        #expect(NetworkName.sanitised(String(repeating: "x", count: 50)).count == 32)
    }

    /// Suffixed rather than refused: adding a second Libera account should not make the
    /// user invent a word for it before they can connect.
    @Test("a taken name gains a suffix")
    func uniquing() {
        #expect(NetworkName.unique("libera", taken: []) == "libera")
        #expect(NetworkName.unique("libera", taken: ["libera"]) == "libera-2")
        #expect(NetworkName.unique("libera", taken: ["libera", "libera-2"]) == "libera-3")
        // The suffix has to survive the length cap, or the "unique" name equals a taken one.
        let long = String(repeating: "a", count: 32)
        let unique = NetworkName.unique(long, taken: [long])
        #expect(unique != long)
        #expect(unique.count <= NetworkName.maximumLength)
    }
}

/// The list itself, and its file.
@MainActor
@Suite("Server list")
struct ServerListTests {
    private func list() -> ServerList {
        ServerList(config: ConfigFile(url: temporaryFile("servers.conf")))
    }

    @Test("an entry round-trips through the file")
    func roundTrip() throws {
        let url = temporaryFile("servers.conf")
        let servers = ServerList(config: ConfigFile(url: url))
        var entry = ServerEntry(name: "libera", host: "irc.libera.chat")
        entry.group = "Public"
        entry.nick = "alice"
        entry.autojoin = ["#swift", "#vapor"]
        entry.perform = ["/msg NickServ identify hunter2", "/mode alice +i"]
        entry.connectsOnStartup = true
        entry.isFavourite = true
        entry.authentication = .saslPlain
        entry.account = "alice"
        servers.save(entry)

        let reread = ServerList(config: ConfigFile(url: url))
        #expect(reread.entry(named: "libera") == entry)
    }

    /// A hand-written entry should be two lines, not thirteen.
    @Test("a host is enough to make an entry")
    func minimalEntry() throws {
        let url = temporaryFile("servers.conf")
        try write("libera.host = irc.libera.chat\n", to: url)
        let servers = ServerList(config: ConfigFile(url: url))
        let entry = try #require(servers.entry(named: "libera"))
        #expect(entry.host == "irc.libera.chat")
        #expect(entry.port == 6697)
        #expect(entry.useTLS)
    }

    @Test("only what differs from the default is written")
    func defaultsAreAbsent() throws {
        let url = temporaryFile("servers.conf")
        let servers = ServerList(config: ConfigFile(url: url))
        servers.save(ServerEntry(name: "libera", host: "irc.libera.chat"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("libera.host = irc.libera.chat"))
        #expect(!text.contains("libera.group"))
        #expect(!text.contains("libera.favourite"))
        #expect(!text.contains("libera.perform"))
    }

    @Test("a hand-edited file survives an entry being changed")
    func handEditedFileSurvives() throws {
        let url = temporaryFile("servers.conf")
        try write(
            """
            # My servers. Keep this comment.
            libera.host = irc.libera.chat

            something.unknown = kept
            """,
            to: url
        )
        let servers = ServerList(config: ConfigFile(url: url))
        var entry = try #require(servers.entry(named: "libera"))
        entry.group = "Public"
        servers.save(entry)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# My servers. Keep this comment."))
        #expect(text.contains("something.unknown = kept"))
        #expect(text.contains("\n\n"))
    }

    @Test("removing an entry clears every line it owns")
    func removalIsComplete() throws {
        let url = temporaryFile("servers.conf")
        let servers = ServerList(config: ConfigFile(url: url))
        var entry = ServerEntry(name: "libera", host: "irc.libera.chat")
        entry.group = "Public"
        entry.autojoin = ["#swift"]
        servers.save(entry)
        servers.remove("libera")

        #expect(!keys(in: url).contains { $0.hasPrefix("libera.") })
        #expect(ServerList(config: ConfigFile(url: url)).entries.isEmpty)
    }

    /// A name the key scheme cannot round-trip is refused rather than stored, because
    /// `order.my.net.channels` parses as the network `my` and the section `net.channels`.
    @Test("an invalid name is refused")
    func invalidNamesRefused() {
        let servers = list()
        #expect(!servers.save(ServerEntry(name: "my.net", host: "h")))
        #expect(!servers.save(ServerEntry(name: "a/b", host: "h")))
        #expect(servers.entries.isEmpty)
    }

    @Test("entries sort ungrouped first, then by group, then by name")
    func ordering() {
        let servers = list()
        servers.save(ServerEntry(name: "zeta", host: "z"))
        servers.save(ServerEntry(name: "alpha", host: "a", group: "Work"))
        servers.save(ServerEntry(name: "beta", host: "b", group: "Work"))
        #expect(servers.entries.map(\.name) == ["zeta", "alpha", "beta"])
    }

    /// **The duplicate the acceptance run produced.** A rename has to leave exactly one
    /// entry and no key of the old name anywhere.
    @Test("a rename leaves no keys behind")
    func renameLeavesNothing() throws {
        let url = temporaryFile("servers.conf")
        let servers = ServerList(config: ConfigFile(url: url))
        var entry = ServerEntry(name: "libera", host: "irc.libera.chat")
        entry.group = "Public"
        entry.autojoin = ["#swift"]
        servers.save(entry)

        #expect(servers.rename("libera", to: "lc"))

        #expect(servers.entries.map(\.name) == ["lc"])
        // Keys at the start of a line, not a substring search: the *host* is
        // `irc.libera.chat`, which contains "libera." and made the first version of this
        // assertion fail for entirely the wrong reason.
        #expect(!keys(in: url).contains { $0.hasPrefix("libera.") })
        #expect(keys(in: url).contains("lc.autojoin"))
        // And still one on the next launch, which is where the duplicate showed up.
        #expect(ServerList(config: ConfigFile(url: url)).entries.count == 1)
    }

    /// The condition `ServerEditor.update` checks before writing. A view torn down after a
    /// rename writes its fields' last values back through their bindings under the *old*
    /// name, which is what recreated the entry the rename had just moved away from.
    @Test("a name that is gone stays gone")
    func renamedNameIsGone() {
        let servers = list()
        servers.save(ServerEntry(name: "libera", host: "irc.libera.chat"))
        servers.rename("libera", to: "lc")
        #expect(servers.entry(named: "libera") == nil)
        #expect(servers.entries.count == 1)
    }
}
