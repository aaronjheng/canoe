import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.vault.isReady {
                TopBarView()
                Divider()
            }
            Group {
                if !store.vault.isReady {
                    VaultLoadingView()
                } else if store.vault.workspaces.isEmpty {
                    WelcomeView()
                } else {
                    mainLayout
                }
            }
            if store.vault.isReady {
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
    }

    private var mainLayout: some View {
        // Plain HSplitView instead of NavigationSplitView: the latter injects
        // an unremovable sidebar toggle into the window toolbar. The
        // "Variables in Request" inspector sits OUTSIDE the split view as a
        // fixed-width HStack pane - a conditionally-presented HSplitView pane
        // breaks the split view's sizing and collapses the whole layout to
        // its ideal height.
        HStack(spacing: 0) {
            HSplitView {
                SidebarView()
                    .frame(
                        minWidth: store.showSidebar ? AppSize.sidebarMinWidth : 0,
                        idealWidth: store.showSidebar ? AppSize.sidebarIdealWidth : 0,
                        maxWidth: store.showSidebar ? AppSize.sidebarMaxWidth : 0
                    )
                    .clipped()
                detailPane
            }
            if store.showVariablesSidebar {
                Divider()
                VariablesSidebarView()
                    .frame(width: AppSize.inspectorWidth)
            } else if store.showCodeSnippetSidebar {
                Divider()
                CodeSnippetSidebarView()
                    .frame(width: AppSize.inspectorWidth)
            }
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if !store.openTabs.isEmpty {
                TabBarView()
                Divider()
            }
            detailContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            WorkspaceDetailView(workspace: workspace)
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
    let request: RequestItem

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
                    .font(.callout)
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

/// Brief splash while the vault is being located and loaded.
private struct VaultLoadingView: View {
    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            CanoeMarkView(size: 64)
            LoadingState(message: "Loading vault…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
