import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store
    /// Whether the tab-row environment dropdown panel is open. The panel
    /// itself floats at window level (see `envPickerOverlay`): hanging it
    /// off the tab strip clips it where it overflows the strip bounds.
    @State private var isEnvPickerShown = false
    @State private var envPickerAnchor: Anchor<CGRect>?
    /// Whether the tab-row drawer is open. Owned here like the environment
    /// panel: the drawer floats at window level too (see `tabDrawerOverlay`).
    @State private var isTabDrawerShown = false
    @State private var tabDrawerAnchor: Anchor<CGRect>?
    /// Whether the request editor's method dropdown is open. Owned here for
    /// the same reason as the environment panel: hanging it off the editor
    /// clips it where it overflows the pane into the response viewer below
    /// (see `methodMenuOverlay`).
    @State private var isMethodMenuShown = false
    @State private var methodMenuAnchor: Anchor<CGRect>?
    /// Pick from the window-level method dropdown, handed down to the
    /// editor's draft (the panel can't reach the draft itself).
    @State private var pendingMethodPick: HTTPMethod?
    /// Keeps the splash up long enough to perceive even when the vault
    /// loads instantly from the local disk.
    @State private var splashElapsed = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.vault.isReady {
                // zIndex: the workspace switcher's hover card hangs below
                // the bar, over the panes underneath - later siblings draw
                // last, so without this the card is painted over the moment
                // it leaves the bar's own bounds.
                TopBarView()
                    .zIndex(1)
                Divider()
            }
            Group {
                if !store.vault.isReady || !splashElapsed {
                    VaultLoadingView()
                        .task {
                            try? await Task.sleep(for: .milliseconds(500))
                            splashElapsed = true
                        }
                } else if let loadError = store.vault.loadError {
                    VaultErrorView(message: loadError)
                } else if store.vault.workspaces.isEmpty {
                    WelcomeView()
                } else if store.activeWorkspace == nil {
                    WorkspacesView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mainLayout
                }
            }
            if store.vault.isReady && store.activeWorkspace != nil {
                Divider()
                StatusBarView()
            }
        }
        .sheet(isPresented: $store.presentNewWorkspace) {
            NewWorkspaceView()
        }
        // File ▸ Clear History: same confirmation the sidebar's Clear button
        // stages. The menu command has no view of its own, so the dialog is
        // hosted here - outside the layout branches below, so it survives
        // the switch to the welcome / workspaces-manager screens too.
        .confirmationDialog(
            "Clear all history",
            isPresented: $store.presentClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
        // The window runs full-size-content (the top bar replaces the system
        // title bar), so the hosting view reports the titlebar as a top safe
        // area inset - ignore it or the bar sinks 32pt below the traffic
        // lights, leaving a bare window-background band above it.
        .ignoresSafeArea()
        // Disable SwiftUI's own focus chrome at the window root (cascades
        // to descendants). AppKit's one-frame system focus ring on the
        // shared field editor is handled separately by AppKitFocusRing.
        .focusEffectDisabled()
        .overlay { tabDrawerOverlay }
        .overlay { envPickerOverlay }
        .overlay { methodMenuOverlay }
        .onPreferenceChange(EnvPickerAnchorKey.self) { envPickerAnchor = $0 }
        .onPreferenceChange(TabDrawerAnchorKey.self) { tabDrawerAnchor = $0 }
        .onPreferenceChange(MethodMenuAnchorKey.self) { methodMenuAnchor = $0 }
    }

    /// Postman-style environment dropdown: no popover bubble or arrow, just
    /// the bordered card directly below the tab-row picker button,
    /// trailing-edge aligned. Window-level so nothing clips it.
    private var envPickerOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // The anchor guard keeps a stale "open" flag from leaving an
                // invisible backdrop swallowing clicks after the picker button
                // has unmounted and cleared the preference (switching to the
                // workspaces manager tears the tab row down).
                if isEnvPickerShown, envPickerAnchor != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isEnvPickerShown = false }
                    Button("Close Environment Picker") { isEnvPickerShown = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                    if let anchor = envPickerAnchor {
                        let button = proxy[anchor]
                        EnvironmentPickerPanel(onDismiss: { isEnvPickerShown = false })
                            .offset(
                                x: button.maxX - EnvironmentPickerPanel.width,
                                y: button.maxY + AppSpacing.xSmall)
                    }
                }
            }
        }
    }

    /// Tab drawer: same window-level card hosting as the environment
    /// dropdown (see `envPickerOverlay`) with the same anchor rule: the
    /// card's trailing edge meets the trigger button's trailing edge and
    /// the card hangs left. Where the window is too narrow to fit the full
    /// 360pt left of the button, the card shrinks to the space available
    /// (120pt floor) so the alignment stays exact.
    private var tabDrawerOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Anchor guard, same reason as the environment dropdown above.
                if isTabDrawerShown, tabDrawerAnchor != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isTabDrawerShown = false }
                    Button("Close Tab Drawer") { isTabDrawerShown = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                    if let anchor = tabDrawerAnchor {
                        let button = proxy[anchor]
                        let cardWidth = min(AppSize.tabSearchWidth, max(button.maxX, 120))
                        TabDrawer(onDismiss: { isTabDrawerShown = false })
                            .frame(width: cardWidth)
                            .offset(
                                x: max(button.maxX - cardWidth, 0),
                                y: button.maxY + AppSpacing.xSmall)
                    }
                }
            }
        }
    }

    /// Postman-style method dropdown, window-level like `envPickerOverlay`:
    /// the card hangs below the URL bar row, left-aligned with the method
    /// picker (the row's resolved leading edge). The highlight follows the
    /// store's copy of the method - `updateRequest` mirrors every draft
    /// change there, so it is the same value the editor shows.
    private var methodMenuOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // The anchor guard keeps a stale "open" flag from leaving an
                // invisible backdrop swallowing clicks after the editor's
                // unmount has cleared the preference.
                if isMethodMenuShown, methodMenuAnchor != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isMethodMenuShown = false }
                    Button("Close Method Menu") { isMethodMenuShown = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                    if let anchor = methodMenuAnchor {
                        let row = proxy[anchor]
                        MethodMenuPanel(
                            selectedMethod: store.selectedRequest?.httpMethod ?? .get,
                            onPick: { method in
                                pendingMethodPick = method
                                isMethodMenuShown = false
                            },
                            onDismiss: { isMethodMenuShown = false }
                        )
                        .offset(x: row.minX, y: row.maxY + AppSpacing.xSmall)
                    }
                }
            }
        }
    }

    private var mainLayout: some View {
        // Plain HSplitView instead of NavigationSplitView: the latter injects
        // an unremovable sidebar toggle into the window toolbar. The
        // "Variables in Request" inspector sits OUTSIDE the split view as a
        // manually-resized HStack pane - a conditionally-presented HSplitView
        // pane breaks the split view's sizing and collapses the whole layout
        // to its ideal height.
        HStack(spacing: 0) {
            HSplitView {
                SidebarView()
                    .frame(
                        minWidth: store.showSidebar ? AppSize.sidebarMinWidth : 0,
                        idealWidth: store.showSidebar ? AppSize.sidebarIdealWidth : 0,
                        maxWidth: store.showSidebar ? AppSize.sidebarMaxWidth : 0
                    )
                    .clipped()
                VStack(spacing: 0) {
                    // Corrupt files are skipped per-file on load: say so here
                    // instead of letting collections silently vanish. The
                    // files stay on disk for manual recovery.
                    if store.vault.loadError == nil, store.vault.corruptFileCount > 0 {
                        corruptFilesBanner
                        Divider()
                    }
                    detailPane
                }
            }
            if store.showVariablesSidebar {
                Divider()
                VariablesSidebarView()
                    .frame(width: store.inspectorWidth)
                    .overlay(alignment: .leading) { inspectorResizeHandle }
            } else if store.showCodeSnippetSidebar {
                Divider()
                CodeSnippetSidebarView()
                    .frame(width: store.inspectorWidth)
                    .overlay(alignment: .leading) { inspectorResizeHandle }
            }
        }
    }

    /// Drag handle on the inspector's leading edge: the shared pane
    /// splitter (see `PaneResizeHandle`), sized by `inspectorWidth`.
    private var inspectorResizeHandle: some View {
        PaneResizeHandle(
            axis: .horizontal,
            range: AppSize.inspectorMinWidth...AppSize.inspectorMaxWidth,
            defaultLength: AppSize.inspectorWidth,
            length: Binding(
                get: { store.inspectorWidth },
                set: { store.inspectorWidth = $0 }
            ),
            onCommit: { store.saveInspectorWidth() }
        )
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            // The strip is chrome, not content: it stays put with an empty
            // tab set, so the "+" (and the environment picker plus the
            // inspector toggles living in the same row) keep their place
            // instead of the whole row appearing only once a tab is open.
            TabBarView(
                isDrawerShown: $isTabDrawerShown,
                isEnvPickerShown: $isEnvPickerShown
            )
            Divider()
            detailContent
            // Postman-style docked console, at the bottom of the whole
            // detail area rather than inside the request workspace: it
            // logs the session, not one request, so it stays available (and
            // keeps its log) whatever the detail pane above is showing -
            // an environment editor, a collection page, or nothing at all.
            if store.showConsole {
                Divider()
                ConsoleView()
                    .frame(height: store.consoleHeight)
                    .overlay(alignment: .top) { consoleResizeHandle }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Drag handle on the console's top edge: the shared pane splitter
    /// (see `PaneResizeHandle`), sized by `consoleHeight`.
    private var consoleResizeHandle: some View {
        PaneResizeHandle(
            axis: .vertical,
            range: AppSize.consoleMinHeight...AppSize.consoleMaxHeight,
            defaultLength: AppSize.consoleDefaultHeight,
            length: Binding(
                get: { store.consoleHeight },
                set: { store.consoleHeight = $0 }
            ),
            onCommit: { store.saveConsoleHeight() }
        )
    }

    /// Warning shown when per-file skips happened on load: names the count
    /// so missing collections read as known damage, not mystery.
    private var corruptFilesBanner: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColor.warning)
            Text(corruptFilesMessage)
                .font(AppFont.emptyStateBody)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            LinkButton("Reveal Vault") { store.vault.revealInFinder() }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .background(AppColor.warning.opacity(AppOpacity.errorBackground))
    }

    private var corruptFilesMessage: String {
        if store.vault.corruptFileCount == 1 {
            let name = store.vault.corruptFileNames.first ?? "unknown"
            return "1 vault file could not be read and was skipped (\(name)). It is still on disk."
        }
        return
            "\(store.vault.corruptFileCount) vault files could not be read and were skipped. They are still on disk."
    }

    @ViewBuilder
    private var detailContent: some View {
        if let request = store.selectedRequest {
            RequestWorkspaceView(
                request: request,
                isMethodMenuShown: $isMethodMenuShown,
                pendingMethodPick: $pendingMethodPick
            )
        } else if let env = store.selectedEnvironmentTab {
            EnvironmentDetailView(environment: env)
                .id(env.id)
        } else if let collection = store.selectedCollectionTab {
            CollectionDetailView(collection: collection)
                .id(collection.id)
        } else if let folder = store.selectedFolderTab {
            FolderDetailView(folder: folder)
                .id(folder.id)
        } else if let workspace = store.selectedWorkspaceTab {
            WorkspaceOverviewView(workspace: workspace)
                .id(workspace.id)
        } else if let workspace = store.selectedWorkspaceVariablesTab {
            WorkspaceVariablesView(workspace: workspace)
                .id(workspace.id)
        } else {
            EmptyStateView()
        }
    }
}

