import Observation

/// One window's input box: what is typed in it, and what was typed before.
///
/// Per buffer, not per window-position. Both halves have to be: a history that outlived
/// the line it belongs to would offer you the wrong window's commands, and an
/// in-progress line that did not survive a buffer switch would be lost every time you
/// glanced at another channel.
@MainActor
@Observable
public final class InputState {
    /// What is in the box right now.
    public var text: String = ""

    /// Lines sent from this window, oldest first.
    public private(set) var history: [String] = []

    /// How many lines are kept. A client left open for a week must not grow without
    /// bound — the same rule the scrollback follows, at a much smaller scale.
    @ObservationIgnored public let historyLimit: Int

    /// Where we are while arrowing back through ``history``. `nil` means the box holds a
    /// line being written rather than one being recalled.
    @ObservationIgnored private var browseIndex: Int?

    /// The line that was being written when browsing started, so arrowing back down
    /// returns it rather than an empty box.
    @ObservationIgnored private var liveLine: String = ""

    public init(historyLimit: Int = 200) {
        self.historyLimit = historyLimit
    }

    /// Records a sent line and returns the box to a fresh state.
    ///
    /// An immediate repeat is not recorded twice: pressing Enter on the same command
    /// three times should leave one entry to arrow back to, not three.
    public func record(_ line: String) {
        browseIndex = nil
        liveLine = ""
        text = ""
        guard !line.isEmpty, history.last != line else { return }
        history.append(line)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    /// Steps back through the history. Returns whether there was anywhere to go.
    @discardableResult
    public func recallPrevious() -> Bool {
        guard !history.isEmpty else { return false }
        switch browseIndex {
        case nil:
            liveLine = text
            browseIndex = history.count - 1
        case .some(0):
            // Already at the oldest. Stopping here rather than wrapping: a history that
            // wraps silently repeats itself and you lose your place.
            return false
        case .some(let index):
            browseIndex = index - 1
        }
        text = history[browseIndex ?? 0]
        return true
    }

    /// Steps forward, ending back at the line that was being written.
    @discardableResult
    public func recallNext() -> Bool {
        guard let index = browseIndex else { return false }
        if index + 1 >= history.count {
            browseIndex = nil
            text = liveLine
            return true
        }
        browseIndex = index + 1
        text = history[index + 1]
        return true
    }

    /// Called when the user edits the box themselves, which ends any recall in progress —
    /// the text is theirs again, not a copy of an old line.
    public func noteEdited() {
        browseIndex = nil
    }
}
