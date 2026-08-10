import AppKit
import SwiftUI

extension View {
    /// Presents the log viewer when it was asked for *from this window*.
    func logViewer(model: AppModel, in window: KeyWindow) -> some View {
        sheet(
            isPresented: Binding(
                get: { model.logViewerPresentation?.window == window },
                set: { if !$0 { model.logViewerPresentation = nil } }
            )
        ) {
            if let presentation = model.logViewerPresentation {
                LogViewerSheet(log: model.chatLog, presentation: presentation)
            }
        }
    }
}

/// What was said, read back out of the files it was written to.
///
/// **Reads the same plain text the writer wrote, and holds no store of its own.** There is
/// no index, no database and no cache: a log file is the record, and a viewer with a second
/// copy of it would be a viewer that could disagree with `grep`. That also means anything
/// you do to the directory — delete a file, edit one, copy one in from another client —
/// shows up here the next time it is opened.
///
/// The filter is a substring match over the lines on screen rather than a search across
/// every file. Search over a whole log directory is a real feature and it wants an index;
/// this is the honest version of what a text file can answer instantly.
struct LogViewerSheet: View {
    let log: ChatLog
    let presentation: AppModel.LogViewerPresentation

    @Environment(\.dismiss) private var dismiss

    @State private var networks: [String] = []
    @State private var network: String?
    @State private var buffer: String?
    @State private var lines: [String] = []
    @State private var filter = ""

    /// How much of a log the viewer puts on screen at once.
    ///
    /// The tail, not the whole file. A year of `#swift` is megabytes and an `NSTextView`
    /// asked to lay all of it out is a beachball; the Reveal button is the way to the rest,
    /// and it opens the file in something built to page through one.
    private static let visibleLines = 5000

    private var buffers: [String] {
        network.map { log.buffers(in: $0) } ?? []
    }

    private var shown: [String] {
        guard !filter.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                transcript
                    .frame(minWidth: 420)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            Text("Logs").font(.headline)
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
        .padding(10)
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(networks, id: \.self) { name in
                Section(name) {
                    ForEach(log.buffers(in: name), id: \.self) { buffer in
                        Text(buffer).tag(Row(network: name, buffer: buffer))
                    }
                }
            }
        }
        .overlay {
            if networks.isEmpty {
                ContentUnavailableView(
                    "No Logs Yet",
                    systemImage: "doc.plaintext",
                    description: Text(
                        "Conversations are written here once logging is on and something "
                            + "has been said."
                    )
                )
            }
        }
    }

    /// A read-only monospaced transcript. `Text` per line rather than one long string so a
    /// filtered view is cheap to rebuild and selection stays per line.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: shown.count) { _, count in
                // The newest line, which is what somebody opening a log wants to see first.
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        .overlay {
            if buffer == nil {
                ContentUnavailableView(
                    "Nothing Selected",
                    systemImage: "sidebar.left",
                    description: Text("Pick a buffer on the left.")
                )
            } else if shown.isEmpty, !filter.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let network, let buffer {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        log.url(network: network, buffer: buffer)
                    ])
                }
            }
            Spacer()
            if lines.count >= Self.visibleLines {
                Text("Showing the last \(Self.visibleLines) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    /// One row of the sidebar. A pair rather than a string, so a buffer named like a
    /// network cannot select the wrong file.
    private struct Row: Hashable {
        let network: String
        let buffer: String
    }

    private var selection: Binding<Row?> {
        Binding(
            get: {
                guard let network, let buffer else { return nil }
                return Row(network: network, buffer: buffer)
            },
            set: { row in
                network = row?.network
                buffer = row?.buffer
                loadLines()
            }
        )
    }

    private func load() {
        networks = log.networks()
        // Opened by `Find in Log…`, it starts on what ⌘F was looking for — the second scope
        // picks up where the first one gave up rather than asking for it again.
        if let query = presentation.query, !query.isEmpty { filter = query }
        // Opened from a buffer's own menu, it starts on that buffer's log — which is the
        // whole reason the presentation carries where it came from.
        if let wanted = presentation.network, networks.contains(wanted) {
            network = wanted
            if let buffer = presentation.buffer, log.buffers(in: wanted).contains(buffer) {
                self.buffer = buffer
            }
        }
        loadLines()
    }

    private func loadLines() {
        guard let network, let buffer else {
            lines = []
            return
        }
        lines = log.tail(Self.visibleLines, network: network, buffer: buffer)
    }
}
