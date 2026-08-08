import AppKit
import IRCTransport
import SwiftUI
import Testing

@testable import CaravanUI

/// The two sheets this prompt added, laid out offscreen.
///
/// **Not a substitute for looking at them**, and not pretending to be: this cannot tell
/// whether a label reads well or a colour is right. What it can tell is whether a row
/// collapses or explodes, which is the failure mode prompt 2 shipped — a `TextField` inside
/// a `LabeledContent` drew its own placeholder as a second label, wrapped one word per line,
/// and produced a five-line-tall row with a sliver of field beside it. Every test passed.
///
/// So these measure. A form row that is taller than a few lines of text, or narrower than
/// the frame it was given, is the shape of that bug.
@MainActor
@Suite("Sheet layout")
struct SheetLayoutTests {
    /// Lays a view out at the size the app presents it and returns the hosting view.
    private func hosted(_ view: some View, width: CGFloat, height: CGFloat) -> NSHostingView<
        AnyView
    > {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    /// Every leaf view's frame, which is what "did a row collapse" is a question about.
    private func leafFrames(_ view: NSView) -> [NSRect] {
        guard !view.subviews.isEmpty else { return [view.frame] }
        return view.subviews.flatMap(leafFrames)
    }

    // MARK: - The server editor

    /// The Connect sheet these two tests were written for is gone (prompt 11). The surface
    /// that inherited its job is the Dashboard's server editor — and so is the defect worth
    /// guarding, because it is the same kind of `Form`: prompt 2 found a row whose label
    /// wrapped one word per line beside a sliver of field, and nothing short of hosting the
    /// thing catches that.
    @Test("the whole server editor hosts and lays out")
    func serverEditorLaysOut() {
        let model = temporaryModel()
        let entry = ServerEntry(name: "libera", host: "irc.libera.chat")
        model.servers.save(entry)
        let hosting = hosted(ServerEditor(model: model, entry: entry), width: 460, height: 700)

        // **No width assertion, unlike the sheet this replaced.** That sheet declared
        // `.frame(width: 460)`, so its fitting width was a promise; the editor lives in a
        // resizable split pane and its fitting width is a *preference* — 744pt here, which
        // means "I would like to be wider", not "I overflow". Asserting on it would test
        // the paragraph lengths rather than the layout.
        #expect(!leafFrames(hosting).isEmpty)
        // Every row drawn inside the width it was given is the thing that matters.
        let overflowing = leafFrames(hosting).filter { $0.maxX > 470 }
        #expect(overflowing.isEmpty, "\(overflowing.count) leaves drew past the pane")
    }

    /// The Authentication section grows by one or two rows as the method changes, and every
    /// row has to stay a row.
    @Test(
        "the editor stays row-shaped for every authentication method",
        arguments: ConnectionSettings.AuthenticationChoice.allCases
    )
    func authenticationSectionLaysOut(choice: ConnectionSettings.AuthenticationChoice) {
        let model = temporaryModel()
        var entry = ServerEntry(name: "libera", host: "irc.libera.chat")
        entry.authentication = choice
        model.servers.save(entry)
        let hosting = hosted(ServerEditor(model: model, entry: entry), width: 460, height: 900)
        let height = hosting.fittingSize.height
        #expect(height > 40, "the editor collapsed to \(height)pt")
        // The whole editor rather than one section now, so the ceiling is higher than the
        // 300pt the section alone was held to. It is still a ceiling, and prompt 2's defect
        // turned one row into five — which no amount of metric drift resembles.
        #expect(height < 1400, "the editor grew to \(height)pt for \(choice.label)")

        // The picker's labels have to be distinct and non-empty, or the menu shows blanks.
        #expect(!choice.label.isEmpty)
        #expect(
            Set(ConnectionSettings.AuthenticationChoice.allCases.map(\.label)).count
                == ConnectionSettings.AuthenticationChoice.allCases.count
        )
    }

    /// The fields shown must be the ones the method uses, and no others. A password field
    /// beside `EXTERNAL` would be a lie about what is being sent.
    @Test("each method asks for exactly what it needs")
    func fieldsMatchTheMethod() {
        #expect(!ConnectionSettings.AuthenticationChoice.none.needsAccount)
        #expect(!ConnectionSettings.AuthenticationChoice.none.needsPassword)
        #expect(ConnectionSettings.AuthenticationChoice.saslExternal.needsAccount)
        #expect(!ConnectionSettings.AuthenticationChoice.saslExternal.needsPassword)
        for choice in [
            ConnectionSettings.AuthenticationChoice.saslPlain, .saslScram, .nickServ,
        ] {
            #expect(choice.needsAccount)
            #expect(choice.needsPassword)
        }
    }

    // MARK: - The trust sheet

    /// A SHA-256 fingerprint is 95 characters. The whole reason this is a sheet rather than
    /// an alert is that it has to be readable and selectable, so a layout that clipped it
    /// would defeat the point of asking at all.
    @Test("the trust sheet lays out both of its cases without clipping the fingerprint")
    func trustSheetLaysOut() {
        let fingerprint = (0..<32).map { String(format: "%02x", $0) }.joined(separator: ":")
        for previous in [nil, "aa:bb:cc"] {
            let request = AppModel.TrustRequest(
                certificate: TLSCertificate(
                    subject: "irc.example.org",
                    sha256Fingerprint: fingerprint,
                    systemTrusted: false
                ),
                host: "irc.example.org",
                previousFingerprint: previous,
                respond: { _ in }
            )
            let hosting = hosted(TrustSheet(request: request), width: 520, height: 400)
            let size = hosting.fittingSize
            #expect(size.width <= 520)
            // Tall enough to hold the explanation and the fingerprint, and not so tall that
            // something wrapped one word per line.
            #expect(size.height > 120, "the sheet collapsed to \(size.height)pt")
            #expect(size.height < 520, "the sheet grew to \(size.height)pt; something wrapped")
        }
    }

    /// Answering is the only way out — there is no close button and dismissal is disabled,
    /// because the TLS handshake is genuinely paused behind it.
    @Test("answering the request resolves it exactly once")
    func answering() {
        var answers: [Bool] = []
        let request = AppModel.TrustRequest(
            certificate: TLSCertificate(
                subject: nil,
                sha256Fingerprint: "aa:bb",
                systemTrusted: false
            ),
            host: "irc.example.org",
            previousFingerprint: nil,
            respond: { answers.append($0) }
        )
        request.answer(false)
        #expect(answers == [false])
    }
}
