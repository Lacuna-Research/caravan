import Foundation
import IRCProtocol
import Testing

@testable import IRCSession

/// The outbound limit: what the user typed goes out late, never not at all.
@Suite("Pacing what we send")
struct SendPacerTests {
    private let origin = ContinuousClock().now

    @Test("the burst goes out with no delay at all")
    func burstIsFree() {
        var pacer = SendPacer(burst: 5, recovery: .seconds(2), now: origin)
        for _ in 0..<5 {
            #expect(pacer.delayForNextSend(at: origin) == nil)
        }
    }

    /// Asked once per line by a single drain, each time after having waited — which is what
    /// the drain loop does, so the test does it too rather than asserting on a caller that
    /// could not exist.
    @Test("past the burst, one line every recovery period")
    func steadyStateIsOnePerRecovery() {
        var pacer = SendPacer(burst: 5, recovery: .seconds(2), now: origin)
        var now = origin
        for _ in 0..<5 { _ = pacer.delayForNextSend(at: now) }

        for _ in 0..<3 {
            let delay = pacer.delayForNextSend(at: now)
            #expect(delay == .seconds(2))
            now += delay ?? .zero
        }
    }

    @Test("waiting refills the bucket, and it never overfills")
    func refill() {
        var pacer = SendPacer(burst: 5, recovery: .seconds(2), now: origin)
        for _ in 0..<5 { _ = pacer.delayForNextSend(at: origin) }

        // Four seconds is two tokens.
        let later = origin + .seconds(4)
        #expect(pacer.delayForNextSend(at: later) == nil)
        #expect(pacer.delayForNextSend(at: later) == nil)
        #expect(pacer.delayForNextSend(at: later) != nil, "and no third")

        // An hour idle is still only a burst's worth, not an hour's worth.
        let muchLater = later + .seconds(3600)
        for _ in 0..<5 { #expect(pacer.delayForNextSend(at: muchLater) == nil) }
        #expect(pacer.delayForNextSend(at: muchLater) != nil)
    }

    /// A queued `PONG` is a ping timeout: the limiter would cause the disconnect it exists
    /// to prevent.
    @Test("keep-alive and quitting never wait")
    func alwaysExempt() {
        for verb in ["PONG", "PING", "QUIT"] {
            let message = IRCMessage(verb: verb, parameters: ["x"])
            #expect(message.bypassesPacing(isRegistered: true))
            #expect(message.bypassesPacing(isRegistered: false))
        }
    }

    /// `NICK` is a registration line for one second and an ordinary command forever after —
    /// and a `/nick` loop is a flood like any other.
    @Test("registration lines are exempt only until registration")
    func registrationExemptionExpires() {
        for verb in ["NICK", "USER", "PASS", "CAP", "AUTHENTICATE"] {
            let message = IRCMessage(verb: verb, parameters: ["x"])
            #expect(message.bypassesPacing(isRegistered: false))
            #expect(!message.bypassesPacing(isRegistered: true), "\(verb) after 001")
        }
    }

    @Test("what the user types is never exempt")
    func ordinaryTrafficIsPaced() {
        let message = IRCMessage(verb: "PRIVMSG", parameters: ["#swift", "hello"])
        #expect(!message.bypassesPacing(isRegistered: true))
        #expect(!message.bypassesPacing(isRegistered: false))
    }
}
