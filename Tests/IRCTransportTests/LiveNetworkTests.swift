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
            tls: .enabled(allowSelfSigned: false)
        )
        #expect(await waitUntil(timeout: .seconds(20)) { await states.snapshot().contains(.ready) })
        #expect(await waitUntil(timeout: .seconds(20)) { await inbound.count() > 0 })

        await connection.disconnect()
    }

    /// The verify block runs only on the self-signed path, so this is the one test that
    /// executes it. Libera's certificate is publicly trusted, so it must come back
    /// system-trusted — an "allow self-signed" option that quietly downgrades a good
    /// certificate would be worse than not having one.
    @Test("records the peer certificate when self-signed certificates are allowed")
    func surfacesCertificate() async throws {
        let connection = IRCConnection(trace: TraceBuffer(capacity: 256))
        let states = StreamLog<TransportState>()
        states.drain(connection.state)

        await connection.connect(
            host: Self.host,
            port: Self.port,
            tls: .enabled(allowSelfSigned: true)
        )
        #expect(await waitUntil(timeout: .seconds(20)) { await states.snapshot().contains(.ready) })

        let certificate = try #require(await connection.acceptedCertificate)
        #expect(certificate.systemTrusted)
        #expect(certificate.sha256Fingerprint.count == 32 * 3 - 1)  // 32 bytes, colon-separated.

        await connection.disconnect()
    }
}
