import Foundation
import Observation

/// Every URL the client has drawn, newest first.
///
/// **Fed from the rendered line rather than by scanning text a second time.**
/// `LineRenderer.applyLinks` already runs an `NSDataDetector` over every line and leaves a
/// `.link` attribute where it found one; the catcher reads those runs back. A second
/// detector pass would be a second opinion about what a URL is, and the two would
/// eventually disagree about which half of `see http://x/(a)` is the link.
///
/// **Inbound only.** What you typed is in your own command history and in the buffer in
/// front of you; the catcher exists for the link somebody else posted an hour ago.
@MainActor
@Observable
public final class URLCatcher {
    /// One URL, and where it came from.
    ///
    /// Identity is the URL *and* the buffer: the same link posted in two channels is two
    /// entries, because "where did I see this" is half of what the window is for.
    public struct Entry: Identifiable, Hashable, Sendable {
        public let url: URL
        public let network: String
        public let buffer: String
        /// When it was last seen. Updated rather than duplicated on a repeat.
        public var date: Date

        public var id: String { "\(network)\u{1}\(buffer)\u{1}\(url.absoluteString)" }

        public init(url: URL, network: String, buffer: String, date: Date) {
            self.url = url
            self.network = network
            self.buffer = buffer
            self.date = date
        }
    }

    /// Newest first, which is the order the window shows and the order Copy All produces.
    public private(set) var entries: [Entry] = []

    /// How many are kept. A client left open for a week must not grow without bound, the
    /// same reason the scrollback has a cap — and a list of ten thousand links is not a
    /// list anyone reads.
    public var cap: Int {
        didSet { trim() }
    }

    public init(cap: Int = 500) {
        self.cap = cap
    }

    /// Records every link in a rendered line.
    public func record(
        _ line: AttributedString,
        network: String,
        buffer: String,
        date: Date = Date()
    ) {
        for run in line.runs {
            guard let url = run.link else { continue }
            record(url, network: network, buffer: buffer, date: date)
        }
    }

    /// Records one URL.
    ///
    /// A repeat moves to the front and takes the new time rather than adding a row: a bot
    /// reposting the same link every hour would otherwise be the whole window.
    public func record(_ url: URL, network: String, buffer: String, date: Date = Date()) {
        let entry = Entry(url: url, network: network, buffer: buffer, date: date)
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        trim()
    }

    /// The entries a scope names.
    public func entries(in scope: URLCatcherScope, network: String?, buffer: String?) -> [Entry] {
        switch scope {
        case .everywhere:
            entries
        case .network:
            entries.filter { $0.network == network }
        case .buffer:
            entries.filter { $0.network == network && $0.buffer == buffer }
        }
    }

    public func clear() {
        entries.removeAll()
    }

    private func trim() {
        guard entries.count > cap else { return }
        entries.removeLast(entries.count - cap)
    }
}

/// How much of the history the catcher window is showing.
public enum URLCatcherScope: String, CaseIterable, Identifiable, Sendable {
    case buffer = "This Buffer"
    case network = "This Network"
    case everywhere = "Everywhere"

    public var id: String { rawValue }
}
