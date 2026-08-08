import Foundation
import IRCProtocol
import Testing

@testable import CaravanUI

/// The list itself: matching, expiry, and the file it survives in.
@MainActor
@Suite("The ignore list")
struct IgnoreListTests {
    private func list() -> IgnoreList {
        IgnoreList(config: temporaryConfig())
    }

    private func bob(host: String = "home.example") -> IRCSource {
        .user(nick: "bob", user: "~bob", host: host)
    }

    // MARK: - Matching

    @Test("a bare nick becomes a nick mask and matches whatever host they are on")
    func nickMask() {
        #expect(IgnoreList.mask(for: "bob") == "bob!*@*")
        // Anything already shaped like a mask is left exactly as typed.
        #expect(IgnoreList.mask(for: "*!*@spam.example") == "*!*@spam.example")
        #expect(IgnoreList.mask(for: "bob!~bob@home.example") == "bob!~bob@home.example")

        let ignores = list()
        ignores.add(IgnoreEntry(mask: IgnoreList.mask(for: "bob")))
        #expect(ignores.levels(for: bob()) == .all)
        #expect(ignores.levels(for: bob(host: "elsewhere.example")) == .all)
        #expect(ignores.levels(for: .user(nick: "carol", user: "c", host: "home.example")) == [])
    }

    /// A source with no user or host still has to match `bob!*@*`, which is what
    /// `/ignore bob` writes — and `IRCSource.wireForm` renders it as a bare `bob`.
    @Test("a source the server sent without a user or host still matches")
    func sparseSource() {
        #expect(IgnoreList.matchable(.user(nick: "bob", user: nil, host: nil)) == "bob!*@*")
        let ignores = list()
        ignores.add(IgnoreEntry(mask: "bob!*@*"))
        #expect(ignores.levels(for: .user(nick: "bob", user: nil, host: nil)) == .all)
        // But it does not match a *specific* mask, because we do not know that it is him.
        let specific = list()
        specific.add(IgnoreEntry(mask: "bob!steve@host"))
        #expect(specific.levels(for: .user(nick: "bob", user: nil, host: nil)) == [])
    }

    /// A `*!*@*` entry taking out the MOTD would be a spectacular way to lose a
    /// connection's own diagnostics.
    @Test("a server is never ignorable, however broad the mask")
    func serversAreNeverIgnored() {
        let ignores = list()
        ignores.add(IgnoreEntry(mask: "*!*@*"))
        #expect(ignores.levels(for: .server("irc.libera.chat")) == [])
        #expect(ignores.levels(for: bob()) == .all)
    }

    /// Order of entry must not decide the answer.
    @Test("two masks that both catch somebody combine their levels")
    func overlappingEntries() {
        let ignores = list()
        ignores.add(IgnoreEntry(mask: "bob!*@*", levels: .notices))
        ignores.add(IgnoreEntry(mask: "*!*@home.example", levels: .ctcps))
        #expect(ignores.levels(for: bob()) == [.notices, .ctcps])
    }

    @Test("adding the same mask twice corrects it rather than stacking a second entry")
    func replacingAnEntry() {
        let ignores = list()
        ignores.add(IgnoreEntry(mask: "bob!*@*", levels: .privateMessages))
        ignores.add(IgnoreEntry(mask: "bob!*@*", levels: .notices))
        #expect(ignores.entries.count == 1)
        #expect(ignores.levels(for: bob()) == .notices)
    }

    @Test("removing says whether there was anything to remove")
    func removing() {
        let ignores = list()
        ignores.add(IgnoreEntry(mask: "bob!*@*"))
        #expect(ignores.remove(mask: "bob!*@*"))
        #expect(!ignores.remove(mask: "bob!*@*"))
        #expect(ignores.entries.isEmpty)
    }

    // MARK: - Expiry

    @Test("a temporary ignore lapses on its own")
    func expiry() {
        let ignores = list()
        let start = Date()
        var clock = start
        ignores.now = { clock }
        ignores.add(
            IgnoreEntry(mask: "bob!*@*", expires: start.addingTimeInterval(600))
        )
        #expect(ignores.levels(for: bob()) == .all)

        clock = start.addingTimeInterval(599)
        #expect(ignores.levels(for: bob()) == .all)

        clock = start.addingTimeInterval(601)
        #expect(ignores.levels(for: bob()) == [])
        // Swept rather than merely filtered, so the file stops claiming it too.
        #expect(ignores.entries.isEmpty)
    }

