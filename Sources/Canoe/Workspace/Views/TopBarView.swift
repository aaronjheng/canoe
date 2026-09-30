import SwiftUI

/// Postman-style top bar spanning the full window width at the very top:
/// the window's traffic lights sit inline on it, the workspace switcher
/// follows them, and a settings shortcut sits at the trailing edge. The bar
/// draws a solid, opaque background on purpose - it replaces the system
/// title bar, and the macOS "liquid glass" chrome underneath it must never
/// show through. It shares the primary chrome fill so the left chrome (bar
/// + sidebar) reads as one continuous surface, separated from the content
/// row by the hairline under the bar.
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
        .background(AppColor.primaryBackground)
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
/// menu can't wipe a whole workspace. Hovering the pill dwells a moment, then
/// drops the workspace's info card (`WorkspaceInfoCard`) - the local stand-in
/// for Postman's cards.
private struct WorkspaceSwitcher: View {
    @Environment(AppStore.self) private var store
    @State private var isHoveringPill = false
    /// Pointer over the info card. The card floats below the pill, so without
    /// this the card would vanish the moment the pointer left for it.
    @State private var isHoveringCard = false
    @State private var isCardShown = false
    /// The switcher's own menu popup tracks the mouse in a nested session on
    /// top of the bar. A card sitting behind the open menu only reads as a
    /// glitch, so it stays hidden for as long as a menu tracks.
    @State private var isMenuTracking = false

