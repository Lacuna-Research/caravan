import AppKit
import CaravanTestSupport
import Diagnostics
import Foundation
import IRCSession
import Testing

@testable import CaravanUI

/// The Debug & Settings canvas: where the trace goes, and what a canvas is not.
@MainActor
@Suite("Debug canvas")
struct DebugCanvasTests {
    /// A controller and the trace feeding it, with a text view attached so the canvas's
    /// contents can be read as a string.
    private struct Harness {
        let trace: TraceBuffer
        let settings: ChatSettings
        let debug: DebugController
        let reader: NSTextView

        @MainActor
        init() {
            let trace = TraceBuffer(capacity: 64)
            let settings = ChatSettings(config: temporaryConfig())
            let debug = DebugController(trace: trace, settings: settings)
            self.trace = trace
            self.settings = settings
            self.debug = debug
            self.reader = debug.log.displayView().documentView as! NSTextView
        }

        @MainActor
        var canvasText: String {
            debug.log.flush()
            return reader.string
        }

        /// Waits for the pump, which is a task consuming an `AsyncStream` — the canvas
        /// cannot be asserted on synchronously after a `record`.
        @MainActor
        func waitForCanvas(toContain text: String) async -> Bool {
            await waitUntil { canvasText.contains(text) }
        }
    }

    // MARK: - Streaming

    /// A debug surface that shows nothing until you type a command looks broken, and
    /// looking at it is the reason to open it.
    @Test("the canvas streams by default, both directions")
    func streamsByDefault() async {
        let harness = Harness()
        #expect(harness.debug.isStreamingToCanvas)

        harness.trace.record(.outbound, line: "NICK alice")
        harness.trace.record(.inbound, line: ":server 001 alice :hi")

        #expect(await harness.waitForCanvas(toContain: ">> NICK alice"))
        #expect(await harness.waitForCanvas(toContain: "<< :server 001 alice :hi"))
    }

    @Test("/debug off stops the canvas")
    func offStopsTheCanvas() async {
        let harness = Harness()
        harness.trace.record(.outbound, line: "before off")
        #expect(await harness.waitForCanvas(toContain: "before off"))

        _ = harness.debug.apply(.off)
        harness.trace.record(.outbound, line: "after off")
        // Give the pump every chance to be wrong.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!harness.canvasText.contains("after off"))
        #expect(!harness.debug.isStreamingToCanvas)
    }

    /// The case `-i` exists for: debugging is switched on *after* something has gone
    /// wrong, and the ring still holds it.
    @Test("-i brings back what happened before debugging was on")
    func includesExistingTrace() async {
        let harness = Harness()
        _ = harness.debug.apply(.off)
        harness.trace.record(.inbound, line: ":server NOTICE :something went wrong")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!harness.canvasText.contains("something went wrong"))