    // MARK: - The file

    @Test("an entry round-trips through the file it is written to")
    func persistence() {
        let config = temporaryConfig()
        let first = IgnoreList(config: config)
        first.add(IgnoreEntry(mask: "*!*@spam.example", levels: [.channelMessages, .notices]))
        first.add(IgnoreEntry(mask: "bob!*@*"))

        let second = IgnoreList(config: ConfigFile(url: config.url))
        #expect(second.entries.map(\.mask) == ["*!*@spam.example", "bob!*@*"])
        #expect(second.entries[0].levels == [.channelMessages, .notices])
        #expect(second.entries[1].levels == .all)
    }

    /// The value's shape is public API, the same way every other key in this file is.
    @Test("the written form is levels, then mask, then an optional expiry")
    func fileFormat() throws {
        let config = temporaryConfig()
        let ignores = IgnoreList(config: config)
        ignores.add(IgnoreEntry(mask: "*!*@spam.example", levels: [.channelMessages, .notices]))
        #expect(config.string("ignore.1") == "cn *!*@spam.example")

        ignores.add(IgnoreEntry(mask: "bob!*@*"))
        #expect(config.string("ignore.2") == "* bob!*@*")

        // And it reads back what it writes, which is the property that matters.
        #expect(IgnoreList.parse("cn *!*@spam.example")?.levels == [.channelMessages, .notices])
        #expect(IgnoreList.parse("* bob!*@*")?.levels == .all)
        #expect(IgnoreList.parse("garbage") == nil)
        #expect(IgnoreList.parse("zz bob!*@*") == nil, "an unknown letter is not an entry")
    }

    /// A file full of expired entries is a file that lies about what the client is doing.
    @Test("a lapsed entry is dropped on the way in and rewritten out of the file")
    func lapsedEntriesAreNotLoaded() {
        let config = temporaryConfig()
        config.set("* bob!*@* 1000000000", forKey: "ignore.1")
        config.set("* carol!*@*", forKey: "ignore.2")

        let ignores = IgnoreList(config: config)
        #expect(ignores.entries.map(\.mask) == ["carol!*@*"])
        // Renumbered from one, so the file does not grow holes.
        #expect(config.string("ignore.1") == "* carol!*@*")
        #expect(config.string("ignore.2") == nil)
    }

    /// `ignore.10` after `ignore.2`, which a plain string sort gets backwards.
    @Test("entries load in numeric order, not alphabetical")
    func numericOrder() {
        let config = temporaryConfig()
        for index in 1...11 {
            config.set("* nick\(index)!*@*", forKey: "ignore.\(index)")
        }
        let ignores = IgnoreList(config: config)
        #expect(ignores.entries.map(\.mask).last == "nick11!*@*")
        #expect(ignores.entries[1].mask == "nick2!*@*")
    }

    /// The rule `ChatSettings.colourOverrides` already follows: a key this family owns has
    /// to be clearable even when the app never wrote it.
    @Test("a hand-added entry is owned, and a rewrite clears it")
    func handEditedKeys() {
        let config = temporaryConfig()
        config.set("p bob!*@*", forKey: "ignore.7")
        let ignores = IgnoreList(config: config)
        #expect(ignores.entries.map(\.mask) == ["bob!*@*"])

        ignores.remove(mask: "bob!*@*")
        #expect(config.string("ignore.7") == nil)
        #expect(config.keys(withPrefix: "ignore.").isEmpty)
    }

    /// The exact shape of the live acceptance run: an entry written by hand into
    /// `caravan.conf`, matched against the source a real server actually sends.
    @Test("a hand-written entry matches a real server's source")
    func liveShape() {
        let config = temporaryConfig()
        config.set("* caravan-peer1!*@*", forKey: "ignore.1")
        let ignores = IgnoreList(config: config)
        #expect(ignores.entries.map(\.mask) == ["caravan-peer1!*@*"])
        let source = IRCSource(prefix: "caravan-peer1!~caravan-p@189.146.108.51")
        #expect(ignores.levels(for: source) == .all)
    }
}
