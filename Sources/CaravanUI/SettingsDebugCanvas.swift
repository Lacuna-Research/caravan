import AppKit
import SwiftUI

/// The Debug & Settings canvas: the app's second kind of surface.
///
/// A canvas is not a chat buffer (GUI-DESIGN-NOTES.md §10). It has no header band, no
/// input box, no activity state and no place in buffer navigation — it replaces the chat
/// area while the tree stays visible, and selecting any buffer brings the chat area back.
/// The two halves are here together because they are the two things you open when
/// something is wrong: what the client is set to, and what it is actually saying.
struct SettingsDebugCanvas: View {
    let model: AppModel

    var body: some View {
        HSplitView {
            OptionsPane(model: model)
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 620)
            DebugPane(model: model)
                .frame(minWidth: 320)
        }
    }
}

// MARK: - Debug

/// The wire trace, live, and the controls `/debug` shares state with.
private struct DebugPane: View {
    let model: AppModel

    private var debug: DebugController { model.debug }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            ScrollbackView(log: debug.log)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(
                    "Streaming",
                    isOn: Binding(
                        get: { debug.isStreamingToCanvas },
                        set: { debug.setStreamingToCanvas($0) }
                    )
                )
                .toggleStyle(.switch)

                Button("Include earlier") {
                    _ = debug.apply(.toCanvas(includingExistingTrace: true))
                }
                .help("Add the traffic already in the ring buffer, from before now")

                Button("Clear") { debug.clearCanvas() }

                Spacer()

                if debug.fileURL == nil {
                    Button("Write to File…") { writeToFile() }
                } else {
                    Button("Stop Writing") { debug.closeFile() }
                }
            }

            Text(debug.report)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            // Said on the surface, not only in the source. A user pasting a debug log
            // into a bug report is trusting this sentence.
            Label(
                "Passwords are redacted before traffic is recorded, so the view above, "
                    + "the file and Copy Diagnostics all carry redacted text.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    /// A save panel rather than a text field, because this is the one place the app is
    /// asked to write somewhere the user chose. `/debug <file>` remains the typed route.
    private func writeToFile() {
        let panel = NSSavePanel()
        panel.title = "Write Debug Log"
        panel.nameFieldStringValue = "caravan-debug.log"
        panel.allowedContentTypes = [.plainText]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = debug.apply(.toFile(path: url.path, includingExistingTrace: true))
    }
}
