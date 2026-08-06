import Foundation
import Testing

@testable import IRCSession

/// The SASL mechanisms, as arithmetic rather than as a connection.
///
/// SCRAM is checked against RFC 7677's published exchange, which is the only way to know
/// the implementation is right rather than merely self-consistent: a client and a server
/// that make the same mistake agree with each other perfectly.
@Suite("SASL")
struct SASLTests {
    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: - PLAIN

    /// `authzid \0 authcid \0 passwd`, with an empty authzid: we are not asking to act as
    /// anyone but the account being authenticated.
    @Test("PLAIN is a NUL-separated triple with an empty authzid")
    func plain() throws {
        var exchange = SASLExchange(mechanism: .plain, account: "alice", password: "hunter2")
        let response = try exchange.respond(to: Data())
        #expect(Array(response) == [0] + Array("alice".utf8) + [0] + Array("hunter2".utf8))
        #expect(exchange.isFinished)
    }

    @Test("PLAIN refuses a second challenge rather than answering it again")
    func plainIsOneShot() throws {
        var exchange = SASLExchange(mechanism: .plain, account: "alice", password: "hunter2")
        _ = try exchange.respond(to: Data())
        #expect(throws: SASLError.unexpectedChallenge) {
            _ = try exchange.respond(to: Data())
        }
    }

    /// CertFP puts nothing on the wire: the TLS certificate already said who we are, so
    /// the response is the empty authorization identity.
    @Test("EXTERNAL sends an empty response")
    func external() throws {
        var exchange = SASLExchange(mechanism: .external, account: "", password: "")
        #expect(try exchange.respond(to: Data()).isEmpty)
    }

    // MARK: - SCRAM-SHA-256, against RFC 7677 §3

    private static let scramClientNonce = "rOprNGfwEbeRWgbNEkqO"
    private static let scramServerFirst =
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private static let scramClientFinal =
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
        + "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
    private static let scramServerFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    private func scram() -> SASLExchange {
        SASLExchange(
            mechanism: .scramSHA256,
            account: "user",
            password: "pencil",
            clientNonce: Self.scramClientNonce
        )
    }

    @Test("SCRAM-SHA-256 reproduces RFC 7677's published exchange")
    func scramVector() throws {
        var exchange = scram()
        #expect(text(try exchange.respond(to: Data())) == "n,,n=user,r=\(Self.scramClientNonce)")

        let final = try exchange.respond(to: Data(Self.scramServerFirst.utf8))
        #expect(text(final) == Self.scramClientFinal)
        #expect(!exchange.isFinished)

        // The last step verifies the server's signature and answers with an empty payload,
        // which becomes `AUTHENTICATE +` on the wire.
        #expect(try exchange.respond(to: Data(Self.scramServerFinal.utf8)).isEmpty)
        #expect(exchange.isFinished)
    }

    /// The half of SCRAM that is not about proving *us*. A server that cannot produce the
    /// signature does not hold the password, which is what mutual authentication buys and
    /// what a client skipping this check throws away.
    @Test("a wrong server signature is refused")
    func scramRejectsABadServerSignature() throws {
        var exchange = scram()
        _ = try exchange.respond(to: Data())
        _ = try exchange.respond(to: Data(Self.scramServerFirst.utf8))
        #expect(throws: SASLError.serverSignatureMismatch) {
            _ = try exchange.respond(
                to: Data("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".utf8)
            )
        }
    }

    /// The nonce binds the exchange to *our* challenge. A server that replaces it rather
    /// than extending it could be replaying a recorded one.
    @Test("a server that does not extend the client nonce is refused")
    func scramRequiresAnExtendedNonce() throws {
        var exchange = scram()
        _ = try exchange.respond(to: Data())
        #expect(throws: (any Error).self) {
            _ = try exchange.respond(
                to: Data("r=somethingelse,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8)
            )
        }
    }

    @Test("a malformed server-first is refused rather than guessed at")
    func scramMalformed() throws {
        var exchange = scram()
        _ = try exchange.respond(to: Data())
        #expect(throws: (any Error).self) {
            _ = try exchange.respond(to: Data("r=\(Self.scramClientNonce)x,i=4096".utf8))
        }
    }

    /// A SCRAM error is delivered as `e=...` in the final message rather than as a
    /// signature that fails to match, and reporting "the server failed to prove it knows
    /// the password" for "unknown-user" would send someone hunting the wrong bug.
    @Test("a server error in the final message is reported as itself")
    func scramServerError() throws {
        var exchange = scram()
        _ = try exchange.respond(to: Data())
        _ = try exchange.respond(to: Data(Self.scramServerFirst.utf8))
        #expect(throws: SASLError.malformedChallenge("unknown-user")) {
            _ = try exchange.respond(to: Data("e=unknown-user".utf8))
        }
    }

    @Test("SCRAM escapes a username containing its own delimiters")
    func scramEscaping() {
        #expect(SASLExchange.escapeSCRAMName("a,b=c") == "a=2Cb=3Dc")
    }

    // MARK: - The wire framing

    @Test("an empty payload is a single plus")
    func emptyPayload() {
        #expect(SASLWire.chunks(for: Data()) == ["+"])
    }

    @Test("a short payload is one chunk")
    func shortPayload() {
        #expect(
            SASLWire.chunks(for: Data("hello".utf8)) == [Data("hello".utf8).base64EncodedString()]
        )
    }

    /// The edge nobody remembers. 300 bytes encode to exactly 400 base64 characters, and a
    /// final chunk of exactly 400 is indistinguishable from "more follows" — so an empty
    /// one has to say the message ended, or the server waits forever.
    @Test("a payload encoding to an exact multiple of 400 gets a trailing plus")
    func exactMultiple() {
        let chunks = SASLWire.chunks(for: Data(repeating: 0x41, count: 300))
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 400)
        #expect(chunks[1] == "+")
    }

    @Test("a long payload is split at 400 characters")
    func longPayload() {
        let chunks = SASLWire.chunks(for: Data(repeating: 0x41, count: 500))
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 400)
        #expect(chunks[1].count > 0 && chunks[1].count < 400)
        #expect(Data(base64Encoded: chunks.joined()) == Data(repeating: 0x41, count: 500))
    }

    @Test("the accumulator waits for a short chunk before decoding")
    func accumulation() {
        let payload = Data(repeating: 0x42, count: 500)
        let chunks = SASLWire.chunks(for: payload)
        var accumulator = SASLWire.Accumulator()
        #expect(accumulator.push(chunks[0]) == .incomplete)
        #expect(accumulator.push(chunks[1]) == .complete(payload))
    }

    @Test("a lone plus is the empty challenge every mechanism starts with")
    func emptyChallenge() {
        var accumulator = SASLWire.Accumulator()
        #expect(accumulator.push("+") == .complete(Data()))
    }

    @Test("a plus after an exact multiple ends the message")
    func plusTerminator() {
        let payload = Data(repeating: 0x43, count: 300)
        var accumulator = SASLWire.Accumulator()
        #expect(accumulator.push(payload.base64EncodedString()) == .incomplete)
        #expect(accumulator.push("+") == .complete(payload))
    }

    @Test("something that is not base64 is reported rather than decoded to nothing")
    func undecodable() {
        var accumulator = SASLWire.Accumulator()
        #expect(accumulator.push("not base64 at all!") == .undecodable)
    }
}
