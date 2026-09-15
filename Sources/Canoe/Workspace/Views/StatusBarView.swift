import SwiftUI

/// Global status bar pinned to the bottom edge of the window, spanning the
/// full width across the sidebar and detail area.
///
/// The leading edge toggles the left sidebar. (The right-edge inspector
/// toggles live in the tab row now, next to the environment picker.)
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
