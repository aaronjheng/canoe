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
            StatusToggleButton(
                systemImage: "sidebar.left",
                isOn: store.showSidebar,
                help: store.showSidebar ? "Hide Sidebar" : "Show Sidebar"
            ) {
                store.showSidebar.toggle()
            }
            // Console entry sits with the left-edge toggles, right of the
            // sidebar switch (Postman keeps its console toggle in the
            // bottom bar too): docks the network log below the Response pane.
            StatusToggleButton(
                systemImage: "terminal",
                isOn: store.showConsole,
                help: store.showConsole ? "Hide Console" : "Show Console"
            ) {
                store.toggleConsole()
            }
            Spacer(minLength: 0)
            // Symmetric counterpart on the trailing edge: shows/hides the
            // right-edge inspector (Variables or Code Snippet).
            StatusToggleButton(
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

/// Small panel toggle button: dimmed when the panel is hidden, highlighted
/// while it is open. Same 26pt square and hover language as the tab-row
/// inspector toggles.
private struct StatusToggleButton: View {
    let systemImage: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(isOn ? AppColor.accent : .secondary)
                .frame(width: AppSize.topBarControlHeight, height: AppSize.topBarControlHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(
                            isOn
                                ? AppColor.tabActiveBackground
                                : (isHovering ? AppColor.tabHoverBackground : .clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