    /// Finder-style name order, matching the workspaces manager's default
    /// sort - the menu otherwise follows vault insertion order, which drifts
    /// from what the manager shows.
    private var sortedWorkspaces: [Workspace] {
        store.vault.workspaces.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Coalesced hover of the pill and the card: the card stays up while
    /// either one is hovered.
    private var wantsCard: Bool { isHoveringPill || isHoveringCard }

    private var showsCard: Bool {
        isCardShown && !isMenuTracking && store.activeWorkspace != nil
    }

    var body: some View {
        pill
            .overlay(alignment: .topLeading) {
                if showsCard, let workspace = store.activeWorkspace {
                    WorkspaceInfoCard(workspace: workspace)
                        .offset(y: AppSize.topBarControlHeight + AppSpacing.xSmall)
                        .onHover { isHoveringCard = $0 }
                        // Also covers the card leaving for any reason other
                        // than the pointer (menu opened, workspace gone), so
                        // the flag never outlives the view it describes.
                        .onDisappear { isHoveringCard = false }
                }
            }
            // Dwell on the way in - a pointer merely crossing the pill, or a
            // click that opens the menu, never flashes the card - and a short
            // grace on the way out, because the pill and the card are separate
            // hover regions and stepping from one to the other crosses a gap
            // where neither is hovered.
            .task(id: wantsCard) {
                if wantsCard {
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled, !isMenuTracking else { return }
                    isCardShown = true
                } else {
                    try? await Task.sleep(for: .milliseconds(140))
                    guard !Task.isCancelled else { return }
                    isCardShown = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                isMenuTracking = true
                // Dropped, not just hidden: once the menu closes the card must
                // not pop back out from under a pointer that never left the
                // pill - it returns on the next hover, like Postman's.
                isCardShown = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                isMenuTracking = false
            }
    }

    /// The pill itself: the menu plus its hover fill. The fill is wrapped
    /// around the menu from the OUTSIDE, because the borderless menu style
    /// sizes its label itself - padding applied inside the label never grew
    /// the fill, which hugged the glyphs and the chevron.
    private var pill: some View {
        Menu {
            ForEach(sortedWorkspaces) { workspace in
                Toggle(
                    workspace.name,
                    isOn: Binding(
                        get: { store.activeWorkspace?.id == workspace.id },
                        set: { isSelected in
                            if isSelected {
                                store.setActiveWorkspace(workspace.id)
                            }
                        }
                    )
                )
            }
            Divider()
            Button("Overview", systemImage: "square.stack.3d.up") {
                if let active = store.activeWorkspace {
                    store.openWorkspace(active.id)
                }
            }
            .disabled(store.activeWorkspace == nil)
            .help("Open the active workspace overview")
            Button("Variables", systemImage: "curlybraces.square") {
                if let active = store.activeWorkspace {
                    store.openWorkspaceVariables(active.id)
                }
            }
            .disabled(store.activeWorkspace == nil)
            .help("Edit the active workspace's variables")
            Divider()
            Button("View all workspaces", systemImage: "square.stack.3d.up") {
                store.enterWorkspacesManager()
            }
        } label: {
            HStack(spacing: AppSpacing.compact) {
                // Menu labels render images as monochrome templates, so this
                // icon stays a quiet gray - same as Postman's workspace icon.
                Image(systemName: "square.stack.3d.up.fill")
                    .font(AppFont.small)
                Text(store.activeWorkspace?.name ?? "No Workspace")
                    .font(AppFont.sidebarRow)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .padding(.horizontal, AppSpacing.xSmall)
        .frame(height: AppSize.topBarControlHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                // Lit while the card is up, not only while the pill itself is
                // hovered: the fill marks which workspace the card belongs to,
                // and dropping it the moment the pointer stepped onto the card
                // left the card hanging off nothing. Riding on `showsCard`
                // instead of the card's own hover - the card outlives a
                // crossing of the gap by its hide grace - also keeps the fill
                // from blinking as the pointer moves between the two.
                .fill(showsCard || isHoveringPill ? AppColor.subtleBackground : .clear)
        )
        .onHover { isHoveringPill = $0 }
        .help("Switch workspace")
    }
}

/// Postman's workspace hover card, cut down to what a local vault knows: one
/// user, so "Created by <you>" becomes a plain created date, there is no share
/// link or favorite to offer, and Postman's "Last activity" has no counterpart
/// either - the app only derives one from request edits, which was never
/// designed as an activity feed. What is left is the creation date the vault
/// really stores plus the workspace ID, which is the name of the workspace's
/// file inside the vault.
private struct WorkspaceInfoCard: View {
    /// Wide enough for the full UUID at the monospaced body size, so the ID
    /// never has to be cut mid-value the way Postman cuts its IDs.
    static let width: CGFloat = 300

    let workspace: Workspace
    @State private var didCopyID = false

    /// Construction is expensive, so one instance serves the card.
    private static let relativeFormatter = RelativeDateTimeFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            createdRow
            Divider()
            idRow
        }
        .frame(width: Self.width)
        // Card height = content height: the overlay proposes the pill's 26pt,
        // and any sizeless child (Divider, shape) would otherwise absorb that
        // proposal and stretch the card down the window.
        .fixedSize(horizontal: false, vertical: true)
        .popupPanel()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(AppFont.small)
                .foregroundStyle(AppColor.accent)
            Text(workspace.name)
                .font(AppFont.panelTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.top, AppSpacing.medium)
        .padding(.bottom, AppSpacing.small)
    }

    // MARK: - Created

    private var createdRow: some View {
        HStack(spacing: AppSpacing.small) {
            Text("Created")
                .foregroundStyle(.secondary)
            Text(Self.relativeFormatter.localizedString(for: workspace.createdAt, relativeTo: Date()))
        }
        .font(AppFont.small)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.bottom, AppSpacing.medium)
    }

    // MARK: - Workspace ID

    private var idRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack(spacing: AppSpacing.small) {
                Text("Workspace ID")
                    .font(AppFont.small)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    copyID()
                } label: {
                    Image(systemName: didCopyID ? "checkmark" : "doc.on.doc")
                }
                // The style's default squared glyph box, deliberately: the
                // copy glyph and the checkmark are different sizes, and the
                // swap must not resize the row under the divider.
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(didCopyID ? AppColor.success : Color.secondary)
                .help("Copy workspace ID")
            }
            Text(workspace.id.uuidString)
                .font(AppFont.monoSubheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    /// Copy feedback matches the License window: the glyph turns into a
    /// checkmark for a moment, so the click is acknowledged in place.
    private func copyID() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(workspace.id.uuidString, forType: .string)
        didCopyID = true
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            didCopyID = false
        }
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
