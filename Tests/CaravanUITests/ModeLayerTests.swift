import AppKit
import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The list modes — ban, quiet, invite, except — as they arrive and as they are collected.
@MainActor
@Suite("List modes")
struct ListModeTests {
    @MainActor
    private final class Harness {
        let server: ScriptedIRCServer
        let model: AppModel

        init(server: ScriptedIRCServer, model: AppModel) {
            self.server = server
            self.model = model
        }

        var connection: ConnectionViewModel { model.activeConnection! }

        func channel(_ name: String) -> ChannelBuffer? {
            connection.buffer(named: IRCChannelName(name, mapping: .ascii))
        }

        func shutDown() async {
            await model.disconnectAll()
            await server.stop()
        }
    }

    private func harness() async throws -> Harness {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(
            nick: "alice",
            isupport: [
                "CASEMAPPING=ascii", "CHANTYPES=#", "PREFIX=(ov)@+", "MODES=3",
                "EXCEPTS", "INVEX",
            ]
        )
        let model = temporaryModel()
        let harness = Harness(server: server, model: model)
        await model.connect(
            using: ConnectionSettings(
                host: "127.0.0.1",
                port: port,
                useTLS: false,
                nick: "alice",
                realName: "Alice Example"
            )
        )
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        await server.send(":alice!u@h JOIN #swift")
        #expect(await waitUntil { harness.channel("#swift") != nil })
        return harness
    }

    /// 367's setter and timestamp are optional in practice — several servers send the mask
    /// alone, and a client that required all five would show nothing at all.
    @Test("a ban list is collected, with or without who and when")
    func banList() async throws {
        let harness = try await harness()
        let buffer = try #require(harness.channel("#swift"))

        await harness.server.send(
            ":irc.example.org 367 alice #swift *!*@evil.example carol 1728394000"
        )
        await harness.server.send(":irc.example.org 367 alice #swift bob!*@* ")
        await harness.server.send(":irc.example.org 368 alice #swift :End of channel ban list")

        // Waited on a *positive* condition. `!pendingListModes.contains("b")` is true
        // before anything has arrived at all, so waiting on it waits for nothing — the
        // same vacuous-wait shape that raced prompt 5's CTCP flood test.
        // The end marker arrives *after* the entries, so both go in the wait. Asserting
        // the second one straight after waiting only for the first passed under `--filter`
        // and failed in the full suite, which is the slower and more honest run.
        #expect(
            await waitUntil {
                buffer.listModes["b"]?.count == 2 && !buffer.pendingListModes.contains("b")
            }
        )
        let entries = try #require(buffer.listModes["b"])
        #expect(entries.map(\.mask) == ["*!*@evil.example", "bob!*@*"])
        #expect(entries[0].setBy == "carol")
        #expect(entries[0].setAt == 1_728_394_000)
        #expect(entries[1].setBy == nil)