        _ = harness.debug.apply(.toCanvas(includingExistingTrace: true))
        #expect(await harness.waitForCanvas(toContain: "something went wrong"))
    }

    /// `-i` fills the gap and nothing else: a line the canvas already has is not a line it
    /// is missing, however many times the ring is asked for.
    @Test("-i does not duplicate what is already on the canvas")
    func replayDoesNotDuplicate() async {
        let harness = Harness()
        harness.trace.record(.inbound, line: "PING :once")
        #expect(await harness.waitForCanvas(toContain: "PING :once"))

        _ = harness.debug.apply(.toCanvas(includingExistingTrace: true))
        _ = harness.debug.apply(.toCanvas(includingExistingTrace: true))
        harness.trace.record(.inbound, line: "PING :twice")
        #expect(await harness.waitForCanvas(toContain: "PING :twice"))

        let occurrences = harness.canvasText.components(separatedBy: "PING :once").count - 1
        #expect(occurrences == 1, "the canvas already had it; -i must not add it again")
    }

    @Test("clearing the canvas leaves the ring alone")
    func clearingKeepsTheRing() async {
        let harness = Harness()
        harness.trace.record(.inbound, line: "PING :kept")
        #expect(await harness.waitForCanvas(toContain: "PING :kept"))

        harness.debug.clearCanvas()
        #expect(!harness.canvasText.contains("PING :kept"))

        _ = harness.debug.apply(.toCanvas(includingExistingTrace: true))
        #expect(await harness.waitForCanvas(toContain: "PING :kept"))
    }

    // MARK: - Redaction

    /// The property the whole debug surface rests on: redaction happens on insert, so
    /// there is no path — canvas, file or clipboard — that carries the plaintext.
    @Test("a password never reaches the canvas")
    func canvasIsRedacted() async {
        let harness = Harness()
        harness.trace.record(.outbound, line: "PASS hunter2")
        #expect(await harness.waitForCanvas(toContain: "PASS"))
        #expect(!harness.canvasText.contains("hunter2"))
    }

    // MARK: - The file destination

    @Test("/debug <file> writes the trace, redacted, with a banner saying so")
    func writesToFile() async throws {
        let harness = Harness()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "caravan-debug-\(UUID().uuidString).log")

        let answer = harness.debug.apply(.toFile(path: url.path, includingExistingTrace: false))
        #expect(answer.contains(url.path))
        #expect(harness.debug.fileURL == url)

        harness.trace.record(.outbound, line: "PRIVMSG NickServ :identify hunter2")
        #expect(
            await waitUntil {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return text.contains("PRIVMSG NickServ")
            }
        )

        harness.debug.closeFile()
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("redacted"), "the file must say what it is")
        #expect(!written.contains("hunter2"))
        #expect(written.contains(">> "))
        #expect(harness.debug.fileURL == nil)
        try? FileManager.default.removeItem(at: url)
    }

    /// A path that cannot be opened is answered, not swallowed — the same rule every
    /// other command follows.
    @Test("an unwritable path is answered rather than ignored")
    func unwritableFile() {
        let harness = Harness()
        let answer = harness.debug.apply(
            .toFile(path: "/no-such-root-directory/caravan.log", includingExistingTrace: false)
        )
        #expect(answer.lowercased().contains("cannot write"))
        #expect(harness.debug.fileURL == nil)
    }

    @Test("bare /debug says where output is going")
    func report() {
        let harness = Harness()
        #expect(harness.debug.apply(.report).contains("canvas"))
        _ = harness.debug.apply(.off)
        #expect(harness.debug.apply(.report).contains("off"))
    }

    // MARK: - A canvas is not a buffer

    /// §10's distinction, as behaviour: the canvas replaces the chat area, is not a
    /// channel, and selecting a buffer brings the chat area back.
    @Test("the canvas takes over the detail area, and a buffer takes it back")
    func canvasNavigation() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let model = temporaryModel()
        await model.connect(
            using: ConnectionSettings(host: "127.0.0.1", port: port, useTLS: false, nick: "alice")
        )
        #expect(await waitUntil { model.activeConnection?.isConnected == true })
        let connectionID = model.activeConnection!.id

        model.showSettingsAndDebug()
        #expect(model.isShowingCanvas)
        // Not a buffer: no channel, and nothing for ⌘W to close.
        #expect(model.selectedChannel == nil)

        model.selection = .status(connectionID)
        #expect(!model.isShowingCanvas)

        await model.disconnect()
        await server.stop()
    }

    /// Leaving a buffer for the canvas is still leaving it, so the unread rule is drawn
    /// where it was left — the canvas taking no part in buffer navigation does not mean
    /// buffers stop noticing that you left.
    @Test("leaving a buffer for the canvas still draws the unread rule")
    func unreadRuleOnLeavingForCanvas() async throws {
        let server = try ScriptedIRCServer()
        let port = try await server.start()
        await server.scriptWelcome(nick: "alice")
        let model = temporaryModel()
        await model.connect(
            using: ConnectionSettings(host: "127.0.0.1", port: port, useTLS: false, nick: "alice")
        )
        #expect(await waitUntil { model.activeConnection?.isConnected == true })

        let log = model.activeConnection!.log
        _ = log.displayView()
        #expect(await waitUntil { log.lineCount > 0 })
        #expect(!log.hasUnreadMarker)

        model.showSettingsAndDebug()
        #expect(log.hasUnreadMarker)

        await model.disconnect()
        await server.stop()
    }
}
