import AppKit
import IRCFormat
import SwiftUI

/// mIRC's tabbed options, on the Settings & Debug canvas rather than in a window (§10).
///
/// **Two properties of the form this replaces are requirements, not accidents**, and every
/// control here keeps them:
///
/// - **Write straight through.** There is no Apply button, nothing to cancel and no pending
///   state, because pending state is a second copy of the settings that can disagree with
///   the first. A control's `didSet` on `ChatSettings` is the whole persistence story.
/// - **The file survives being hand-edited.** `ConfigFile.set` rewrites the one line it
///   owns and passes comments, blank lines and unknown keys through untouched. A tab that
///   rewrote the file wholesale would be a regression, and `ConfigFileTests` has a test
///   that would notice.
///
/// **A tab exists when it has something in it.** mIRC has eight; Sounds is prompt 13b's,
/// and shipping it empty would teach the user the client is unfinished rather than that the
/// feature is coming. Adding one is a case below plus a pane — the enum is `CaseIterable`
/// and drives the picker.
struct OptionsPane: View {
    let model: AppModel

    @Bindable private var settings: ChatSettings

    @State private var tab: Tab = .display

    init(model: AppModel) {
        self.model = model
        self._settings = Bindable(wrappedValue: model.settings)
    }

    /// **A segmented picker rather than a second sidebar**, matching `ChannelModesSheet`.
    /// It stops scaling somewhere around seven tabs; that is the point to reconsider, not
    /// before.
    enum Tab: String, CaseIterable, Identifiable {
        case connect = "Connect"
        case irc = "IRC"
        case display = "Display"
        case colours = "Colours"
        case logging = "Logging"
        case other = "Other"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch tab {
            case .connect: ConnectOptions(model: model)
            case .irc: IRCOptions(settings: settings)
            case .display: DisplayOptions(model: model, settings: settings)
            case .colours: ColourOptions(model: model, settings: settings)
            case .logging: LoggingOptions(model: model, settings: settings)
            case .other: OtherOptions(model: model)
            }
        }
    }
}

// MARK: - Connect

/// Identity, and the certificates we have been told to trust.
///
/// **Identity only — not servers.** Which servers exist, their passwords and their SASL
/// method are per-server and belong with the server list (prompt 11); a nickname is global
/// and belongs here. Splitting on that line is what stops the two surfaces both claiming
/// the same settings.
private struct ConnectOptions: View {
    let model: AppModel

    @State private var identity = ConnectionSettings.lastUsed()
    @State private var hosts: [KnownHosts.Entry] = []

