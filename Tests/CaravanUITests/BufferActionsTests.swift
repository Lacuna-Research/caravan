import AppKit
import CaravanTestSupport
import Foundation
import IRCProtocol
import IRCSession
import Testing

@testable import CaravanUI

/// The context menus, as a table.
///
/// Tested as data rather than by putting a window on screen: ``BufferMenu`` is pure for
/// exactly this reason, and what stage 3's script-driven menus will replace is this table
/// and nothing else.
@MainActor
@Suite("Context menus")
struct BufferMenuTests {
    private let channel = IRCChannelName("#swift", mapping: .rfc1459)

    private func titles(_ groups: [[BufferMenuItem]]) -> [String] {
        groups.flatMap { $0 }.map(\.title)
    }

    private func item(_ title: String, in groups: [[BufferMenuItem]]) -> BufferMenuItem? {
        groups.flatMap { $0 }.first { $0.title == title }
    }

    @Test("every item on a nick is a command naming that nick")
    func nickItemsAreCommands() {
        let groups = BufferMenu.items(for: .nick("bob"), channel: channel, canSetModes: true)
        let actions = groups.flatMap { $0 }.map(\.action)
        #expect(!actions.isEmpty)
        for action in actions {
            guard case .command(let text) = action else {
                Issue.record("a nick's menu should be commands and nothing else: \(action)")
                continue
            }
            #expect(text.hasPrefix("/"))
            #expect(text.contains("bob"))
        }
    }

    /// The specific strings matter: they are the client's public behaviour, and a typo
    /// here is a menu item that produces a red "unknown command" line.
    @Test("the commands are the ones the parser knows")
    func commandsMatchTheTable() {
        let groups = BufferMenu.items(for: .nick("bob"), channel: channel, canSetModes: true)
        #expect(item("Whois", in: groups)?.action == .command("/whois bob"))
        #expect(item("Query", in: groups)?.action == .command("/query bob"))
        #expect(item("Op", in: groups)?.action == .command("/op bob"))
        #expect(item("Deop", in: groups)?.action == .command("/deop bob"))
        #expect(item("Voice", in: groups)?.action == .command("/voice bob"))
        #expect(item("Devoice", in: groups)?.action == .command("/devoice bob"))
        #expect(item("Kick", in: groups)?.action == .command("/kick bob"))
        #expect(item("Ban", in: groups)?.action == .command("/ban bob"))
        #expect(item("Kick and Ban", in: groups)?.action == .command("/kickban bob"))
        #expect(
            item("Slap", in: groups)?.action
                == .command("/me slaps bob around a bit with a large trout")
        )
    }

    /// `/op` in a conversation has no channel to name, and an item that could only ever
    /// produce "no target in this window" is not an item.
    @Test("a conversation offers no membership items")
    func queryHasNoMembershipItems() {
        let groups = BufferMenu.items(for: .nick("bob"), channel: nil, canSetModes: true)
        #expect(titles(groups) == ["Whois", "Query", "Slap"])
    }

    @Test("operator items are disabled rather than hidden when we hold no prefix")
    func operatorItemsAreDisabled() {
        let without = BufferMenu.items(for: .nick("bob"), channel: channel, canSetModes: false)
        let with = BufferMenu.items(for: .nick("bob"), channel: channel, canSetModes: true)

        // Same items either way. A menu whose contents come and go teaches nobody what
        // the client can do.
        #expect(titles(without) == titles(with))

        let operatorItems = ["Op", "Deop", "Voice", "Devoice", "Kick", "Ban", "Kick and Ban"]
        for title in operatorItems {
            #expect(item(title, in: without)?.isEnabled == false, "\(title) should be disabled")
            #expect(item(title, in: with)?.isEnabled == true, "\(title) should be enabled")
        }
        // Whois, Query and Slap need nothing from the server's permission model.
        for title in ["Whois", "Query", "Slap"] {
            #expect(item(title, in: without)?.isEnabled == true)
        }
    }

    @Test("a link offers the exact URL, unmangled")
    func linkItems() throws {
        let url = try #require(URL(string: "https://example.com/a%20b?q=1&r=2#frag"))
        let groups = BufferMenu.items(for: .link(url))
        #expect(item("Open Link", in: groups)?.action == .open(url))
        #expect(item("Copy Link", in: groups)?.action == .copy(url.absoluteString))
        #expect(item("URL Catcher…", in: groups)?.action == .showURLCatcher)
    }

    @Test("the buffer's own menu offers channel modes only where there is a channel")
    func bufferItems() {
        #expect(
            titles(BufferMenu.items(for: .buffer, channel: channel))
                == ["Channel Modes…", "URL Catcher…"]
        )
        #expect(titles(BufferMenu.items(for: .buffer, channel: nil)) == ["URL Catcher…"])
    }

    /// A group boundary is a separator, and an empty table must produce no menu at all —
    /// `menu(for:)` returning an empty `NSMenu` draws an empty grey rectangle.
    @Test("the AppKit menu draws a separator per group boundary")
    func appKitMenuShape() throws {
        let groups = BufferMenu.items(for: .nick("bob"), channel: channel, canSetModes: false)
        let menu = try #require(NSMenu.buffer(groups) { _ in })
        #expect(menu.items.filter(\.isSeparatorItem).count == groups.count - 1)
        #expect(menu.item(withTitle: "Op")?.isEnabled == false)
        #expect(menu.item(withTitle: "Whois")?.isEnabled == true)
        #expect(NSMenu.buffer([]) { _ in } == nil)
    }

    @Test("choosing an item runs its action")
    func appKitMenuPerformsTheAction() throws {
        var chosen: [BufferAction] = []
        let menu = try #require(
            NSMenu.buffer(BufferMenu.items(for: .nick("bob"))) { chosen.append($0) }
        )
        let whois = try #require(menu.item(withTitle: "Whois"))
        // The handler has to survive the builder returning: `NSMenuItem.target` is weak,
        // and this is the assertion that catches it being the only reference.
        let target = try #require(whois.target)
        let action = try #require(whois.action)
        // `perform` hands back an `Unmanaged<AnyObject>?` nobody wants, and CI builds
        // warnings as errors.
        _ = target.perform(action, with: whois)
        #expect(chosen == [.command("/whois bob")])
    }
}

