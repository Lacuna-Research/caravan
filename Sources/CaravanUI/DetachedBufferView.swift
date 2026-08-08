import SwiftUI

/// One buffer, in a window of its own (§1, §10).
///
/// **No tree.** Detaching is "put this buffer in its own window", not "open a second copy
/// of the app" — §1 keeps the single sidebar-driven window as the primary metaphor, and a
/// second tree would be a second place for the selection to live and a second answer to
/// "where am I".
///
/// The same view bodies the main window's detail pane uses, so a detached channel is not a
/// second implementation of a channel window that can drift from the first.
public struct DetachedBufferView: View {
    let model: AppModel
    let item: AppModel.SidebarItem

    public init(model: AppModel, item: AppModel.SidebarItem) {
        self.model = model
        self.item = item
    }

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        content
            .environment(
                \.chatFont,
                model.settings.chatFont
            )
            .navigationTitle(model.title(of: item))
            .navigationSubtitle(model.subtitle(of: item))
            .frame(minWidth: 420, minHeight: 260)
            // Which window ⌘W and the activity rules are talking about.
            .onChange(of: activeState, initial: true) { _, state in
                if state == .key { model.keyWindow = .detached(item) }
            }
            .onAppear(perform: adopt)
            // The catcher opens as a sheet on the window it was asked for from. A single
            // `isShowing` flag would put it on the main window, quite possibly behind this
            // one, when the link that prompted it was in this buffer.
            .urlCatcher(model: model, in: .detached(item))
            .logViewer(model: model, in: .detached(item))
            // **Closing the window is reattaching.** A buffer that lived in neither place
            // would be a buffer you could no longer reach — so the red button is not a
            // second, destructive meaning of "close", it is the inverse of detaching.
            .onDisappear {
                model.reattach(item, selecting: false)
                if model.keyWindow == .detached(item) { model.keyWindow = .main }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.reattach(item)
                        dismiss()
                    } label: {
                        Label("Reattach", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Put this buffer back in the main window")
                }
            }
    }

    /// Reconciles a window that macOS restored with a model that knows nothing about it.
    ///
    /// **Window restoration outlives the thing a window points at.** A detached buffer
    /// names a connection whose identity lasts one run, so a restored window always names
    /// a network that no longer exists — the live run watched last session's
    /// `##caravan-win-a` come back on a launch that had not connected to anything, showing
    /// the "buffer closed" placeholder. Neither `defaultLaunchBehavior(.suppressed)` nor
    /// `restorationBehavior(.disabled)` stopped it.
    ///
    /// So restoration is made harmless rather than fought: a window onto a network this
    /// run has never heard of closes itself, and one onto something real — the canvas,
    /// which belongs to no connection — tells the model it is detached, so the two do not
    /// disagree about where the buffer is.
    private func adopt() {
        if let connectionID = item.connectionID, model.connection(id: connectionID) == nil {
            dismiss()
            return
        }
        if !model.isDetached(item) { model.detach(item) }
    }

    @ViewBuilder
    private var content: some View {
        // **This window's connection, resolved from its own row.** Not `activeConnection`,
        // which is the tree's selection: a detached channel on one network with the main
        // window pointed at another used to send its input to the wrong server entirely.
        let connection = item.connectionID.flatMap(model.connection(id:))
        switch item {
        case .settingsAndDebug:
            SettingsDebugCanvas(model: model)
        case .dashboard:
            DashboardCanvas(model: model)
        case .status:
            if let connection {
                StatusBufferView(model: model, connection: connection, window: .detached(item))
            } else {
                closedPlaceholder
            }
        case .channel:
            if let connection, let buffer = model.buffer(for: item) as? ChannelBuffer {
                ChannelBufferView(
                    model: model,
                    connection: connection,
                    buffer: buffer,
                    window: .detached(item)
                )
            } else {
                closedPlaceholder
            }
        case .query:
            if let connection, let buffer = model.buffer(for: item) as? QueryBuffer {
                QueryBufferView(
                    model: model,
                    connection: connection,
                    buffer: buffer,
                    window: .detached(item)
                )
            } else {
                closedPlaceholder
            }
        }
    }

    /// The buffer went away underneath the window — the network was closed, or the channel
    /// buffer was. Said out loud rather than left as an empty window, which reads as a bug.
    private var closedPlaceholder: some View {
        ContentUnavailableView {
            Label("Buffer closed", systemImage: "rectangle.slash")
        } description: {
            Text("This buffer is no longer open.")
        }
    }
}

extension AppModel {
    /// What a row is called, for a window title. Shared by both windows so they cannot
    /// disagree about what a buffer is named.
    public func title(of item: SidebarItem) -> String {
        switch item {
        case .settingsAndDebug: "Settings & Debug"
        case .dashboard: "Dashboard"
        case .status(let id): connection(id: id)?.treeName ?? "Caravan"
        case .channel(_, let name): name.raw
        case .query(_, let nick): nick.raw
        }
    }

    /// The network a row belongs to — the "always say which network" rule the tree follows,
    /// since `#music` on two networks are different rooms (§12).
    public func subtitle(of item: SidebarItem) -> String {
        switch item {
        case .settingsAndDebug, .dashboard:
            ""
        case .status(let id):
            connection(id: id)?.statusSummary ?? ""
        case .channel(let id, _), .query(let id, _):
            connection(id: id)?.treeName ?? ""
        }
    }
}
