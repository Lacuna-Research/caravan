import CaravanTestSupport
import Foundation
import IRCTransport
import Testing

@testable import CaravanUI

/// Trust-on-first-use, and the file that remembers the decisions.
///
/// The TLS handshake itself is not driven here — a scripted server with a self-signed
/// certificate is a live test, and this is the *decision*, which is the part with rules in
/// it. `AppModel.decideTrust` is the seam the transport calls into, so that is what is
/// exercised.
@MainActor
@Suite("TLS trust")
struct TrustTests {
    private func certificate(_ fingerprint: String) -> TLSCertificate {
        TLSCertificate(
            subject: "irc.example.org",
            sha256Fingerprint: fingerprint,
            systemTrusted: false
        )
    }

    // MARK: - The store

    @Test("a remembered fingerprint round-trips through the file")
    func roundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "caravan-tests-\(UUID().uuidString)/known_hosts")
        let hosts = KnownHosts(url: url)
        hosts.remember("aa:bb", for: "irc.Example.ORG")

        // Read back by a second instance: this is a file, and the point of it is that it
        // survives the process.
        #expect(KnownHosts(url: url).fingerprint(for: "irc.example.org") == "aa:bb")
    }

    /// **The path and the format are public API**, like `caravan.conf`. Deleting a line
    /// has to be how you forget a decision, which means it has to be a file a person can
    /// read.
    @Test("the file is plain text a person can edit")
    func plainText() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "caravan-tests-\(UUID().uuidString)/known_hosts")
        let hosts = KnownHosts(url: url)
        hosts.remember("aa:bb", for: "irc.example.org")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("irc.example.org aa:bb"))
        #expect(written.hasPrefix("#"))
    }

    @Test("comments and blank lines are ignored on the way in")
    func handEdited() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "caravan-tests-\(UUID().uuidString)/known_hosts")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("# a note\n\nirc.example.org  aa:bb\nmalformed\n".utf8).write(to: url)
        let hosts = KnownHosts(url: url)
        #expect(hosts.fingerprint(for: "irc.example.org") == "aa:bb")
        #expect(hosts.fingerprint(for: "malformed") == nil)
    }

    @Test("forgetting a host means being asked about it again")
    func forgetting() {
        let hosts = temporaryKnownHosts()
        hosts.remember("aa:bb", for: "irc.example.org")
        hosts.forget("irc.example.org")
        #expect(hosts.fingerprint(for: "irc.example.org") == nil)
    }

    // MARK: - The decision

    /// The whole of "on first use": the second visit is not a question.
    @Test("a fingerprint we already accepted is accepted without asking")
    func rememberedIsSilent() async {
        let model = temporaryModel()
        model.knownHosts.remember("aa:bb", for: "irc.example.org")
        #expect(await model.decideTrust(certificate("aa:bb"), host: "irc.example.org"))
        #expect(model.pendingTrust == nil)
    }

    @Test("an unknown certificate is asked about, and accepting remembers it")
    func firstUseAsks() async {
        let model = temporaryModel()
        let answering = Task { @MainActor in
            _ = await waitUntil { model.pendingTrust != nil }
            model.pendingTrust?.answer(true)
        }
        let accepted = await model.decideTrust(certificate("aa:bb"), host: "irc.example.org")
        await answering.value

        #expect(accepted)
        #expect(model.knownHosts.fingerprint(for: "irc.example.org") == "aa:bb")
        #expect(model.pendingTrust == nil)
    }

    /// Refusing must not be remembered as anything: the next attempt asks again, rather
    /// than the client having quietly learned to distrust a host it never wrote down.
    @Test("refusing is not remembered")
    func refusingIsNotRemembered() async {
        let model = temporaryModel()
        let answering = Task { @MainActor in
            _ = await waitUntil { model.pendingTrust != nil }
            model.pendingTrust?.answer(false)
        }
        let accepted = await model.decideTrust(certificate("aa:bb"), host: "irc.example.org")
        await answering.value

        #expect(!accepted)
        #expect(model.knownHosts.fingerprint(for: "irc.example.org") == nil)
    }

    /// The dangerous case, and it has to read differently from a first visit: a changed
    /// certificate is either a rotation or an interception, and the user is the only one
    /// who can tell which.
    @Test("a changed fingerprint is asked about, carrying the previous one")
    func changedCertificate() async {
        let model = temporaryModel()
        model.knownHosts.remember("aa:bb", for: "irc.example.org")

        let answering = Task { @MainActor in
            _ = await waitUntil { model.pendingTrust != nil }
            #expect(model.pendingTrust?.previousFingerprint == "aa:bb")
            model.pendingTrust?.answer(true)
        }
        let accepted = await model.decideTrust(certificate("cc:dd"), host: "irc.example.org")
        await answering.value

        #expect(accepted)
        // Accepting a rotation replaces the entry rather than accumulating two, so the
        // *next* change is a question again.
        #expect(model.knownHosts.fingerprint(for: "irc.example.org") == "cc:dd")
    }

    @Test("a decision for one host says nothing about another")
    func perHost() async {
        let model = temporaryModel()
        model.knownHosts.remember("aa:bb", for: "irc.example.org")
        #expect(model.knownHosts.fingerprint(for: "irc.elsewhere.org") == nil)
    }

    // MARK: - The default

    /// The `allowSelfSigned` flag this replaced accepted an unvalidated certificate
    /// silently. The default is now to *ask*, which is strictly more permissive than
    /// refusing and strictly less permissive than what it replaced.
    @Test("TLS defaults to trust-on-first-use")
    func defaultMode() {
        let settings = ConnectionSettings(host: "irc.example.org", useTLS: true, nick: "alice")
        #expect(settings.sessionConfiguration.tls == .enabled(.trustOnFirstUse))

        var plaintext = settings
        plaintext.useTLS = false
        #expect(plaintext.sessionConfiguration.tls == .disabled)
    }
}
