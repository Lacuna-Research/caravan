import Diagnostics
import Foundation
import IRCSession
import Observation

/// Where the wire trace goes: the canvas, a file, both, or neither.
///
/// The trace itself is not switchable — `TraceBuffer` records from launch, which is the
/// whole reason `/debug -i` can show you what happened before you asked. This owns the
/// *destinations*, and both the `/debug` command and the canvas's own controls drive it,
/// so there is one piece of state rather than a command and a UI that can disagree.
///
/// Rendering is the same table everything else uses: `.rawInbound` and `.rawOutbound`
/// give `<<` and `>>`, so the canvas, the status window's raw toggle, the clipboard
/// export and the file all read identically.
@MainActor
@Observable
public final class DebugController {
    /// The canvas's scrollback.
    public let log: MessageLogController

    /// Whether the canvas is being fed. On by default: a debug surface that shows nothing
    /// until you type a command looks broken, and looking is the reason to open it.
    public private(set) var isStreamingToCanvas = true

    /// Where `/debug <file>` is writing, if anywhere. Shown in the canvas, because a
    /// process quietly appending to a file on disk should never be invisible.
    public private(set) var fileURL: URL?

    @ObservationIgnored private let trace: TraceBuffer
    @ObservationIgnored private let settings: ChatSettings
    @ObservationIgnored private var writer: TraceFileWriter?
    @ObservationIgnored private var pump: Task<Void, Never>?

    /// The newest event each sink has already been given.
    ///
    /// One rule covers both the live feed and `-i`: **a sink is only ever given events
    /// newer than the newest it has.** So `-i` fills exactly the gap left while output was
    /// off and nothing else, asking for it twice adds nothing the second time, and
    /// clearing the canvas — which resets the mark — lets `-i` bring the whole ring back.
    /// Monotonic timestamps make the comparison exact.
    ///
    /// A sink that is switched off deliberately stops advancing, because the gap it is
    /// missing is precisely what `-i` has to be able to find later.
    @ObservationIgnored private var canvasWatermark: ContinuousClock.Instant?
    @ObservationIgnored private var fileWatermark: ContinuousClock.Instant?

    public init(trace: TraceBuffer, settings: ChatSettings) {
        self.trace = trace
        self.settings = settings
        self.log = MessageLogController(lineCap: settings.scrollbackLines)
        self.log.chatFont = ChatFont.nsFont(
            family: settings.fontFamily,
            size: settings.fontSize
        )

        // Retained and live in one atomic step, so the canvas holds the complete trace
        // from launch with nothing dropped or doubled at the join.
        let (retained, events) = trace.feed(includingRetained: true)
        deliver(retained)
        pump = Task { [weak self] in
            for await event in events {
                self?.deliver([event])
            }
        }
    }

    deinit {
        pump?.cancel()
    }

    // MARK: - Destinations

    /// Carries out a `/debug`, and returns the line to show the user.
    ///
    /// Every path answers, including the ones that change nothing: `/debug off` twice
    /// should say so rather than look broken the second time.
    public func apply(_ command: DebugCommand) -> String {
        switch command {
        case .report:
            return report

        case .off:
            isStreamingToCanvas = false
            closeFile()
            return "Debug output off"

        case .toCanvas(let includingExistingTrace):
            let wasStreaming = isStreamingToCanvas
            isStreamingToCanvas = true
            if includingExistingTrace {
                appendToCanvas(fresh(trace.snapshot(), for: &canvasWatermark))
            }
            return wasStreaming
                ? "Debug output already going to the Settings & Debug canvas"
                : "Debug output to the Settings & Debug canvas"

        case .toFile(let path, let includingExistingTrace):
            do {
                closeFile()
                let writer = try TraceFileWriter(path: path)
                writer.write(
                    line: "--- Caravan debug log. Credentials are redacted before they reach it."
                )
                self.writer = writer
                fileURL = writer.url
                if includingExistingTrace {
                    for event in fresh(trace.snapshot(), for: &fileWatermark) {
                        writer.write(event)
                    }
                }
                return "Debug output to \(writer.url.path) — redacted, safe to attach to a report"
            } catch {
                return "Cannot write \(path): \(error.localizedDescription)"
            }
        }
    }

    /// The canvas's own switch, and the same state `/debug window` and `/debug off` set.
    public func setStreamingToCanvas(_ isStreaming: Bool) {
        isStreamingToCanvas = isStreaming
    }

    /// Stops the file destination and leaves the canvas alone. The canvas's "stop
    /// writing" button, and half of `/debug off`.
    public func closeFile() {
        writer?.close()
        writer = nil
        fileURL = nil
        fileWatermark = nil
    }

    /// What bare `/debug` says.
    public var report: String {
        switch (isStreamingToCanvas, fileURL) {
        case (true, let url?): "Debug output to the Settings & Debug canvas and \(url.path)"
        case (true, nil): "Debug output to the Settings & Debug canvas"
        case (false, let url?): "Debug output to \(url.path)"
        case (false, nil): "Debug output off — /debug window or /debug <file> to start"
        }
    }

    /// Adopts changed settings. The canvas is a buffer like any other in this one respect.
    public func applySettings() {
        log.lineCap = settings.scrollbackLines
        log.chatFont = ChatFont.nsFont(family: settings.fontFamily, size: settings.fontSize)
    }

    /// Empties the canvas view. The ring buffer is untouched — `/debug -i` can still
    /// bring it all back, which is what makes clearing safe to offer.
    public func clearCanvas() {
        log.clear()
        canvasWatermark = nil
    }

    // MARK: - The feed

    private func deliver(_ events: [TraceEvent]) {
        guard !events.isEmpty else { return }
        if isStreamingToCanvas {
            appendToCanvas(fresh(events, for: &canvasWatermark))
        }
        if let writer {
            for event in fresh(events, for: &fileWatermark) {
                writer.write(event)
            }
        }
    }

    private func appendToCanvas(_ events: [TraceEvent]) {
        guard !events.isEmpty else { return }
        log.append(events.map { renderer.line($0.line, kind: kind(of: $0)) })
    }

    /// The events a sink has not had yet, advancing its mark past them.
    private func fresh(
        _ events: [TraceEvent],
        for watermark: inout ContinuousClock.Instant?
    ) -> [TraceEvent] {
        let unseen = watermark.map { mark in events.filter { $0.timestamp > mark } } ?? events
        if let last = unseen.last { watermark = last.timestamp }
        return unseen
    }

    private func kind(of event: TraceEvent) -> LineKind {
        switch event.direction {
        case .inbound: .rawInbound
        case .outbound: .rawOutbound
        }
    }

    private var renderer: LineRenderer { settings.renderer }
}