        await harness.shutDown()
    }

    /// The server sends the whole list every time, so a merge would keep entries that had
    /// been removed since.
    @Test("asking again replaces the list rather than appending to it")
    func listIsReplaced() async throws {
        let harness = try await harness()
        let buffer = try #require(harness.channel("#swift"))

        await harness.server.send(":irc.example.org 367 alice #swift one!*@*")
        await harness.server.send(":irc.example.org 368 alice #swift :End")
        #expect(await waitUntil { buffer.listModes["b"]?.count == 1 })

        buffer.beginListMode("b")
        await harness.server.send(":irc.example.org 367 alice #swift two!*@*")
        await harness.server.send(":irc.example.org 368 alice #swift :End")
        #expect(await waitUntil { buffer.listModes["b"]?.map(\.mask) == ["two!*@*"] })

        await harness.shutDown()
    }

    /// 728 carries the mode letter in a column of its own, because quiet was invented
    /// later and by someone else.
    @Test("the quiet list arrives with its letter in an extra column")
    func quietList() async throws {
        let harness = try await harness()
        let buffer = try #require(harness.channel("#swift"))

        await harness.server.send(":irc.example.org 728 alice #swift q noisy!*@* carol 1728394000")
        await harness.server.send(":irc.example.org 729 alice #swift q :End of channel quiet list")

        #expect(
            await waitUntil {
                buffer.listModes["q"]?.count == 1 && !buffer.pendingListModes.contains("q")
            }
        )
        #expect(buffer.listModes["q"]?.first?.mask == "noisy!*@*")

        await harness.shutDown()
    }

    /// Invite and except are the same shape again, at the letters `ISUPPORT` names.
    @Test("invite and except lists land under their own letters")
    func inviteAndExcept() async throws {
        let harness = try await harness()
        let buffer = try #require(harness.channel("#swift"))

        await harness.server.send(":irc.example.org 346 alice #swift friend!*@* carol 1")
        await harness.server.send(":irc.example.org 347 alice #swift :End of invite list")
        await harness.server.send(":irc.example.org 348 alice #swift good!*@* carol 1")
        await harness.server.send(":irc.example.org 349 alice #swift :End of except list")

        #expect(await waitUntil { buffer.listModes["I"]?.count == 1 })
        #expect(await waitUntil { buffer.listModes["e"]?.count == 1 })
        #expect(buffer.listModes["I"]?.first?.mask == "friend!*@*")
        #expect(buffer.listModes["e"]?.first?.mask == "good!*@*")

        await harness.shutDown()
    }

    /// A server that sends an empty or over-long mode column must not crash the client —
    /// `Character(String)` traps unless the string is exactly one character.
    @Test("a malformed mode column falls back rather than trapping")
    func malformedModeColumn() async throws {
        let harness = try await harness()
        let buffer = try #require(harness.channel("#swift"))

        await harness.server.send(":irc.example.org 728 alice #swift  odd!*@*")
        await harness.server.send(":irc.example.org 728 alice #swift qq other!*@*")

        #expect(await waitUntil { (buffer.listModes["q"]?.count ?? 0) >= 1 })

        await harness.shutDown()
    }

    /// `EXCEPTS` and `INVEX` may arrive bare, which means "yes, at the conventional letter".
    @Test("the list-mode letters come from ISUPPORT")
    func lettersFromISUPPORT() async throws {
        let harness = try await harness()
        #expect(
            await waitUntil { harness.connection.lastKnownCapabilities.banExceptionMode == "e" }
        )
        #expect(harness.connection.lastKnownCapabilities.inviteExceptionMode == "I")

        let support = ListModeSupport(capabilities: harness.connection.lastKnownCapabilities)
        #expect(support.exceptIsSupported)
        #expect(support.inviteIsSupported)
        #expect(ListMode.ban.letter(capabilities: support.letters) == "b")
        #expect(ListMode.except.letter(capabilities: support.letters) == "e")

        await harness.shutDown()
    }

    /// Found by the live run: list entries reused the `channelMode` template and read
    /// `*** Channel modes for : +b *!*@…` — the wrong sentence, and with an empty channel
    /// because that template wants a `$channel` a list entry never filled in.
    @Test("a list entry names its list and its channel")
    func listEntryRendering() async throws {
        let harness = try await harness()
        let buffer = try #require(harness.channel("#swift"))
        let reader = buffer.log.displayView().documentView as? NSTextView

        await harness.server.send(
            ":irc.example.org 367 alice #swift *!*@evil.example carol 1728394000"
        )
        await harness.server.send(":irc.example.org 368 alice #swift :End")
        // Waited on the *text*, which is what is being asserted. Collection happens
        // before rendering inside the same handler, so waiting on `listModes` and then
        // reading the scrollback reads it one event too early — it passed under
        // `--filter` and failed in the full suite.
        func text() -> String {
            buffer.log.flush()
            return reader?.string ?? ""
        }
        #expect(await waitUntil { text().contains("End of ban list") })

        let text = text()
        #expect(text.contains("Ban list for #swift: *!*@evil.example (set by carol on "))
        #expect(text.contains("End of ban list for #swift"))
        #expect(!text.contains("Channel modes for :"))

        await harness.shutDown()
    }

    /// Found by the live run, in the modes sheet's own header: **a channel does not have a
    /// `+b`, it has a ban list.** Setting one ban recorded `b` in `modeArguments`, so the
    /// mode line read `+Cnstb badactor!*@*` and each new ban overwrote the last.
    @Test("a list mode is not tracked as a channel mode")
    func listModesAreNotChannelModes() async throws {
        let harness = try await harness()
        let buffer = try #require(harness.channel("#swift"))

        await harness.server.send(":irc.example.org 324 alice #swift +nst")
        #expect(await waitUntil { buffer.channel.modes.contains("n") })

        await harness.server.send(":alice!u@h MODE #swift +b one!*@*")
        await harness.server.send(":alice!u@h MODE #swift +b two!*@*")
        await harness.server.send(":alice!u@h MODE #swift +k hunter2")
        #expect(await waitUntil { buffer.channel.modeArguments["k"] == "hunter2" })

        #expect(!buffer.channel.modes.contains("b"))
        #expect(buffer.channel.modeArguments["b"] == nil)
        // Flag modes first, then the ones carrying an argument — and no `b` among them.
        #expect(buffer.channel.modeDescription == "+nstk hunter2")

        await harness.shutDown()
    }

    /// A server that never mentions them does not have them, which is different from
    /// having them at the default letter.
    @Test("a server without EXCEPTS and INVEX offers neither list")
    func withoutExceptsOrInvex() {
        var capabilities = ServerCapabilities()
        capabilities.apply(tokens: ["CASEMAPPING=ascii"])
        let support = ListModeSupport(capabilities: capabilities)
        #expect(!support.exceptIsSupported)
        #expect(!support.inviteIsSupported)
    }
}

