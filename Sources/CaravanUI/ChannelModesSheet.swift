import IRCProtocol
import IRCSession
import SwiftUI

/// A channel's modes, and its ban / quiet / invite / except lists.
///
/// **One sheet with a picker, not four dialogs.** The list numerics are the same shape
/// four times over — a channel, a mask, optionally who set it and when — and a client with
/// four near-identical dialogs is a client with four places to fix the same bug.
///
/// Every change goes out as a `MODE` line through the ordinary command path rather than
/// being applied locally, so the buffer learns about it the same way it learns about a
/// mode somebody else set: from the server. A sheet that updated itself optimistically
/// would show a `+m` that the server refused.
struct ChannelModesSheet: View {
    let model: AppModel

    /// The channel's own network, not the tree's selection. See ``BufferActions``.
    let connection: ConnectionViewModel

    let buffer: ChannelBuffer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatFont) private var chatFont

    @State private var section: Section = .modes
    @State private var list: ListMode = .ban
    @State private var newMask = ""

    private enum Section: String, CaseIterable, Identifiable {
        case modes = "Modes"
        case lists = "Lists"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch section {
            case .modes: modesPane
            case .lists: listsPane
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460, height: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(buffer.name.raw).font(.headline)
            // Says out loud when you cannot actually change anything, rather than letting
            // every toggle fail silently against the server.
            Text(canSetModes ? buffer.channel.modeDescription : "You are not an operator here")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Whether we hold a prefix that is likely to let us set modes. On the buffer since
    /// prompt 9, where the two context menus need the same answer.
    private var canSetModes: Bool { buffer.canSetModes(as: connection.currentNick) }

    // MARK: - Modes

    private var modesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SimpleChannelMode.common, id: \.letter) { mode in
                    Toggle(isOn: binding(for: mode.letter)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(mode.name) (+\(String(mode.letter)))")
                            Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                keyedMode(
                    letter: "k",
                    name: "Key",
                    placeholder: "channel key",
                    summary: "Joining requires this key."
                )
                keyedMode(
                    letter: "l",
                    name: "User limit",
                    placeholder: "maximum users",
                    summary: "Joining is refused above this many people."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A flag mode, sent the moment it is toggled.
    private func binding(for letter: Character) -> Binding<Bool> {
        Binding(
            get: { buffer.channel.modes.contains(letter) },
            set: { isOn in
                send(["\(isOn ? "+" : "-")\(letter)"])
            }
        )
    }

    /// `+k` and `+l` carry an argument, and **unsetting them does not** on most servers —
    /// `-k` wants the old key back on some and nothing on others. The old key is sent when
    /// we know it, which is what the servers that want it expect and what the ones that do
    /// not simply ignore.
    @ViewBuilder
    private func keyedMode(
        letter: Character,
        name: String,
        placeholder: String,
        summary: String
    ) -> some View {
        let current = buffer.channel.modeArguments[letter]
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(name) (+\(String(letter)))")
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            KeyedModeField(
                placeholder: placeholder,
                current: current,
                set: { value in send(["+\(letter)", value]) },
                clear: { send(current.map { ["-\(letter)", $0] } ?? ["-\(letter)"]) }
            )
        }
    }

    // MARK: - Lists

    private var listsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $list) {
                ForEach(availableLists) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .onChange(of: list, initial: true) { _, mode in request(mode) }

            entries
            addRow
        }
    }

    /// Only the lists this server actually has. `EXCEPTS` and `INVEX` say so in `ISUPPORT`;
    /// quiet is offered always, because no token announces it and the networks that lack it
    /// answer with an error rather than silence.
    private var availableLists: [ListMode] {
        ListMode.allCases.filter { mode in
            switch mode {
            case .ban, .quiet: true
            case .except: letters.exceptIsSupported
            case .invite: letters.inviteIsSupported
            }
        }
    }

    private var letters: ListModeSupport {
        ListModeSupport(capabilities: connection.lastKnownCapabilities)
    }

    @ViewBuilder
    private var entries: some View {
        let letter = list.letter(capabilities: letters.letters)
        let rows = buffer.listModes[letter] ?? []
        if buffer.pendingListModes.contains(letter) && rows.isEmpty {
            // "Loading" and "empty" look identical and mean opposite things.
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            Text(list.emptyDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(rows) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.mask).font(chatFont)
                        if let detail = detail(for: entry) {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Remove") { send(["-\(letter)", entry.mask]) }
                        .buttonStyle(.borderless)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func detail(for entry: ListModeEntry) -> String? {
        let by = entry.setBy.map { "by \($0)" }
        let when = entry.setAtDescription
        let parts = [by, when].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var addRow: some View {
        HStack {
            TextField("nick or nick!user@host", text: $newMask)
                .textFieldStyle(.roundedBorder)
                .font(chatFont)
                .onSubmit(add)
            Button("Add", action: add).disabled(newMask.trimmed.isEmpty)
        }
    }

    private func add() {
        let subject = newMask.trimmed
        guard !subject.isEmpty else { return }
        newMask = ""
        // Through the same `/ban` path the command uses, so a bare nick becomes `*!*@host`
        // here exactly as it does when typed — one answer to "what does banning bob mean".
        guard case .ban = list else {
            send(["+\(list.letter(capabilities: letters.letters))", subject])
            return
        }
        Task {
            await connection
                .ban(
                    channel: buffer.name.raw,
                    subject: subject,
                    isSet: true,
                    kickReason: nil,
                    from: .channel(buffer.name)
                )
        }
    }

    /// Asks the server for one list.
    private func request(_ mode: ListMode) {
        let letter = mode.letter(capabilities: letters.letters)
        buffer.beginListMode(letter)
        send(["+\(letter)"])
    }

    private func send(_ arguments: [String]) {
        Task {
            await connection.send(
                IRCMessage(verb: "MODE", parameters: [buffer.name.raw] + arguments),
                from: .channel(buffer.name)
            )
        }
    }
}

/// The text field beside `+k` and `+l`, which commits on Enter rather than per keystroke.
private struct KeyedModeField: View {
    let placeholder: String
    let current: String?
    let set: (String) -> Void
    let clear: () -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onSubmit {
                    let value = text.trimmed
                    if value.isEmpty { clear() } else { set(value) }
                }
                .onChange(of: current, initial: true) { _, value in text = value ?? "" }
            if current != nil {
                Button("Clear", action: clear).buttonStyle(.borderless)
            }
        }
    }
}

/// Which list modes this server has, and at which letters.
struct ListModeSupport {
    var letters = ChannelListModeLetters()
    var exceptIsSupported = false
    var inviteIsSupported = false

    init() {}

    init(capabilities: ServerCapabilities) {
        exceptIsSupported = capabilities.banExceptionMode != nil
        inviteIsSupported = capabilities.inviteExceptionMode != nil
        letters = ChannelListModeLetters(
            quiet: "q",
            invite: capabilities.inviteExceptionMode ?? "I",
            except: capabilities.banExceptionMode ?? "e"
        )
    }
}

/// The flag modes worth a checkbox, with what they actually do.
///
/// Not every mode a server declares: `CHANMODES` group D can hold a dozen letters nobody
/// has heard of, and a sheet of unlabelled checkboxes is worse than no sheet. The ones
/// here are the ones with a settled meaning across networks; anything else is `/mode`.
struct SimpleChannelMode {
    let letter: Character
    let name: String
    let summary: String

    static let common: [SimpleChannelMode] = [
        .init(letter: "m", name: "Moderated", summary: "Only voiced people may speak."),
        .init(letter: "n", name: "No external messages", summary: "Only members may send."),
        .init(letter: "t", name: "Topic locked", summary: "Only operators may set the topic."),
        .init(letter: "i", name: "Invite only", summary: "Joining requires an invitation."),
        .init(letter: "s", name: "Secret", summary: "Hidden from /list and /whois."),
    ]
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
