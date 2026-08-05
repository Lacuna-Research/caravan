import CryptoKit
import Diagnostics
import Foundation
import IRCProtocol
import Network
import Synchronization

/// One socket, as a stream of ``IRCMessage`` in and a `send` for messages out.
///
/// IRC semantics are deliberately absent: this layer knows about bytes, lines and TLS,
/// and nothing about PING, registration or numerics. Those are the session's.
///
/// **One instance is one connection attempt.** ``connect(host:port:tls:)`` may be called
/// once; after a terminal state both streams finish and the object is spent. Reconnect
/// means a new instance, which is what keeps a retry from inheriting half-torn-down
/// state — and it matches `AsyncStream`, which is single-shot anyway.
public actor IRCConnection {
    /// Read size. Large enough that a MOTD burst arrives in a few reads, small enough
    /// that a stalled connection is not holding much.
    private static let receiveChunkBytes = 64 * 1024

    private let trace: TraceBuffer
    private let queue = DispatchQueue(label: "com.lacuna-research.caravan.transport")

    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var framer = LineFramer()
    private var hasConnected = false

    /// Every inbound message, in order. Finishes when the connection reaches a terminal
    /// state; already-yielded messages still drain first.
    public nonisolated let inbound: AsyncStream<IRCMessage>
    private let inboundContinuation: AsyncStream<IRCMessage>.Continuation

    /// Connection lifecycle. Begins with `.idle` and ends with `.failed` or `.cancelled`.
    public nonisolated let state: AsyncStream<TransportState>
    private let stateContinuation: AsyncStream<TransportState>.Continuation

    /// Latches on the first terminal state so a failure and the cancellation that
    /// follows it cannot both be reported. Nonisolated because `NWConnection` callbacks
    /// arrive on a dispatch queue and must not race an actor hop to get here.
    private let terminated = Mutex(false)

    private let certificateBox = CertificateBox()

    /// What the peer presented, once a TLS handshake with a verify block has run.
    ///
    /// Only populated for `.enabled(allowSelfSigned: true)`: the default path uses stock
    /// system validation, which we do not intercept.
    public var acceptedCertificate: TLSCertificate? { certificateBox.value }

    /// - Parameter trace: Every line in and out is recorded here. Redaction happens on
    ///   insert inside the buffer, so this transport never handles a redacted string.
    public init(trace: TraceBuffer) {
        self.trace = trace
        let inboundStream = AsyncStream<IRCMessage>.makeStream(bufferingPolicy: .unbounded)
        self.inbound = inboundStream.stream
        self.inboundContinuation = inboundStream.continuation
        let stateStream = AsyncStream<TransportState>.makeStream(bufferingPolicy: .unbounded)
        self.state = stateStream.stream
        self.stateContinuation = stateStream.continuation
        stateContinuation.yield(.idle)
    }

    deinit {
        inboundContinuation.finish()
        stateContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts connecting. Returns immediately; readiness and failure arrive on ``state``.
    public func connect(host: String, port: UInt16, tls: TLSMode) {
        guard !hasConnected else {
            Log.transport.error("connect called twice on one IRCConnection; ignored")
            return
        }
        hasConnected = true

        // `NWEndpoint.Port` accepts 0 — it means "any port", which is meaningful for a
        // listener and meaningless for us. Rejected here rather than opening a socket
        // that can never connect.
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            finish(.failed(.invalidPort(port)))
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters(for: tls)
        )
        self.connection = connection

        Log.transport.info(
            "connecting to \(host, privacy: .public):\(port, privacy: .public) tls=\(tls.logDescription, privacy: .public)"
        )
        stateContinuation.yield(.connecting)

        // Handled without hopping to the actor. NWConnection serializes these callbacks
        // on our queue, so yielding straight to the continuation preserves their order;
        // one `Task` per update would not.
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .setup, .preparing:
                break  // .connecting already reported.
            case .waiting(let error):
                // Not terminal: NWConnection keeps retrying (no route, DNS not up yet).
                Log.transport.info(
                    "connection waiting: \(error.debugDescription, privacy: .public)"
                )
            case .ready:
                Log.transport.info("connection ready")
                self?.stateContinuation.yield(.ready)
            case .failed(let error):
                Log.transport.error(
                    "connection failed: \(error.debugDescription, privacy: .public)"
                )
                self?.finish(.failed(.connectionFailed(reason: error.debugDescription)))
                Task { await self?.tearDown() }
            case .cancelled:
                self?.finish(.cancelled)
                Task { await self?.tearDown() }
            @unknown default:
                break
            }
        }

        connection.start(queue: queue)
        receiveTask = Task { await self.receiveLoop(connection) }
    }

    /// Closes the connection. Idempotent, and reported as `.cancelled` rather than
    /// `.failed` so a deliberate disconnect is never mistaken for a network problem.
    public func disconnect() {
        if finish(.cancelled) {
            Log.transport.info("disconnected by request")
        }
        tearDown()
    }

    private func tearDown() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel()
        connection = nil
    }

    /// Reports a terminal state and closes both streams. Returns whether this was the
    /// first terminal state; later ones are dropped.
    @discardableResult
    private nonisolated func finish(_ terminal: TransportState) -> Bool {
        let isFirst = terminated.withLock { alreadyTerminated in
            if alreadyTerminated { return false }
            alreadyTerminated = true
            return true
        }
        guard isFirst else { return false }
        stateContinuation.yield(terminal)
        inboundContinuation.finish()
        stateContinuation.finish()
        return true
    }

    // MARK: - Receiving

    /// Reads until the connection ends.
    ///
    /// A loop rather than a self-rescheduling callback: the framer is mutable state, and
    /// `Task { await ingest(...) }` per callback would not guarantee the chunks reach it
    /// in arrival order. Awaiting each read in turn does.
    private func receiveLoop(_ connection: NWConnection) async {
        while !Task.isCancelled {
            let result = await withCheckedContinuation {
                (continuation: CheckedContinuation<ReceiveResult, Never>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: Self.receiveChunkBytes
                ) { data, _, isComplete, error in
                    continuation.resume(
                        returning: ReceiveResult(
                            data: data,
                            isComplete: isComplete,
                            errorReason: error?.debugDescription
                        )
                    )
                }
            }

            if let data = result.data, !data.isEmpty {
                ingest(data)
            }
            if let reason = result.errorReason {
                Log.transport.error("receive failed: \(reason, privacy: .public)")
                finish(.failed(.receiveFailed(reason: reason)))
                tearDown()
                return
            }
            if result.isComplete {
                Log.transport.info("connection closed by peer")
                finish(.failed(.closedByPeer))
                tearDown()
                return
            }
        }
    }

    /// The one inbound trace call site: nothing can arrive without being recorded.
    private func ingest(_ data: Data) {
        let output = framer.push(data)
        if output.droppedOverlongLines > 0 {
            Log.transport.error(
                "dropped \(output.droppedOverlongLines, privacy: .public) overlong inbound line(s)"
            )
        }
        for bytes in output.lines {
            let line = WireDecoding.line(from: bytes)
            trace.record(.inbound, line: line)
            // Parsing fails only on a line with no command at all — a stray CRLF. It is
            // in the trace either way; there is nothing for a consumer to do with it.
            guard let message = IRCMessage(line: line) else { continue }
            inboundContinuation.yield(message)
        }
    }

    // MARK: - Sending

    /// Serializes and writes one message.
    ///
    /// No outbound queue of our own: `send` is actor-isolated so call order is the
    /// enqueue order, and `NWConnection` writes each `send` contiguously and in order on
    /// a stream connection. A second queue would only be a second thing to get wrong.
    public func send(_ message: IRCMessage) {
        let line = wireLine(for: message)
        // The one outbound trace call site, before the write, so a line that fails to
        // send is still visible in the trace.
        trace.record(.outbound, line: line)

        guard let connection else {
            Log.transport.error("send with no connection; line dropped")
            return
        }
        connection.send(
            content: WireDecoding.data(for: line),
            completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Log.transport.error("send failed: \(error.debugDescription, privacy: .public)")
                self?.finish(.failed(.sendFailed(reason: error.debugDescription)))
            }
        )
    }

    /// The wire form, truncated if it would exceed the protocol limit.
    ///
    /// The server truncates an overlong line anyway; doing it here keeps the trace
    /// honest about what actually went out. Tags are left alone — their 8191-byte budget
    /// is separate and nothing we send comes near it.
    private func wireLine(for message: IRCMessage) -> String {
        guard !message.fitsProtocolLimits else { return message.wireForm }
        var withoutTags = message
        withoutTags.tags = IRCTags()
        let body = withoutTags.wireForm.truncated(to: IRCProtocolLimits.maximumMessageBytes - 2)
        Log.transport.error("outbound message exceeded the protocol limit and was truncated")
        return message.tags.isEmpty ? body : "@\(message.tags.wireForm) " + body
    }

    // MARK: - Parameters and TLS

    private func parameters(for tls: TLSMode) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // IRC is interactive and its writes are one short line at a time. Nagle would
        // hold a line back waiting for company that is not coming.
        tcp.noDelay = true

        switch tls {
        case .disabled:
            return NWParameters(tls: nil, tcp: tcp)
        case .enabled(let allowSelfSigned):
            let options = NWProtocolTLS.Options()
            if allowSelfSigned {
                installVerifyBlock(on: options)
            }
            return NWParameters(tls: options, tcp: tcp)
        }
    }

    /// Installed *only* for `allowSelfSigned`, so the ordinary path keeps stock system
    /// validation rather than our reimplementation of it.
    ///
    /// Even here the certificate is evaluated and recorded rather than waved through
    /// unseen: ``acceptedCertificate`` carries the fingerprint out to the caller, and
    /// the log says plainly that trust was not established. A UI that asks the user
    /// before accepting is stage 2's — see the note on PLAN.md.
    private func installVerifyBlock(on options: NWProtocolTLS.Options) {
        let certificateBox = self.certificateBox
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                let systemTrusted = SecTrustEvaluateWithError(trust, nil)
                let certificate = TLSCertificate(leafOf: trust, systemTrusted: systemTrusted)
                certificateBox.store(certificate)

                if systemTrusted {
                    Log.transport.info("TLS certificate validated by the system")
                } else {
                    Log.transport.error(
                        """
                        accepting an unvalidated TLS certificate because self-signed \
                        certificates were allowed: \
                        \(certificate?.sha256Fingerprint ?? "no certificate", privacy: .public)
                        """
                    )
                }
                complete(true)
            },
            queue
        )
    }
}