/// Splits the detail area into a request editor (top) and response viewer
/// (bottom), like the classic Postman layout. The console is NOT here - it
/// is docked below this whole pane (see ContentView), so it survives any
/// change of context.
struct RequestWorkspaceView: View {
    @Environment(AppStore.self) private var store
    let request: Request
    /// Passed through to the editor; the dropdown panel itself lives at
    /// window level in ContentView (see `methodMenuOverlay`).
    @Binding var isMethodMenuShown: Bool
    @Binding var pendingMethodPick: HTTPMethod?

    var body: some View {
        VSplitView {
            RequestEditorView(
                request: request,
                isMethodMenuVisible: $isMethodMenuShown,
                pendingMethodPick: $pendingMethodPick
            )
            .frame(minHeight: 240)
            ResponseViewerView()
                .frame(minHeight: 200)
        }
        // VSplitView otherwise collapses to its panes' ideal heights, and a
        // section switch to fixed-height content (e.g. the GET "No Body"
        // hint) shrinks the whole detail layout - the outer VStack then
        // centers it, leaving blank bands above/below. Pin it to fill.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when a workspace exists but no request is selected.
struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            CanoeMarkView(size: 56)

            VStack(spacing: AppSpacing.small) {
                Text("No Request Selected")
                    .font(.title2.weight(.semibold))
                Text("Select a request from the sidebar, or create a new one to get started.")
                    .font(AppFont.emptyStateBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button {
                store.addRequest()
            } label: {
                Label("New Request", systemImage: "plus")
            }
            .buttonStyle(SendButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-window error shown when the vault itself fails to load: previously
/// this state fell through to the welcome screen, inviting the user to create
/// a workspace whose saves would then silently no-op.
private struct VaultErrorView: View {
    @Environment(AppStore.self) private var store
    let message: String
    @State private var isRetrying = false

    var body: some View {
        ContentUnavailableView(
            "Could Not Load Vault",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            HStack(spacing: AppSpacing.medium) {
                Button(isRetrying ? "Retrying…" : "Retry") {
                    isRetrying = true
                    Task {
                        await store.retryVaultLoad()
                        isRetrying = false
                    }
                }
                .buttonStyle(SendButtonStyle())
                .disabled(isRetrying)
                LinkButton("Reveal Vault in Finder") { store.vault.revealInFinder() }
            }
            .padding(.bottom, AppSpacing.xLarge)
        }
    }
}

/// Brief splash while the vault is being located and loaded. Mark and
/// spinner share one centered stack - `LoadingState` stretches with
/// `maxHeight: .infinity`, which would pin the mark under the title bar.
private struct VaultLoadingView: View {
    var body: some View {
        VStack(spacing: AppSpacing.xLarge) {
            CanoeMarkView(size: 96, showsShadow: true)
            VStack(spacing: AppSpacing.small) {
                ProgressView()
                Text("Loading vault…")
                    .font(AppFont.emptyStateBody)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
