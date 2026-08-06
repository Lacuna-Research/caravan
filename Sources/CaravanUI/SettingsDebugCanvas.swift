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
            SettingsPane(model: model)
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            DebugPane(model: model)
                .frame(minWidth: 320)
        }
    }
}

// MARK: - Settings

/// The settings that exist by now, as a plain form.
///
/// Deliberately not a tabbed mIRC options dialog — that is stage 2's Options item, and it
/// builds on this surface rather than replacing it. Every control here writes straight
/// through to the plain-text config; there is no Apply button, and nothing to cancel.
private struct SettingsPane: View {
    let model: AppModel

    @Bindable private var settings: ChatSettings

    init(model: AppModel) {
        self.model = model
        self._settings = Bindable(wrappedValue: model.settings)
    }

    var body: some View {
        Form {
            Section("Font") {
                Picker("Chat font", selection: $settings.fontFamily) {
                    ForEach(ChatFont.selectableFamilies(including: settings.fontFamily), id: \.self)
                    { family in
                        Text(family).tag(family)
                    }
                }
                .onChange(of: settings.fontFamily) { model.applySettings() }

                LabeledContent("Size") {
                    Stepper(
                        value: $settings.fontSize,
                        in: ChatSettings.fontSizeRange,
                        step: 1
                    ) {
                        Text(settings.fontSize, format: .number.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .onChange(of: settings.fontSize) { model.applySettings() }
                }
                Text(
                    "Menlo is the default because it carries the whole CP437 art set at "
                        + "one cell wide. Other faces may substitute glyphs and break art."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Messages") {
                TextField("Timestamp format", text: $settings.timestampFormat)
                LabeledContent("Preview") {
                    Text(timestampPreview)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                Text("A date pattern such as [HH:mm:ss]. Leave it empty for no timestamps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Scrollback lines") {
                    TextField(
                        "Scrollback lines",
                        value: $settings.scrollbackLines,
                        format: .number.grouping(.never)
                    )
                    .labelsHidden()
                    .frame(width: 90)
                }
                .onChange(of: settings.scrollbackLines) { model.applySettings() }
                Toggle(
                    "Show raw wire traffic in the status window",
                    isOn: $settings.showsRawTraffic
                )
            }

            Section("Where these live") {
                LabeledContent("Config file") {
                    Button(model.config.url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.config.url])
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help("Reveal in Finder")
                }
                Text(
                    "Plain text, and safe to edit by hand. Passwords are never written "
                        + "here — they go to the Keychain, and until that exists they are "
                        + "asked for each time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The format applied to a real date, so a typo is visible before it reaches every
    /// line of every buffer.
    private var timestampPreview: String {
        let rendered = settings.renderer.timestampPreview()
        return rendered.isEmpty ? "(no timestamps)" : rendered
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
