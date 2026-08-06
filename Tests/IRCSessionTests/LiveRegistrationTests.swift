import CaravanTestSupport
import Diagnostics
import Foundation
import IRCTransport
import Testing

@testable import IRCSession

/// Registration against a real IRC network.
///
/// Off unless `CARAVAN_LIVE_TESTS` is set, so CI and an ordinary `swift test` never
/// depend on the internet. A scripted server proves the state machine does what the
/// script says; only a real ircd proves the script resembles an ircd.
///
///     CARAVAN_LIVE_TESTS=1 swift test --filter LiveRegistrationTests
@Suite(
    "live registration",
    .enabled(if: ProcessInfo.processInfo.environment["CARAVAN_LIVE_TESTS"] != nil)
)
struct LiveRegistrationTests {
    @Test("registers on Libera over TLS and reads its ISUPPORT")
    func registersOnLibera() async throws {
        // A nick nobody else is holding, so a collision does not make this test a
        // coin toss. Reconnect is effectively disabled: one attempt, then stop.
        let nick = "caravan\(Int.random(in: 100_000...999_999))"
        let configuration = SessionConfiguration(
            host: "irc.libera.chat",
            port: 6697,
            tls: .enabled(.system),
            nick: nick,
            realName: "Caravan test",
            connectTimeout: .seconds(30),
            backoff: BackoffPolicy(initialDelay: .seconds(3600), multiplier: 1)
        )
        let session = IRCSession(configuration: configuration, trace: TraceBuffer(capacity: 512))
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())

        await session.connect()
        #expect(
            await waitUntil(timeout: .seconds(40)) {
                await events.snapshot().contains {
                    if case .stateChanged(.connected) = $0 { true } else { false }
                }
            }
        )

        let info = try #require(await session.serverInfo)
        #expect(info.nick == nick)
        #expect(info.version?.isEmpty == false)

        // 005 arrives right after 001, so give the burst a moment to land.
        #expect(
            await waitUntil(timeout: .seconds(20)) {
                await session.capabilities.network == "Libera.Chat"
            }
        )
        let capabilities = await session.capabilities
        #expect(capabilities.caseMapping == .rfc1459)
        #expect(capabilities.nickLength >= 16)
        #expect(capabilities.prefixes.map(\.prefix).contains("@"))
        #expect(!capabilities.channelModes.lists.isEmpty)

        // Registration completing at all proves `CAP END` was sent: Libera holds 001 until
        // it arrives. What is worth asserting beyond that is *which* capabilities came
        // back — a scripted server agrees with whatever the client asks for, and only a
        // real ircd can disagree.
        let negotiated = await session.negotiated
        #expect(negotiated.isEnabled(.multiPrefix))
        #expect(negotiated.isEnabled(.serverTime))
        #expect(negotiated.isEnabled(.echoMessage))
        #expect(negotiated.isEnabled(.extendedJoin))
        #expect(negotiated.saslMechanisms.contains("PLAIN"))
        // Not asked for: nothing is authenticating.
        #expect(!negotiated.isEnabled(.sasl))

        await session.disconnect()
    }

    /// Libera really does send a multiline `CAP LS`, and it really does reject a credential
    /// for an account that does not exist. Both are things a scripted server can only be
    /// *told* to do.
    ///
    /// One attempt, with an obviously-bogus account. The point is the wire path — `CAP REQ
    /// sasl`, `AUTHENTICATE PLAIN`, the chunked credential, 904 — and the client's response
    /// to a refusal, which is to stop rather than to retry.
    @Test("a rejected SASL credential ends the attempt and is redacted")
    func saslRejectionOnLibera() async throws {
        let nick = "caravan\(Int.random(in: 100_000...999_999))"
        let password = "s3cr3t-not-real"
        let configuration = SessionConfiguration(
            host: "irc.libera.chat",
            port: 6697,
            tls: .enabled(.system),
            nick: nick,
            realName: "Caravan test",
            authentication: .sasl(mechanism: .plain, account: nick, password: password),
            connectTimeout: .seconds(30),
            backoff: BackoffPolicy(initialDelay: .seconds(3600), multiplier: 1)
        )
        let trace = TraceBuffer(capacity: 512)
        let session = IRCSession(configuration: configuration, trace: trace)
        let events = StreamLog<IRCEvent>()
        events.drain(session.events())

        await session.connect()
        #expect(
            await waitUntil(timeout: .seconds(40)) {
                await events.snapshot().contains {
                    if case .stateChanged(.disconnected(.authenticationFailed)) = $0 {
                        true
                    } else {
                        false
                    }
                }
            }
        )
        // Never registered: the attempt stopped at authentication rather than carrying on
        // unauthenticated.
        #expect(
            await !events.snapshot().contains {
                if case .stateChanged(.connected) = $0 { true } else { false }
            }
        )

        let traced = trace.snapshot().map(\.line)
        #expect(traced.contains("AUTHENTICATE PLAIN"))
        #expect(!traced.joined().contains(password))
        await session.disconnect()
    }
}
