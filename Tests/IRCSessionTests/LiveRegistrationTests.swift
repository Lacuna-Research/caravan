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
            tls: .enabled(allowSelfSigned: false),
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

        await session.disconnect()
    }
}
