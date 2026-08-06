import CryptoKit
import Foundation

/// A SASL mechanism this client can complete.
///
/// Ordered by preference, strongest first: `SCRAM-SHA-256` never puts the password on the
/// wire, `EXTERNAL` puts nothing on the wire at all because the TLS certificate already
/// said who we are, and `PLAIN` is the fallback every network supports.
public enum SASLMechanism: String, Sendable, Hashable, CaseIterable {
    case scramSHA256 = "SCRAM-SHA-256"
    case external = "EXTERNAL"
    case plain = "PLAIN"

    /// Whether the mechanism needs a password. `EXTERNAL` proves identity with the
    /// client certificate instead, which is the whole of CertFP.
    public var needsPassword: Bool { self != .external }

    /// A phrase for the Connect sheet and for an error line.
    public var summary: String {
        switch self {
        case .scramSHA256: "SCRAM-SHA-256"
        case .external: "EXTERNAL (client certificate)"
        case .plain: "PLAIN"
        }
    }
}

/// Why a SASL exchange could not be completed by us.
///
/// A server *rejecting* the credentials is a numeric, not one of these: this is the client
/// giving up because it cannot answer what it was asked.
public enum SASLError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server's challenge was not the shape the mechanism defines.
    case malformedChallenge(String)
    /// The server's final signature did not match the one we computed. Under SCRAM this
    /// means the peer does not hold the password — an active attacker, or the wrong server.
    case serverSignatureMismatch
    /// A challenge arrived after the exchange was already finished.
    case unexpectedChallenge

    public var description: String {
        switch self {
        case .malformedChallenge(let detail): "the server's SASL challenge was malformed: \(detail)"
        case .serverSignatureMismatch: "the server failed to prove it knows the password"
        case .unexpectedChallenge: "the server continued a SASL exchange that had finished"
        }
    }
}

/// One SASL exchange, as a state machine over decoded payloads.
///
/// Deliberately knows nothing about `AUTHENTICATE`, base64 or the 400-byte chunking — that
/// is ``SASLWire``'s, and keeping them apart is what makes the cryptography testable
/// against RFC 7677's published vectors without a connection.
struct SASLExchange {
    private enum State {
        case initial
        case awaitingServerFirst
        case awaitingServerFinal
        case finished
    }

    let mechanism: SASLMechanism
    private let authenticationIdentity: String
    private let password: String
    /// The client nonce, injected so a test can pin it to a published vector.
    private let clientNonce: String

    private var state: State = .initial

    /// SCRAM's running transcript, built across the three messages it signs over.
    private var clientFirstBare = ""
    private var saltedPassword = Data()
    private var authMessage = ""

    init(
        mechanism: SASLMechanism,
        account: String,
        password: String,
        clientNonce: String = SASLExchange.freshNonce()
    ) {
        self.mechanism = mechanism
        self.authenticationIdentity = account
        self.password = password
        self.clientNonce = clientNonce
    }

    /// Whether the exchange has said everything it has to say.
    var isFinished: Bool { state == .finished }

    /// The response to one challenge, which for the first step is empty.
    ///
    /// Every step produces a payload, including the last: SASL over IRC ends with the
    /// client sending an empty `AUTHENTICATE +` to acknowledge the server's final message.
    mutating func respond(to challenge: Data) throws -> Data {
        switch mechanism {
        case .external:
            guard state == .initial else { throw SASLError.unexpectedChallenge }
            state = .finished
            // The authorization identity, empty to mean "whoever the certificate says".
            return Data(authenticationIdentity.utf8)

        case .plain:
            guard state == .initial else { throw SASLError.unexpectedChallenge }
            state = .finished
            // `authzid \0 authcid \0 passwd`, with an empty authzid: we are not asking to
            // act as anyone other than the account we are authenticating as.
            var payload = Data([0])
            payload.append(Data(authenticationIdentity.utf8))
            payload.append(0)
            payload.append(Data(password.utf8))
            return payload

        case .scramSHA256:
            return try scramStep(challenge)
        }
    }

    // MARK: - SCRAM-SHA-256

