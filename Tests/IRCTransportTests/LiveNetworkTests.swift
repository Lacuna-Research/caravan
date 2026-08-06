import CaravanTestSupport
import Diagnostics
import Foundation
import IRCProtocol
import Testing

@testable import IRCTransport

/// The TLS path, against a real IRC network.
///
/// Off unless `CARAVAN_LIVE_TESTS` is set, so CI and an ordinary `swift test` never
/// depend on the internet or on Libera being up. It exists because the alternative
/// coverage for `NWProtocolTLS` and the verify block is none: standing up a TLS listener
/// in-process needs a `SecIdentity`, which needs a keychain item or a hand-rolled
/// self-signed certificate, and that is a lot of machinery to test Apple's TLS stack
/// rather than our use of it.
///
///     CARAVAN_LIVE_TESTS=1 swift test --filter LiveNetworkTests
@Suite(
    "live network",
    .enabled(if: ProcessInfo.processInfo.environment["CARAVAN_LIVE_TESTS"] != nil)
)
struct LiveNetworkTests {
    private static let host = "irc.libera.chat"
    private static let port: UInt16 = 6697

    /// Libera greets a new connection with notices before we send anything, so reaching
    /// `.ready` and then parsing a line proves handshake, framing and decoding together.
    @Test("completes a TLS handshake and receives the greeting")
    func tlsHandshake() async throws {
        let connection = IRCConnection(trace: TraceBuffer(capacity: 256))
        let states = StreamLog<TransportState>()
        let inbound = StreamLog<IRCMessage>()
        states.drain(connection.state)
        inbound.drain(connection.inbound)

        await connection.connect(
            host: Self.host,
            port: Self.port,
            tls: .enabled(.system)
        )
        #expect(await waitUntil(timeout: .seconds(20)) { await states.snapshot().contains(.ready) })
        #expect(await waitUntil(timeout: .seconds(20)) { await inbound.count() > 0 })

        await connection.disconnect()
    }

    /// The verify block runs only under `trustOnFirstUse`, so this is the one test that
    /// executes it against a real handshake. Libera's certificate is publicly trusted, so
    /// it must come back system-trusted and **the evaluator must not be consulted at all**:
    /// a trust mode that asked about a perfectly good certificate would train people to
    /// click through the question that matters.
    @Test("a system-trusted certificate is recorded and nobody is asked about it")
    func surfacesCertificate() async throws {
        let asked = Asked()
        let connection = IRCConnection(
            trace: TraceBuffer(capacity: 256),
            credentials: TLSCredentials(trustEvaluator: { _, _ in
                await asked.record()
                return true
            })
        )
        let states = StreamLog<TransportState>()
        states.drain(connection.state)

        await connection.connect(
            host: Self.host,
            port: Self.port,
            tls: .enabled(.trustOnFirstUse)
        )
        #expect(await waitUntil(timeout: .seconds(20)) { await states.snapshot().contains(.ready) })

        let certificate = try #require(await connection.acceptedCertificate)
        #expect(certificate.systemTrusted)
        #expect(certificate.sha256Fingerprint.count == 32 * 3 - 1)  // 32 bytes, colon-separated.
        #expect(await asked.count == 0)

        await connection.disconnect()
    }
}

