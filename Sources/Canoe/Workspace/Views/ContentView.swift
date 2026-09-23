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
    /// Inspector width at drag start; the drag applies deltas against it.
    @State private var inspectorDragStartWidth: CGFloat?
    /// Keeps the splash up long enough to perceive even when the vault
    /// loads instantly from the local disk.
    @State private var splashElapsed = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.vault.isReady {
                TopBarView()
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
        .onPreferenceChange(EnvPickerAnchorKey.self) { envPickerAnchor = $0 }
        .onPreferenceChange(TabDrawerAnchorKey.self) { tabDrawerAnchor = $0 }
    }

    /// Postman-style environment dropdown: no popover bubble or arrow, just
    /// the bordered card directly below the tab-row picker button,
    /// trailing-edge aligned. Window-level so nothing clips it.
    private var envPickerOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if isEnvPickerShown {
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
                if isTabDrawerShown {
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

    /// Drag handle on the inspector's leading edge (VSCode-style splitter):
    /// drag to resize between the min/max widths, double-click to reset to
    /// the default. The inspector sits outside the HSplitView (a
    /// conditionally-presented split pane breaks its sizing), so the
    /// splitter is manual.
    private var inspectorResizeHandle: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                // Global coordinates on purpose: the handle itself moves
                // with the width it controls, so a local-space translation
                // feeds back into the layout and oscillates (the tab strip
                // and the trailing toggles jitter). Global space keeps the
                // delta a pure function of the pointer.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if inspectorDragStartWidth == nil {
                            inspectorDragStartWidth = store.inspectorWidth
                        }
                        let start = inspectorDragStartWidth ?? store.inspectorWidth
                        store.inspectorWidth = min(
                            max(start - value.translation.width, AppSize.inspectorMinWidth),
                            AppSize.inspectorMaxWidth
                        )
                    }
                    .onEnded { _ in
                        inspectorDragStartWidth = nil
                        store.saveInspectorWidth()
                    }
            )
            .onTapGesture(count: 2) {
                store.inspectorWidth = AppSize.inspectorWidth
                store.saveInspectorWidth()
            }
            .help("Drag to resize the inspector (double-click to reset)")
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if !store.openTabs.isEmpty {
                TabBarView(
                    isDrawerShown: $isTabDrawerShown,
                    isEnvPickerShown: $isEnvPickerShown
                )
                Divider()
            }
            detailContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            RequestWorkspaceView(request: request)
        } else if let env = store.selectedEnvironmentTab {
            EnvironmentDetailView(environment: env)
                .id(env.id)
        } else if let collection = store.selectedCollectionTab {
            CollectionDetailView(collection: collection)
                .id(collection.id)
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
/// (bottom), like the classic Postman layout.
struct RequestWorkspaceView: View {
    @Environment(AppStore.self) private var store
    let request: Request

    var body: some View {
        VSplitView {
            RequestEditorView(request: request)
                .frame(minHeight: 240)
            ResponseViewerView()
                .frame(minHeight: 200)
            // Postman-style docked console: opens below the Response pane.
            if store.showConsole {
                ConsoleView()
                    .frame(minHeight: 150, idealHeight: 220)
            }
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