    private mutating func scramStep(_ challenge: Data) throws -> Data {
        switch state {
        case .initial:
            clientFirstBare = "n=\(Self.escapeSCRAMName(authenticationIdentity)),r=\(clientNonce)"
            state = .awaitingServerFirst
            // `n,,` is the GS2 header: no channel binding, no authorization identity.
            return Data("n,,\(clientFirstBare)".utf8)

        case .awaitingServerFirst:
            let serverFirst = String(decoding: challenge, as: UTF8.self)
            let fields = Self.scramFields(serverFirst)
            guard let combinedNonce = fields["r"],
                let saltText = fields["s"], let salt = Data(base64Encoded: saltText),
                let iterationsText = fields["i"], let iterations = Int(iterationsText),
                iterations > 0
            else { throw SASLError.malformedChallenge(serverFirst) }
            // The server must extend our nonce rather than replace it; if it does not, the
            // exchange is not bound to our own challenge and is worthless.
            guard combinedNonce.hasPrefix(clientNonce), combinedNonce != clientNonce else {
                throw SASLError.malformedChallenge("the server did not extend the client nonce")
            }

            saltedPassword = Self.hi(
                password: Data(password.utf8),
                salt: salt,
                iterations: iterations
            )
            let clientKey = Self.hmac(key: saltedPassword, message: Data("Client Key".utf8))
            let storedKey = Data(SHA256.hash(data: clientKey))

            // `c=biws` is base64("n,,") — the same GS2 header, repeated so the server can
            // detect a downgrade of the channel-binding flag.
            let withoutProof = "c=biws,r=\(combinedNonce)"
            authMessage = "\(clientFirstBare),\(serverFirst),\(withoutProof)"
            let clientSignature = Self.hmac(key: storedKey, message: Data(authMessage.utf8))
            let proof = Data(zip(clientKey, clientSignature).map(^))

            state = .awaitingServerFinal
            return Data("\(withoutProof),p=\(proof.base64EncodedString())".utf8)

        case .awaitingServerFinal:
            let serverFinal = String(decoding: challenge, as: UTF8.self)
            let fields = Self.scramFields(serverFinal)
            if let error = fields["e"] {
                throw SASLError.malformedChallenge(error)
            }
            guard let signature = fields["v"], let received = Data(base64Encoded: signature) else {
                throw SASLError.malformedChallenge(serverFinal)
            }
            let serverKey = Self.hmac(key: saltedPassword, message: Data("Server Key".utf8))
            let expected = Self.hmac(key: serverKey, message: Data(authMessage.utf8))
            // Constant-time, because this is a MAC comparison and the timing of a `==` over
            // `Data` is a function of how many leading bytes matched.
            guard Self.constantTimeEqual(received, expected) else {
                throw SASLError.serverSignatureMismatch
            }
            state = .finished
            return Data()

        case .finished:
            throw SASLError.unexpectedChallenge
        }
    }

    /// `a=1,b=2` as a dictionary. A field with no `=` is ignored rather than fatal — the
    /// caller checks for what it needs and reports the whole string if it is missing.
    static func scramFields(_ message: String) -> [String: String] {
        var fields: [String: String] = [:]
        for field in message.split(separator: ",") {
            guard let separator = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<separator])
            fields[key] = String(field[field.index(after: separator)...])
        }
        return fields
    }

    /// SCRAM's username escaping: `,` and `=` are the message's own delimiters.
    static func escapeSCRAMName(_ name: String) -> String {
        name.replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
    }

    /// PBKDF2-HMAC-SHA-256, which RFC 5802 calls `Hi`.
    ///
    /// Written out rather than reached for in CommonCrypto: the derived key is exactly one
    /// hash long, so the general multi-block form is not needed, and this keeps the whole
    /// mechanism inside CryptoKit.
    static func hi(password: Data, salt: Data, iterations: Int) -> Data {
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])  // INT(1), the only block a 32-byte key needs.
        var u = hmac(key: password, message: block)
        var result = u
        for _ in 1..<iterations {
            u = hmac(key: password, message: u)
            result = Data(zip(result, u).map(^))
        }
        return result
    }

    static func hmac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    /// A fresh client nonce: 24 random bytes, base64'd.
    ///
    /// SCRAM's nonce must not repeat across exchanges — reuse lets a recorded exchange be
    /// replayed — so this comes from the system generator rather than from a counter.
    static func freshNonce() -> String {
        var bytes = Data(count: 24)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        // The nonce is printable ASCII by definition and may contain no comma, which
        // base64's alphabet already guarantees.
        return bytes.base64EncodedString()
    }
}

/// The `AUTHENTICATE` framing: base64, split into 400-byte chunks.
///
/// Its own type because the chunking rule has an edge nobody remembers — a payload whose
/// encoding is an exact multiple of 400 needs a trailing empty chunk, or the server waits
/// forever for a short line that never comes.
enum SASLWire {
    /// IRCv3's chunk size for `AUTHENTICATE`.
    static let chunkSize = 400

    /// The empty payload, and the end-of-message marker.
    static let empty = "+"

    /// One payload as the parameters of one or more `AUTHENTICATE` lines.
    static func chunks(for payload: Data) -> [String] {
        guard !payload.isEmpty else { return [empty] }
        let encoded = payload.base64EncodedString()
        var chunks: [String] = []
        var rest = Substring(encoded)
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(chunkSize)))
            rest = rest.dropFirst(chunkSize)
        }
        // A final chunk of exactly 400 is indistinguishable from "more follows", so an
        // empty one is appended to say the message ended.
        if encoded.count % chunkSize == 0 { chunks.append(empty) }
        return chunks
    }

    /// What one inbound `AUTHENTICATE` parameter completed, if anything.
    enum Arrival: Sendable, Equatable {
        /// A chunk of exactly ``chunkSize``: more of the same challenge follows.
        case incomplete
        case complete(Data)
        /// The accumulated text was not base64. The server is not speaking SASL at us.
        case undecodable
    }

    /// Accumulates inbound chunks until one of them ends the challenge.
    struct Accumulator {
        private var buffer = ""

        mutating func push(_ parameter: String) -> Arrival {
            if parameter == empty {
                // Either an empty challenge, or the terminator after an exact multiple of
                // 400. Both mean "decode what you have".
                defer { buffer = "" }
                guard !buffer.isEmpty else { return .complete(Data()) }
                return Data(base64Encoded: buffer).map(Arrival.complete) ?? .undecodable
            }
            buffer += parameter
            guard parameter.count < chunkSize else { return .incomplete }
            defer { buffer = "" }
            return Data(base64Encoded: buffer).map(Arrival.complete) ?? .undecodable
        }
    }
}