/// Banning by nick, which is where the roster earns the parser/connection split.
@MainActor
@Suite("Ban masks")
struct BanMaskTests {
    private func connection() -> ConnectionViewModel {
        ConnectionViewModel(
            configuration: SessionConfiguration(
                host: "127.0.0.1",
                port: 6667,
                tls: .disabled,
                nick: "alice"
            ),
            trace: .init()
        )
    }

    /// **`bob!*@*` is defeated by `/nick bob2`**, which is not much of a ban — so the host
    /// is used when the roster knows it.
    @Test("a known nick becomes a host mask")
    func hostMask() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let model = temporaryModel()
        await model.connect(
            using: ConnectionSettings(
                host: "127.0.0.1",
                port: port,
                useTLS: false,
                nick: "alice",
                realName: "Alice Example"
            )
        )
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)

        await server.send(":alice!u@h JOIN #swift")
        await server.send(":bob!bobuser@bob.example JOIN #swift")
        let name = IRCChannelName("#swift", mapping: .ascii)
        #expect(
            await waitUntil {
                connection.buffer(named: name)?.channel.members.count == 2
            }
        )

        #expect(connection.banMask(for: "bob", in: name) == "*!*@bob.example")
        // Somebody who is not here: a weaker ban beats an error message.
        #expect(connection.banMask(for: "stranger", in: name) == "stranger!*@*")
        // Anything with mask punctuation was written as a mask and is left alone.
        #expect(connection.banMask(for: "*!*@evil.example", in: name) == "*!*@evil.example")
        #expect(connection.banMask(for: "bob!*@*", in: name) == "bob!*@*")

        await model.disconnectAll()
        await server.stop()
    }

    /// **The ban goes out before the kick.** Kicking first leaves a window, however small,
    /// in which they can rejoin — which is the whole reason `/kickban` exists as one
    /// command rather than two.
    @Test("kickban bans before it kicks")
    func kickbanOrder() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let model = temporaryModel()
        await model.connect(
            using: ConnectionSettings(
                host: "127.0.0.1",
                port: port,
                useTLS: false,
                nick: "alice",
                realName: "Alice Example"
            )
        )
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connection = try #require(model.activeConnection)
        await server.send(":alice!u@h JOIN #swift")
        #expect(
            await waitUntil {
                connection.buffer(named: IRCChannelName("#swift", mapping: .ascii)) != nil
            }
        )

        await connection.ban(
            channel: "#swift",
            subject: "bob",
            isSet: true,
            kickReason: "spam",
            from: nil
        )
        #expect(
            await waitUntil {
                await server.receivedLines().contains { $0.hasPrefix("KICK #swift bob") }
            }
        )
        let lines = await server.receivedLines()
        let banIndex = try #require(lines.firstIndex { $0.hasPrefix("MODE #swift +b") })
        let kickIndex = try #require(lines.firstIndex { $0.hasPrefix("KICK #swift bob") })
        #expect(banIndex < kickIndex)

        await model.disconnectAll()
        await server.stop()
    }
}
