import Foundation
import IRCFormat
import IRCProtocol

/// One channel as `LIST` describes it.
///
/// The topic arrives with mIRC formatting codes in it and is stripped here rather than at
/// render time: colour in a dense table is noise, the raw control bytes in a table cell are
/// worse, and stripping twenty-two thousand topics once is cheaper than stripping the
/// visible ones on every scroll.
public struct ChannelListing: Sendable, Hashable, Identifiable {
    public let name: IRCChannelName
    public let members: Int
    public let topic: String

    /// The topic folded for searching, computed once on arrival.
    ///
    /// **The reason the search field can keep up.** Lowercasing the corpus per keystroke is
    /// twenty-two thousand allocations per character typed; the name needs no equivalent
    /// because ``IRCChannelName`` already carries its folded form.
    let searchableTopic: String

    public var id: IRCChannelName { name }

    public init(name: IRCChannelName, members: Int, topic: String) {
        self.name = name
        self.members = members
        self.topic = IRCFormatting.stripping(topic)
        self.searchableTopic = self.topic.lowercased()
    }

    /// `#swift` — what the column shows and what sorting compares.
    public var displayName: String { name.raw }
}

/// What the fields above the table currently ask for.
///
/// A value type separate from the view so the matching is testable without one, and so the
/// whole filter is one `==` away from "did anything actually change".
public struct ChannelListQuery: Sendable, Hashable {
    /// Matched case-insensitively against the name, the topic, or both.
    public var text: String = ""
    public var searchesNames: Bool = true
    public var searchesTopics: Bool = true
    /// `nil` for "no bound", which is not the same as zero.
    public var minimumMembers: Int?
    public var maximumMembers: Int?

    public init() {}

    /// Whether this query would keep everything, in which case filtering is skipped whole.
    public var isEverything: Bool {
        text.isEmpty && minimumMembers == nil && maximumMembers == nil
    }

    public func matches(_ listing: ChannelListing) -> Bool {
        if let minimum = minimumMembers, listing.members < minimum { return false }
        if let maximum = maximumMembers, listing.members > maximum { return false }
        guard !text.isEmpty else { return true }

        // **Plain substring, not `FuzzyMatch`.** That is the quick switcher's tool, where
        // the corpus is forty buffers and the user is aiming at one they can name. Fuzzy
        // over twenty-two thousand topics per keystroke costs what this whole surface
        // exists to avoid, and it answers nonsense: a short query's letters appear in
        // scattered order in almost every sentence in English.
        let needle = text.lowercased()
        if searchesNames, listing.name.folded.contains(needle) { return true }
        if searchesTopics, listing.searchableTopic.contains(needle) { return true }
        return false
    }

    public func apply(to listings: [ChannelListing]) -> [ChannelListing] {
        isEverything ? listings : listings.filter(matches)
    }
}

/// The channels one connection last reported, and whether more are still arriving.
///
/// **Rows accumulate where the view cannot see them and are published on a deadline.**
/// Libera answers `LIST` with about twenty-two thousand 322s; assigning an observed
/// property once per row is twenty-two thousand view invalidations, and the surface this
/// feeds has to stay usable while they arrive. So ``add(_:)`` appends to an unobserved
/// array and ``listings`` — the one thing the table reads — changes at most once per
/// ``flushInterval``, plus once more at the end.
@MainActor
@Observable
public final class ChannelDirectory {
    /// The published snapshot. Assigning this is the expensive thing, so it happens rarely.
    public private(set) var listings: [ChannelListing] = []

    /// Whether a `LIST` is outstanding. Read by the canvas for its progress state, and
    /// named in prompt 16's carry-forward: an inbound flood detector has to know that the
    /// user asked for this.
    public private(set) var isCollecting = false

    /// How many rows have arrived, including ones not yet published. Deliberately *not*
    /// observed: a live counter would defeat the coalescing it is counting.
    @ObservationIgnored public private(set) var arrivedCount = 0

    /// Publishes so far, for the test that the coalescing is real.
    @ObservationIgnored private(set) var publishCount = 0

    @ObservationIgnored private var collected: [ChannelListing] = []
    @ObservationIgnored private var hasUnpublished = false
    @ObservationIgnored private var flusher: Task<Void, Never>?
    /// Set by ``stopCollecting()`` so the rows the server keeps sending are dropped rather
    /// than reopening a collection ``add(_:)`` would otherwise start on its own.
    @ObservationIgnored private var isIgnoringUntilEnd = false

    @ObservationIgnored let flushInterval: Duration

    public init(flushInterval: Duration = .milliseconds(250)) {
        self.flushInterval = flushInterval
    }

    /// A `LIST` has been sent.
    ///
    /// **The previous rows stay on screen until the first new one arrives.** A re-list takes
    /// ten seconds against a large network, and blanking the table for them loses whatever
    /// the user was reading — including, often, the row they were about to double-click.
    public func beginCollecting() {
        collected = []
        arrivedCount = 0
        hasUnpublished = false
        isIgnoringUntilEnd = false
        isCollecting = true
    }

    /// One 322.
    ///
    /// Starts a collection if none is in progress, so a `LIST` sent by hand through
    /// `/quote` — or replayed by a bouncer at attach — is not thrown away for having
    /// skipped ``beginCollecting()``.
    public func add(_ listing: ChannelListing) {
        guard !isIgnoringUntilEnd else { return }
        if !isCollecting {
            beginCollecting()
            listings = []
        }
        collected.append(listing)
        arrivedCount += 1
        hasUnpublished = true
        startFlushing()
    }

    /// 323: the server is done.
    public func endCollecting() {
        isCollecting = false
        isIgnoringUntilEnd = false
        flusher?.cancel()
        flusher = nil
        publish()
    }

    /// The Stop button.
    ///
    /// **This stops collecting, not the server.** `LIST` has no cancel in the protocol; the
    /// rest of the reply is coming whatever the user clicks, and the button says so.
    public func stopCollecting() {
        guard isCollecting else { return }
        isIgnoringUntilEnd = true
        isCollecting = false
        flusher?.cancel()
        flusher = nil
        publish()
    }

    /// A loop that sleeps to a deadline rather than a repeating timer, the shape
    /// `IRCSession.idleMonitor()` established: a timer left running is a timer to remember
    /// to invalidate, and this one has to stop the moment the rows stop.
    private func startFlushing() {
        guard flusher == nil else { return }
        flusher = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.flushInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.publish()
                guard self.isCollecting else {
                    self.flusher = nil
                    return
                }
            }
        }
    }

    private func publish() {
        guard hasUnpublished else { return }
        hasUnpublished = false
        publishCount += 1
        listings = collected
    }
}
