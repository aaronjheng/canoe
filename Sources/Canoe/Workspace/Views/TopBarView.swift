import SwiftUI

/// Postman-style top bar spanning the full window width at the very top:
/// the window's traffic lights sit inline on it, the workspace switcher
/// follows them, and a settings shortcut sits at the trailing edge. The bar
/// draws a solid, opaque background on purpose - it replaces the system
/// title bar, and the macOS "liquid glass" chrome underneath it must never
/// show through. It shares the sidebar's fill so the left chrome (bar +
/// sidebar) reads as one continuous surface, separated from the content row
/// by the hairline under the bar.
struct TopBarView: View {
    /// macOS hides the traffic lights while fullscreen, so the gutter
    /// reserved for them would turn into dead blank space - track the
    /// fullscreen state and reclaim the inset there.
    @State private var isFullScreen = false

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            WorkspaceSwitcher()
            Spacer(minLength: 0)
            settingsButton
        }
        .padding(.leading, isFullScreen ? AppSpacing.medium : AppSize.trafficLightInset)
        .padding(.trailing, AppSpacing.medium)
        .frame(height: AppSize.topBarHeight)
        .background(AppColor.sidebarBackground)
        .background {
            // The bar replaces the title bar, so it takes over dragging:
            // empty regions move the window, controls keep their clicks.
            WindowDragArea()
        }
        .onAppear {
            // Covers relaunching straight into a restored fullscreen window,
            // where no enter/exit notification fires before the first layout.
            isFullScreen = NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        // On exit, the traffic lights fade back in as the animation STARTS,
        // so the gutter must be restored immediately - switching at the
        // finished transition (didExit) would leave the switcher sitting
        // under the lights for the whole exit animation.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    /// Shortcut for `Canoe -> Settings…`: same window, focused if open.
    private var settingsButton: some View {
        Button {
            (NSApp.delegate as? AppDelegate)?.openSettings()
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(ToolbarButtonStyle())
        .frame(width: AppSize.topBarControlHeight, height: AppSize.topBarControlHeight)
        .help("Settings (⌘,)")
    }
}

/// Compact workspace menu: icon + name + chevron, mirroring Postman's
/// workspace pill in the top bar. Switch, create, and variables live here;
/// deletion stays in the workspaces manager so a slip in this always-visible
/// menu can't wipe a whole workspace.
private struct WorkspaceSwitcher: View {
    @Environment(AppStore.self) private var store
    @State private var isHovering = false

    /// Finder-style name order, matching the workspaces manager's default
    /// sort - the menu otherwise follows vault insertion order, which drifts
    /// from what the manager shows.
    private var sortedWorkspaces: [Workspace] {
        store.vault.workspaces.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Menu {
            ForEach(sortedWorkspaces) { workspace in
                Button(workspace.name) { store.setActiveWorkspace(workspace.id) }
            }
            Divider()
            Button("Workspace Variables", systemImage: "curlybraces.square") {
                if let active = store.activeWorkspace {
                    store.openWorkspaceVariables(active.id)
                }
            }
            .disabled(store.activeWorkspace == nil)
            .help("Edit the active workspace's variables")
            Divider()
            // Postman-style footer: workspace management lives here - create
            // and browse together, apart from the active-workspace actions.
            Button("New Workspace", systemImage: "plus") { store.addWorkspace() }
            Button("View all workspaces", systemImage: "square.stack.3d.up") {
                store.enterWorkspacesManager()
            }
        } label: {
            HStack(spacing: AppSpacing.compact) {
                // Menu labels render images as monochrome templates, so this
                // icon stays a quiet gray - same as Postman's workspace icon.
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.subheadline)
                Text(store.activeWorkspace?.name ?? "No Workspace")
                    .font(AppFont.sidebarRow)
                    .lineLimit(1)
            }
            .padding(.horizontal, AppSpacing.comfortable)
            .frame(height: AppSize.topBarControlHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .fill(isHovering ? AppColor.subtleBackground : .clear)
        )
        .onHover { isHovering = $0 }
        .help("Switch workspace")
    }
}

/// An invisible AppKit view that makes the empty regions of the top bar drag
/// the window. Since the bar replaces the system title bar, it must supply
/// the title bar's drag behavior itself. Controls rendered above the
/// background win the hit test, so buttons and menus keep working.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView {
        WindowDragView()
    }

    func updateNSView(_ nsView: WindowDragView, context: Context) {}

    final class WindowDragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
