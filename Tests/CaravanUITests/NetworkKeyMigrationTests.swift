import Foundation
import Testing

@testable import CaravanUI

/// Moving `binding.N` and `order.<network>.*` onto the stable name.
///
/// **These keys are public API.** Somebody who bound ⌘3 last week has to find ⌘3 working
/// this week, so every assertion here is really the same one: nothing is dropped because
/// its format changed.
@MainActor
@Suite("Network key migration")
struct NetworkKeyMigrationTests {
    private func files() -> (settings: ConfigFile, servers: ServerList) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "caravan-migration-\(UUID().uuidString)")
        return (
            ConfigFile(url: directory.appending(path: "caravan.conf")),
            ServerList(config: ConfigFile(url: directory.appending(path: "servers.conf")))
        )
    }

    @Test("a binding on a known server moves to its name")
    func bindingMovesToAnExistingEntry() {
        let (settings, servers) = files()
        servers.save(ServerEntry(name: "libera", host: "irc.libera.chat", port: 6697))
        settings.set("irc.libera.chat:6697/#swift", forKey: "binding.3")

        NetworkKeyMigration.run(settings: settings, servers: servers)

        #expect(settings.string("binding.3") == "libera/#swift")
        #expect(BufferBindings(config: settings).binding(for: 3)?.network == "libera")
    }

    /// The case that decides whether this is a migration or a data loss: a binding whose
    /// server is not in the list *creates* the server.
    @Test("a binding on an unknown server creates the server")
    func bindingCreatesAMissingEntry() throws {
        let (settings, servers) = files()
        settings.set("irc.libera.chat:6697/#swift", forKey: "binding.1")

        let created = NetworkKeyMigration.run(settings: settings, servers: servers)

        #expect(created == ["libera"])
        let entry = try #require(servers.entry(named: "libera"))
        #expect(entry.host == "irc.libera.chat")
        #expect(entry.port == 6697)
        #expect(settings.string("binding.1") == "libera/#swift")
    }

    @Test("a bouncer network keeps its own word as the name")
    func bouncerNetworksUseTheirOwnName() throws {
        let (settings, servers) = files()
        settings.set("soju.example.org:6697[libera]/#swift", forKey: "binding.2")

        NetworkKeyMigration.run(settings: settings, servers: servers)

        let entry = try #require(servers.entry(named: "libera"))
        #expect(entry.host == "soju.example.org")
        #expect(entry.bouncerNetwork == "libera")
        #expect(settings.string("binding.2") == "libera/#swift")
    }

    @Test("the manual tree order moves too")
    func orderKeysMove() {
        let (settings, servers) = files()
        servers.save(ServerEntry(name: "libera", host: "irc.libera.chat"))
        settings.set("#swift,#vapor", forKey: "order.irc.libera.chat:6697.channels")
        settings.set("bob", forKey: "order.irc.libera.chat:6697.queries")

        NetworkKeyMigration.run(settings: settings, servers: servers)

        #expect(settings.string("order.libera.channels") == "#swift,#vapor")
        #expect(settings.string("order.libera.queries") == "bob")
        #expect(settings.string("order.irc.libera.chat:6697.channels") == nil)
    }

    /// Two keys naming the same old network must land on *one* entry, not two.
    @Test("one old network becomes one entry however many keys name it")
    func oneNetworkOneEntry() {
        let (settings, servers) = files()
        settings.set("irc.libera.chat:6697/#swift", forKey: "binding.1")
        settings.set("irc.libera.chat:6697/#vapor", forKey: "binding.2")
        settings.set("#swift", forKey: "order.irc.libera.chat:6697.channels")

        let created = NetworkKeyMigration.run(settings: settings, servers: servers)

        #expect(created == ["libera"])
        #expect(servers.entries.count == 1)
        #expect(settings.string("binding.2") == "libera/#vapor")
        #expect(settings.string("order.libera.channels") == "#swift")
    }

    /// A second launch must not migrate the migrated, which would turn `libera` into a
    /// host and make an entry called `libera-2`.
    @Test("running twice changes nothing the second time")
    func idempotent() {
        let (settings, servers) = files()
        settings.set("irc.libera.chat:6697/#swift", forKey: "binding.1")

        NetworkKeyMigration.run(settings: settings, servers: servers)
        let afterFirst = settings.string("binding.1")
        let created = NetworkKeyMigration.run(settings: settings, servers: servers)

        #expect(created.isEmpty)
        #expect(settings.string("binding.1") == afterFirst)
        #expect(servers.entries.count == 1)
    }

    @Test("a status-window binding, which has no buffer part, still moves")
    func statusBindingsMove() {
        let (settings, servers) = files()
        servers.save(ServerEntry(name: "libera", host: "irc.libera.chat"))
        settings.set("irc.libera.chat:6697", forKey: "binding.4")

        NetworkKeyMigration.run(settings: settings, servers: servers)

        #expect(settings.string("binding.4") == "libera")
    }

    // MARK: - Renaming

    /// The user's own rename. Without this their ⌘1–9 and their tree order silently point
    /// at a network that no longer answers to that name.
    @Test("renaming an entry brings its bindings and order with it")
    func renameMovesEverything() {
        let (settings, servers) = files()
        servers.save(ServerEntry(name: "libera", host: "irc.libera.chat"))
        settings.set("libera/#swift", forKey: "binding.3")
        settings.set("#swift,#vapor", forKey: "order.libera.channels")

        #expect(servers.rename("libera", to: "lc", movingKeysIn: settings))

        #expect(servers.entry(named: "lc")?.host == "irc.libera.chat")
        #expect(servers.entry(named: "libera") == nil)
        #expect(settings.string("binding.3") == "lc/#swift")
        #expect(settings.string("order.lc.channels") == "#swift,#vapor")
        #expect(settings.string("order.libera.channels") == nil)
    }

    @Test("a rename onto a taken name, or an invalid one, is refused")
    func renameRefusals() {
        let (settings, servers) = files()
        servers.save(ServerEntry(name: "libera", host: "a"))
        servers.save(ServerEntry(name: "oftc", host: "b"))

        #expect(!servers.rename("libera", to: "oftc", movingKeysIn: settings))
        #expect(!servers.rename("libera", to: "my.net", movingKeysIn: settings))
        #expect(!servers.rename("nothing", to: "fine", movingKeysIn: settings))
        #expect(servers.entry(named: "libera")?.host == "a")
        #expect(servers.entry(named: "oftc")?.host == "b")
    }

    /// A rename must not disturb *another* network's keys.
    @Test("renaming one network leaves the others alone")
    func renameIsScoped() {
        let (settings, servers) = files()
        servers.save(ServerEntry(name: "libera", host: "a"))
        servers.save(ServerEntry(name: "oftc", host: "b"))
        settings.set("libera/#swift", forKey: "binding.1")
        settings.set("oftc/#swift", forKey: "binding.2")
        settings.set("#a", forKey: "order.oftc.channels")

        servers.rename("libera", to: "lc", movingKeysIn: settings)

        #expect(settings.string("binding.2") == "oftc/#swift")
        #expect(settings.string("order.oftc.channels") == "#a")
    }

    // MARK: - First launch

    /// The upgrade path, and the acceptance-run harness, in one rule.
    @Test("a pre-server-list config becomes the first entry")
    func lastUsedServerBecomesAnEntry() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "caravan-adopt-\(UUID().uuidString)")
        let config = ConfigFile(url: directory.appending(path: "caravan.conf"))
        config.set("irc.libera.chat", forKey: ConnectionSettings.Key.host)
        config.set(6697, forKey: ConnectionSettings.Key.port)
        let servers = ServerList(config: ConfigFile(url: directory.appending(path: "servers.conf")))

        _ = AppModel(
            config: config,
            knownHosts: temporaryKnownHosts(),
            credentials: EphemeralCredentialStore(),
            servers: servers
        )

        let entry = try #require(servers.entry(named: "libera"))
        #expect(entry.host == "irc.libera.chat")
        #expect(entry.port == 6697)
    }

    @Test("a list that already has entries is left alone")
    func adoptionOnlyHappensOnce() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "caravan-adopt-\(UUID().uuidString)")
        let config = ConfigFile(url: directory.appending(path: "caravan.conf"))
        config.set("irc.libera.chat", forKey: ConnectionSettings.Key.host)
        let servers = ServerList(config: ConfigFile(url: directory.appending(path: "servers.conf")))
        servers.save(ServerEntry(name: "mine", host: "irc.example.org"))

        _ = AppModel(
            config: config,
            knownHosts: temporaryKnownHosts(),
            credentials: EphemeralCredentialStore(),
            servers: servers
        )

        #expect(servers.entries.map(\.name) == ["mine"])
    }
}
