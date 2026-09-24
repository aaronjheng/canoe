import SwiftUI

/// Workspace status bar pinned to the bottom edge of the window, spanning the
/// full width across the sidebar and detail area.
///
/// Workspace-only controls toggle the left sidebar and console at the
/// leading edge, and the right inspector at the trailing edge.
struct StatusBarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            ToolbarToggleButton(
                systemImage: "sidebar.left",
                isOn: store.showSidebar,
                help: store.showSidebar ? "Hide Sidebar" : "Show Sidebar"
            ) {
                store.showSidebar.toggle()
            }
            // Console entry sits with the left-edge toggles, right of the
            // sidebar switch (Postman keeps its console toggle in the
            // bottom bar too): docks the network log below the Response pane.
            ToolbarToggleButton(
                systemImage: "terminal",
                isOn: store.showConsole,
                help: store.showConsole ? "Hide Console" : "Show Console"
            ) {
                store.toggleConsole()
            }
            Spacer(minLength: 0)
            // Symmetric counterpart on the trailing edge: shows/hides the
            // right-edge inspector (Variables or Code Snippet).
            ToolbarToggleButton(
                systemImage: "sidebar.right",
                isOn: store.isRightSidebarVisible,
                help: store.isRightSidebarVisible ? "Hide Right Sidebar" : "Show Right Sidebar"
            ) {
                store.toggleRightSidebar()
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(height: AppSize.statusBarHeight)
        .background(AppColor.controlBackground)
    }
}

struct WorkspaceListStatusBarView: View {
    let workspaceCount: Int

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Text("Workspaces")
                .font(AppFont.small)
                .foregroundStyle(.secondary)
            Text("\(workspaceCount)")
                .font(AppFont.countBadge)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(height: AppSize.statusBarHeight)
        .background(AppColor.controlBackground)
    }
}
