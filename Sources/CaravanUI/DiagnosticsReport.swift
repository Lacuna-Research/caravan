import AppKit
import Diagnostics
import Foundation

/// The text "Copy Diagnostics" puts on the clipboard.
///
/// Everything a bug report needs and nothing it does not: what the app is, what it is
/// running on, and what actually crossed the wire. The trace is **already redacted** —
/// `TraceBuffer` strips credentials on insert, not on export, so the plaintext of a
/// `PASS` or a NickServ `identify` exists nowhere but the socket write itself. That is
/// what makes this safe to paste into a public issue.
public enum DiagnosticsReport {
    /// Builds the report.
    public static func text(trace: TraceBuffer, bundle: Bundle = .main) -> String {
        var lines: [String] = []
        lines.append("Caravan \(version(of: bundle))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append(
            "Wire trace: \(trace.count) of \(trace.capacity) events retained, redacted on insert"
        )
        lines.append("")

        let events = trace.snapshot()
        if events.isEmpty {
            lines.append("(no wire traffic recorded)")
        } else {
            for event in events {
                lines.append("\(marker(for: event.direction)) \(event.line)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Copies the report, returning what was copied so a caller can say how much.
    @MainActor
    @discardableResult
    public static func copyToPasteboard(trace: TraceBuffer, bundle: Bundle = .main) -> String {
        let report = text(trace: trace, bundle: bundle)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        return report
    }

    /// The same `>>`/`<<` markers the raw-traffic toggle uses, so a trace pasted into an
    /// issue reads the same way as the window it came from.
    private static func marker(for direction: TraceEvent.Direction) -> String {
        switch direction {
        case .outbound: ">>"
        case .inbound: "<<"
        }
    }

    private static func version(of bundle: Bundle) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case (let short?, let build?): return "\(short) (\(build))"
        case (let short?, nil): return short
        case (nil, let build?): return "build \(build)"
        case (nil, nil): return "development build"
        }
    }
}
