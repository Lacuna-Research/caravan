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

    // MARK: - The Connect sheet

    @Test("the whole Connect sheet hosts and lays out")
    func connectSheetLaysOut() {
        let sheet = ConnectSheet(
            config: temporaryConfig(),
            credentials: EphemeralCredentialStore()
        ) { _ in }
        let hosting = hosted(sheet, width: 460, height: 620)
        #expect(hosting.fittingSize.width <= 460)
        #expect(!leafFrames(hosting).isEmpty)
    }

    /// The section grows by one or two rows as the method changes, and every row has to
    /// stay a row. A `Form` row taller than about 60pt is the shape of prompt 2's defect —
    /// a label wrapping one word per line beside a sliver of field.
    @Test(
        "the Authentication section stays row-shaped for every method",
        arguments: ConnectionSettings.AuthenticationChoice.allCases
    )
    func authenticationSectionLaysOut(choice: ConnectionSettings.AuthenticationChoice) {
        var settings = ConnectionSettings()
        settings.authentication = choice
        let binding = Binding(get: { settings }, set: { settings = $0 })
        let hosting = hosted(
            Form { AuthenticationSection(settings: binding) }.formStyle(.grouped),
            width: 460,
            height: 400
        )
        let height = hosting.fittingSize.height
        #expect(height > 40, "the section collapsed to \(height)pt")
        // Measured: a row is ~37pt, so `.none` is 104pt and `.saslExternal` — four rows
        // plus the explanatory paragraph — is 215pt. The ceiling leaves room for two more
        // rows' worth of metric drift between OS versions while still catching prompt 2's
        // defect, which turned one row into five and would land near 355pt.
        #expect(height < 300, "the section grew to \(height)pt for \(choice.label)")

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