/// Somewhere for the TLS verify block to leave the certificate.
///
/// A reference type because `Mutex` is non-copyable: the block runs on a dispatch queue
/// and needs a handle it can capture without capturing the actor.
private final class CertificateBox: Sendable {
    private let storage = Mutex<TLSCertificate?>(nil)

    var value: TLSCertificate? { storage.withLock { $0 } }

    func store(_ certificate: TLSCertificate?) {
        storage.withLock { $0 = certificate }
    }
}

/// One `NWConnection.receive` result, flattened to `Sendable` values.
private struct ReceiveResult: Sendable {
    var data: Data?
    var isComplete: Bool
    var errorReason: String?
}

extension TLSCertificate {
    /// Summarizes the leaf certificate of an evaluated trust object.
    fileprivate init?(leafOf trust: SecTrust, systemTrusted: Bool) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        self.init(
            subject: SecCertificateCopySubjectSummary(leaf) as String?,
            sha256Fingerprint: digest.map { String(format: "%02x", $0) }.joined(separator: ":"),
            systemTrusted: systemTrusted
        )
    }
}

extension TLSMode {
    fileprivate var logDescription: String {
        switch self {
        case .disabled: "off"
        case .enabled(let allowSelfSigned): allowSelfSigned ? "on (self-signed allowed)" : "on"
        }
    }
}