    var body: some View {
        Form {
            Section("Identity") {
                field("Nickname", text: $identity.nick)
                field("Alternate", text: $identity.altNick)
                field("Ident", text: $identity.ident)
                field("Real name", text: $identity.realName)
                Text(
                    "Who you are on every network. A server that already has your "
                        + "nickname gets the alternate instead."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Trusted certificates") {
                if hosts.isEmpty {
                    Text("No certificates have been accepted by hand.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hosts, id: \.host) { entry in
                        LabeledContent(entry.host) {
                            HStack(spacing: 8) {
                                Text(entry.fingerprint)
                                    .font(.caption)
                                    .monospaced()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Button("Forget") { forget(entry.host) }
                            }
                        }
                    }
                }
                Text(
                    "A server whose certificate the system would not validate, that you "
                        + "accepted anyway. Forgetting one means being asked again the "
                        + "next time you connect — which is what you want if you accepted "
                        + "the wrong one."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hosts = model.knownHosts.accepted() }
    }

    /// Written on every keystroke, like every other control here. `rememberAsLastUsed`
    /// would also touch the Keychain, which identity has no business doing.
    private func field(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .onChange(of: text.wrappedValue) { identity.rememberIdentity(in: model.config) }
    }

    private func forget(_ host: String) {
        model.knownHosts.forget(host)
        hosts = model.knownHosts.accepted()
    }
}

// MARK: - IRC

/// How the client behaves in a conversation, rather than how it looks.
private struct IRCOptions: View {
    @Bindable var settings: ChatSettings

    var body: some View {
        Form {
            Section("Typing") {
                // `labelsHidden()` is load-bearing, not decoration: without it the field's
                // own placeholder is drawn as a second label inside a 70pt box and wraps
                // one word per line, which is what a live run found.
                suffixField("After a nickname at the start", \.atLineStart)
                suffixField("After a nickname elsewhere", \.elsewhere)
                Text(
                    "What Tab puts after a completed nickname. A nickname opening a line "
                        + "is an address, so it takes the first; one inside a sentence "
                        + "takes the second. In the config file a space is written `_`."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Toggle(
                    "Show raw wire traffic in the status window",
                    isOn: $settings.showsRawTraffic
                )
                Text(
                    "Both directions, marked `>>` and `<<`. Starts from the moment you "
                        + "turn it on; `/debug -i` is what reaches back for what came "
                        + "before."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func suffixField(
        _ label: String,
        _ path: WritableKeyPath<CompletionStyle, String>
    ) -> some View {
        LabeledContent(label) {
            TextField(
                "suffix",
                text: Binding(
                    get: { settings.completionSuffix[keyPath: path] },
                    set: { settings.completionSuffix[keyPath: path] = $0 }
                )
            )
            .labelsHidden()
            // Bordered, unlike the other fields here, because a suffix is often a single
            // space — an unbordered field holding one looks like no field.
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
        }
    }
}

// MARK: - Display

/// Font, density, zoom, timestamps and how much scrollback is kept.
private struct DisplayOptions: View {
    let model: AppModel
    @Bindable var settings: ChatSettings

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
                    Stepper(value: $settings.fontSize, in: ChatSettings.fontSizeRange, step: 1) {
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

            Section("Density") {
                Picker("Line height", selection: $settings.density) {
                    ForEach(ChatSettings.Density.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.density) { model.applySettings() }
                // Plain prose, not markdown: these captions are built by concatenating
                // string literals, which makes them a `String` rather than a
                // `LocalizedStringKey`, so SwiftUI draws any `**` verbatim. The live run
                // found this one wearing its asterisks.
                Text(
                    "Density is line height, not size. mIRC's tightness came from "
                        + "near-zero leading rather than small text, so these open the "
                        + "lines up without touching the font — and they are multipliers, "
                        + "so asking for large text keeps it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Zoom") {
                LabeledContent("Zoom") {
                    HStack(spacing: 8) {
                        Text(settings.zoom, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                        Button("Actual Size") { model.resetZoom() }
                            .disabled(settings.zoom == ChatSettings.Default.zoom)
                    }
                }
                Text(
                    "One zoom for every window, over whatever size you chose above. "
                        + "\u{2318}+ and \u{2318}\u{2212} step it; \u{2325}\u{2318}0 is "
                        + "actual size, because \u{2318}0 opens this canvas."
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

// MARK: - Colours

/// The palette, nick colouring, and the sixteen indices a user may retune.
private struct ColourOptions: View {
    let model: AppModel
    @Bindable var settings: ChatSettings

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8)

    var body: some View {
        Form {
            Section("Palette") {
                Picker("Palette", selection: $settings.paletteMode) {
                    ForEach(Palette.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.paletteMode) { model.applySettings() }
                Text(
                    "Which of the two 16-colour tables a sender's colour codes read. The "
                        + "dark one is a full alternate palette, not white and black "
                        + "swapped — the other fourteen are tuned for a white background "
                        + "too. Auto follows the system."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Toggle("Colour nicknames", isOn: $settings.coloursNicks)
                    .onChange(of: settings.coloursNicks) { model.applySettings() }
                Text(
                    "A colour per nickname, from the name alone — so somebody looks the "
                        + "same on every network you reach them on. Only where there is a "
                        + "nickname column: names inside a join or a quit stay the "
                        + "line's colour."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Colours 0–15") {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(ChatSettings.overridableColours), id: \.self) { index in
                        ColourSwatch(index: index, model: model, settings: settings)
                    }
                }
                .padding(.vertical, 4)

                // **Sixteen, not ninety-nine.** §5 puts overrides on top of the two
                // 16-colour tables and leaves 16–98 fixed by the specification, so those
                // are not the user's to retune.
                Text(
                    "Click a swatch to replace what a sender's colour code means here. "
                        + "Indices 16 to 98 are fixed by the specification and are not "
                        + "shown. Right-click a changed one to put it back."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !settings.colourOverrides.isEmpty {
                    Button("Reset All Colours") {
                        settings.colourOverrides = [:]
                        model.applySettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One index of the palette, as a well you can click.
///
/// Bound to a `Color` so macOS's own colour picker does the work. The binding reads the
/// *resolved* colour — the override if there is one, the table's value if not — so a
/// swatch always shows what a sender's code would actually draw.
private struct ColourSwatch: View {
    let index: Int
    let model: AppModel
    @Bindable var settings: ChatSettings

    var body: some View {
        ColorPicker(
            "Colour \(index)",
            selection: Binding(
                get: { Color(nsColor: resolved) },
                set: { store($0) }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .help(helpText)
        .contextMenu {
            Button("Reset Colour \(index)") {
                settings.colourOverrides[index] = nil
                model.applySettings()
            }
            .disabled(settings.colourOverrides[index] == nil)
        }
    }

    private var resolved: NSColor {
        settings.palette.swatch(at: index)
    }

    private var helpText: String {
        settings.colourOverrides[index] == nil
            ? "Colour \(index)" : "Colour \(index) — changed from the default"
    }

    /// Stores as `RGB`, which is what `Palette` and the config file both speak.
    ///
    /// Converted through sRGB deliberately: the picker can hand back a colour in any
    /// space, and `RGB` is eight bits per channel with no space of its own — the same
    /// thing the wire carries.
    private func store(_ colour: Color) {
        guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return }
        settings.colourOverrides[index] = RGB(
            UInt8(clamping: Int((srgb.redComponent * 255).rounded())),
            UInt8(clamping: Int((srgb.greenComponent * 255).rounded())),
            UInt8(clamping: Int((srgb.blueComponent * 255).rounded()))
        )
        model.applySettings()
    }
}

// MARK: - Logging

/// What gets written down, how much comes back, and where it all lives.
///
/// **The privacy sentence is on the surface, not only in the source.** Logging is on out of
/// the box for the two kinds of buffer that hold a conversation, which is a decision made
/// on the user's behalf about writing what they say to disk — so the pane says plainly what
/// is written, where, and that nothing sends it anywhere.
private struct LoggingOptions: View {
    let model: AppModel
    @Bindable var settings: ChatSettings

    var body: some View {
        Form {
            Section("What to log") {
                Toggle("Channels", isOn: $settings.logsChannels)
                Toggle("Private messages", isOn: $settings.logsQueries)
                Toggle("The status window", isOn: $settings.logsStatus)
                Text(
                    "Plain text, one file per window, in the folder below. Nothing is sent "
                        + "anywhere and nothing is written inside the app. Turning a "
                        + "toggle off stops new lines; it does not delete what is there."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Reload") {
                LabeledContent("Lines to put back") {
                    TextField(
                        "Lines to put back",
                        value: $settings.logReloadLines,
                        format: .number.grouping(.never)
                    )
                    .labelsHidden()
                    .frame(width: 90)
                }
                Text(
                    "How much of a window's log reappears, dimmed, when it opens — so a "
                        + "channel is not blank after a restart. Zero turns it off. Where "
                        + "the server sends its own history for the same period, the "
                        + "overlap is recognised and shown once."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Files") {
                LabeledContent("Log folder") {
                    Button(model.chatLog.directory.path) {
                        reveal(model.chatLog.directory)
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help("Reveal in Finder")
                }
                Button("Browse Logs\u{2026}") {
                    model.logViewerPresentation = AppModel.LogViewerPresentation(
                        window: .main,
                        network: nil,
                        buffer: nil
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Creates the folder on the way if it is not there yet: a Reveal button that does
    /// nothing because nothing has been logged reads as a broken button.
    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Other

/// Where the settings live, and how to get at them.
private struct OtherOptions: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Files") {
                LabeledContent("Config file") {
                    revealButton(model.config.url)
                }
                LabeledContent("Trusted certificates") {
                    revealButton(model.knownHosts.url)
                }
                Text(
                    "Plain text, and safe to edit by hand: this app rewrites only the "
                        + "lines it owns, so comments and anything it does not recognise "
                        + "survive. Passwords are never written here — they go to the "
                        + "Keychain."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func revealButton(_ url: URL) -> some View {
        Button(url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .buttonStyle(.link)
        .lineLimit(1)
        .truncationMode(.head)
        .help("Reveal in Finder")
    }
}
