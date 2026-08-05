import Testing

@testable import Diagnostics

// Every credential in this file is deliberately fake and recognisably so — `hunter2`
// and `s3cr3t-not-real`. Nothing here should ever resemble a real token: the repo is
// public and CI runs a secret scanner over it.

/// Lines that carry a credential. The credential must not survive; everything else must.
@Suite("Redactor removes credentials")
struct RedactorRedactsTests {
    @Test(
        "credential-bearing lines are redacted",
        arguments: [
            // Server password.
            ("PASS hunter2", "PASS <redacted>"),
            ("PASS :hunter2", "PASS :<redacted>"),
            // Commands are case-insensitive on the wire.
            ("pass hunter2", "pass <redacted>"),

            // SASL payload. The mechanism name is not a secret; the payload is.
            ("AUTHENTICATE aGVsbG8gd29ybGQ=", "AUTHENTICATE <redacted>"),
            ("AUTHENTICATE dGVzdAB0ZXN0AGh1bnRlcjI=", "AUTHENTICATE <redacted>"),

            // Oper name is useful for debugging and is kept.
            ("OPER alice hunter2", "OPER alice <redacted>"),

            // NickServ via PRIVMSG, the form actually sent on the wire.
            ("PRIVMSG NickServ :IDENTIFY hunter2", "PRIVMSG NickServ :IDENTIFY <redacted>"),
            ("PRIVMSG NickServ :identify alice hunter2", "PRIVMSG NickServ :identify <redacted>"),
            ("PRIVMSG nickserv :GHOST alice hunter2", "PRIVMSG nickserv :GHOST <redacted>"),
            ("PRIVMSG NickServ :REGAIN alice hunter2", "PRIVMSG NickServ :REGAIN <redacted>"),
            ("NOTICE NS :RELEASE alice hunter2", "NOTICE NS :RELEASE <redacted>"),
            // SETPASS carries a key as well as the new password; both go.
            (
                "PRIVMSG NickServ :SETPASS alice key s3cr3t-not-real",
                "PRIVMSG NickServ :SETPASS <redacted>"
            ),

            // Server-side alias form.
            ("NS IDENTIFY hunter2", "NS IDENTIFY <redacted>"),
            ("ns identify alice hunter2", "ns identify <redacted>"),

            // Tags and source prefix are preserved byte for byte.
            (
                "@time=2026-08-04T12:00:00.000Z :me!u@h PRIVMSG NickServ :IDENTIFY hunter2",
                "@time=2026-08-04T12:00:00.000Z :me!u@h PRIVMSG NickServ :IDENTIFY <redacted>"
            ),
            ("@label=1 PASS hunter2", "@label=1 PASS <redacted>"),
        ] as [(String, String)]
    )
    func redactsCredentials(line: String, expected: String) {
        #expect(Redactor.redact(line) == expected)
    }

    @Test("no credential survives redaction")
    func noCredentialSurvives() {
        let lines = [
            "PASS hunter2",
            "OPER alice hunter2",
            "PRIVMSG NickServ :IDENTIFY hunter2",
            "NS IDENTIFY hunter2",
            "PRIVMSG NickServ :SETPASS alice key s3cr3t-not-real",
        ]
        for line in lines {
            let redacted = Redactor.redact(line)
            #expect(!redacted.contains("hunter2"), "leaked in: \(redacted)")
            #expect(!redacted.contains("s3cr3t-not-real"), "leaked in: \(redacted)")
        }
    }
}

/// The other half, and the half that is easy to get wrong. Over-redaction destroys the
/// debuggability the trace buffer exists for, so these must pass through untouched.
@Suite("Redactor leaves ordinary traffic alone")
struct RedactorPreservesTests {
    @Test(
        "ordinary lines are untouched",
        arguments: [
            // The word "identify" in ordinary conversation.
            ":alice!a@h PRIVMSG #dev :please identify yourself before joining",
            ":alice!a@h PRIVMSG #dev :I can't identify the problem",
            // A user whose nick is "pass" — a naive scan would see a PASS command.
            ":pass!pass@example.invalid PRIVMSG #dev :hello everyone",
            ":pass!pass@example.invalid JOIN #dev",
            // A channel named #pass.
            "PRIVMSG #pass :hi",
            // Merely talking about a password.
            ":bob!b@h PRIVMSG #dev :my password is in the vault, not in this message",
            // Inbound from the service: a reply, not a credential.
            ":NickServ!services@example.invalid NOTICE alice :Password accepted for alice",
            // Mechanism names and SASL control tokens are not secrets.
            "AUTHENTICATE PLAIN",
            "AUTHENTICATE EXTERNAL",
            "AUTHENTICATE SCRAM-SHA-256",
            "AUTHENTICATE +",
            "AUTHENTICATE *",
            // A NickServ subcommand that carries no secret.
            "PRIVMSG NickServ :HELP IDENTIFY",
            "PRIVMSG NickServ :INFO alice",
            // Keyword present but no arguments to redact.
            "PRIVMSG NickServ :IDENTIFY",
            // Ordinary protocol traffic.
            ":server.example 001 alice :Welcome to the network",
            "PING :12345",
            "JOIN #dev",
            ":alice!a@h QUIT :Leaving",
        ]
    )
    func preservesOrdinaryTraffic(line: String) {
        #expect(Redactor.redact(line) == line)
    }

    @Test(
        "degenerate input does not crash and is returned unchanged",
        arguments: ["", " ", ":", "@", "@tags-only", ":prefix-only", "PASS", "OPER alice"]
    )
    func handlesDegenerateInput(line: String) {
        #expect(Redactor.redact(line) == line)
    }
}
