import Foundation
import Testing

@testable import CaravanUI

/// The networks a fresh install starts with.
@MainActor
@Suite("Default servers")
struct DefaultServersTests {
    private func freshURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "caravan-defaults-\(UUID().uuidString)")
            .appending(path: "servers.conf")
    }

    @Test("a first run is given the ten networks")
    func firstRunIsSeeded() {
        let url = freshURL()
        let list = ServerList(config: ConfigFile(url: url), seedingDefaults: true)

        #expect(list.entries.count == 10)
        #expect(list.names.contains("libera"))
        // Written through to the file, which is the user's from that moment: defaults that
        // lived only in the binary would be defaults nobody could diff or delete.
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reread = ServerList(config: ConfigFile(url: url))
        #expect(reread.entries.count == 10)
    }

    /// **"First run" means no file, not an empty one.** Somebody who deletes every entry has
    /// said something, and a client that puts ten networks back is arguing with them.
    @Test("an emptied list stays empty")
    func deletingThemAllSticks() {
        let url = freshURL()
        let first = ServerList(config: ConfigFile(url: url), seedingDefaults: true)
        for entry in first.entries { first.remove(entry.name) }
        #expect(first.entries.isEmpty)

        let second = ServerList(config: ConfigFile(url: url), seedingDefaults: true)
        #expect(second.entries.isEmpty, "the file exists, so this is not a first run")
    }

    @Test("an existing list is not added to")
    func existingListIsLeftAlone() {
        let url = freshURL()
        let existing = ServerList(config: ConfigFile(url: url))
        existing.save(ServerEntry(name: "mine", host: "irc.example.org"))

        let reopened = ServerList(config: ConfigFile(url: url), seedingDefaults: true)
        #expect(reopened.entries.map(\.name) == ["mine"])
    }

    @Test("without the flag, nothing is seeded — which is what every test relies on")
    func seedingIsOptIn() {
        #expect(ServerList(config: ConfigFile(url: freshURL())).entries.isEmpty)
    }

    /// A pre-populated entry that cannot connect is worse than no entry, and every field
    /// here was checked against the live server before it was written down.
    @Test("every default is valid, named legally, and dials nobody on startup")
    func entriesAreWellFormed() {
        for entry in DefaultServers.entries {
            #expect(entry.isValid, "\(entry.name)")
            #expect(NetworkName.isValid(entry.name), "\(entry.name) must be a legal network name")
            #expect(!entry.host.isEmpty)
            #expect(!entry.connectsOnStartup, "\(entry.name) must not dial on launch")
            #expect(!entry.isFavourite)
            #expect(entry.nick.isEmpty, "the nick comes from the global setting")
            #expect(entry.port == (entry.useTLS ? 6697 : 6667), "\(entry.name)")
        }
    }

    /// The two the rankings include and TLS does not reach. They ship because they are two of
    /// the largest networks on the internet, and they are marked in the Dashboard because a
    /// cleartext default the user cannot see is the thing worth avoiding.
    @Test("exactly Undernet and QuakeNet are cleartext")
    func knownCleartextNetworks() {
        let cleartext = DefaultServers.entries.filter { !$0.useTLS }.map(\.name).sorted()
        #expect(cleartext == ["quakenet", "undernet"])
    }

    @Test("no two entries share a name")
    func namesAreUnique() {
        let names = DefaultServers.entries.map(\.name)
        #expect(Set(names).count == names.count)
    }
}