/// The scrollback's hit test, over the attributes the renderer left behind.
///
/// The geometry half — which character a point is over — needs a laid-out window, and the
/// live acceptance run is what covers it. This is the half that decides what a character
/// *means*, and it is the half that can stop working silently: a custom attribute that
/// fails to cross into the text storage leaves no trace at all, which is exactly how
/// prompt 1's inline traits were lost for an afternoon.
@MainActor
@Suite("Scrollback hit test")
struct ScrollbackHitTestTests {
    /// A controller with one line in it, and the storage that line landed in.
    private func storage(_ line: AttributedString) throws -> NSTextStorage {
        let controller = MessageLogController(coalesceInterval: .zero)
        let scrollView = controller.displayView()
        controller.append([line])
        controller.flush()
        let textView = try #require(scrollView.documentView as? NSTextView)
        return try #require(textView.textStorage)
    }

    private func index(of substring: String, in storage: NSTextStorage) throws -> Int {
        let text = storage.string
        let range = try #require(text.range(of: substring))
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    @Test("a nick column answers with the nick")
    func findsTheNick() throws {
        var fields = LineFields()
        fields.nick = "bob"
        fields.text = "hello"
        let line = LineRenderer().line(kind: .message, fields: fields, now: Date())
        let storage = try storage(line)

        #expect(
            ScrollbackTextView.target(in: storage, at: try index(of: "bob", in: storage))
                == .nick("bob")
        )
        // The message text is not the nick, and neither is the timestamp.
        #expect(
            ScrollbackTextView.target(in: storage, at: try index(of: "hello", in: storage))
                == .buffer
        )
        #expect(ScrollbackTextView.target(in: storage, at: 1) == .buffer)
    }

    @Test("a URL answers with the URL the renderer detected")
    func findsTheLink() throws {
        var fields = LineFields()
        fields.nick = "bob"
        fields.text = "see https://example.com/thing"
        let line = LineRenderer().line(kind: .message, fields: fields, now: Date())
        let storage = try storage(line)

        #expect(
            ScrollbackTextView.target(in: storage, at: try index(of: "example.com", in: storage))
                == .link(URL(string: "https://example.com/thing")!)
        )
    }

    /// Past the end of the text, and before the start of it. The first is reachable by
    /// right-clicking the empty space below the last line of a short buffer.
    @Test("an index outside the text answers with the buffer")
    func outOfRange() throws {
        let storage = try storage(LineRenderer().line("hi", kind: .status, now: Date()))
        #expect(ScrollbackTextView.target(in: storage, at: storage.length) == .buffer)
        #expect(ScrollbackTextView.target(in: storage, at: -1) == .buffer)
        #expect(ScrollbackTextView.target(in: nil, at: 0) == .buffer)
    }
}