/// Trust-on-first-use against a certificate the system will *not* validate.
///
/// Needs a listener presenting a self-signed certificate, which is one `openssl` command
/// rather than a `SecIdentity` built by hand:
///
///     openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
///         -days 1 -nodes -subj "/CN=caravan-selfsigned-test"
///     openssl s_server -accept 16697 -cert cert.pem -key key.pem -quiet
///     CARAVAN_SELF_SIGNED_ENDPOINT=127.0.0.1:16697 \
///         CARAVAN_LIVE_TESTS=1 swift test --filter SelfSignedTLSTests
///
/// Worth the fixture. This is the only path that runs the asynchronous half of the verify
/// block — the one that holds the handshake open across a suspension while somebody
/// answers — and nothing else in the suite can reach it.
@Suite(
    "self-signed TLS",
    .enabled(
        if: ProcessInfo.processInfo.environment["CARAVAN_LIVE_TESTS"] != nil
            && ProcessInfo.processInfo.environment["CARAVAN_SELF_SIGNED_ENDPOINT"] != nil
    )
)
struct SelfSignedTLSTests {
    private var endpoint: (host: String, port: UInt16) {
        let raw = ProcessInfo.processInfo.environment["CARAVAN_SELF_SIGNED_ENDPOINT"] ?? ""
        let parts = raw.split(separator: ":")
        return (String(parts.first ?? "127.0.0.1"), UInt16(parts.last ?? "16697") ?? 16697)
    }

    private func connect(
        accepting: Bool?,
        record: Recorder = Recorder()
    ) async -> (IRCConnection, StreamLog<TransportState>, Recorder) {
        var evaluator: (@Sendable (TLSCertificate, String) async -> Bool)?
        if let accepting {
            evaluator = { certificate, host in
                await record.store(certificate: certificate, host: host)
                return accepting
            }
        }
        let connection = IRCConnection(
            trace: TraceBuffer(capacity: 256),
            credentials: TLSCredentials(trustEvaluator: evaluator)
        )
        let states = StreamLog<TransportState>()
        states.drain(connection.state)
        await connection.connect(
            host: endpoint.host,
            port: endpoint.port,
            tls: .enabled(.trustOnFirstUse)
        )
        return (connection, states, record)
    }

    @Test("the evaluator is asked, with the fingerprint and the host")
    func asksAndAccepts() async throws {
        let (connection, states, record) = await connect(accepting: true)
        #expect(await waitUntil(timeout: .seconds(20)) { await states.snapshot().contains(.ready) })

        let certificate = try #require(await record.certificate)
        #expect(!certificate.systemTrusted)
        #expect(certificate.sha256Fingerprint.count == 32 * 3 - 1)
        #expect(await record.host == endpoint.host)

        // The fingerprint the user is shown has to be the *server's*. Set
        // `CARAVAN_SELF_SIGNED_FINGERPRINT` to the output of
        // `openssl x509 -in cert.pem -noout -fingerprint -sha256` to pin it: a trust
        // prompt showing some other certificate's digest is worse than no prompt.
        if let expected = ProcessInfo.processInfo.environment["CARAVAN_SELF_SIGNED_FINGERPRINT"] {
            #expect(certificate.sha256Fingerprint.uppercased() == expected.uppercased())
        }
        await connection.disconnect()
    }

    @Test("refusing fails the handshake rather than connecting anyway")
    func refusing() async throws {
        let (connection, states, _) = await connect(accepting: false)
        #expect(
            await waitUntil(timeout: .seconds(20)) {
                await states.snapshot().contains { if case .failed = $0 { true } else { false } }
            }
        )
        #expect(await !states.snapshot().contains(.ready))
        await connection.disconnect()
    }

    /// **Fails closed.** The flag this replaced accepted an unvalidated certificate when
    /// there was no UI to ask; with nobody to ask, the right answer is no.
    @Test("with no evaluator the handshake fails rather than accepting silently")
    func noEvaluator() async throws {
        let (connection, states, _) = await connect(accepting: nil)
        #expect(
            await waitUntil(timeout: .seconds(20)) {
                await states.snapshot().contains { if case .failed = $0 { true } else { false } }
            }
        )
        #expect(await !states.snapshot().contains(.ready))
        await connection.disconnect()
    }
}

/// What the evaluator saw, across the concurrency boundary it is called on.
actor Recorder {
    private(set) var certificate: TLSCertificate?
    private(set) var host: String?

    func store(certificate: TLSCertificate, host: String) {
        self.certificate = certificate
        self.host = host
    }
}

/// A counter for an evaluator that ought never to run.
actor Asked {
    private(set) var count = 0

    func record() { count += 1 }
}
