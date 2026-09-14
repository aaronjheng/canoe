import SwiftUI

/// The workspace tab strip above the detail area. Each tab holds a request or
/// an environment editor; tabs keep their own send state and responses.
struct TabBarView: View {
    @Environment(AppStore.self) private var store
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xSmall) {
                    ForEach(store.visibleOpenTabs) { tab in
                        TabPill(
                            tab: tab,
                            width: tabWidth,
                            isSelected: store.selectedTab == tab,
                            isSending: store.sendingTabs.contains(tab)
                        )
                    }
                }
                .padding(.horizontal, AppSpacing.small)
                .padding(.vertical, AppSpacing.xSmall)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                availableWidth = width
            }
            Button("New Request Tab", systemImage: "plus") {
                store.addRequest()
            }
            .buttonStyle(ToolbarButtonStyle())
            .help("New Request (⌘N)")

            // Postman keeps the environment selector and inspector toggles in
            // the tab row; the window's dedicated toolbar row was removed.
            Divider()
                .frame(height: 18)
            EnvironmentPicker()
            InspectorToggleButton(
                systemImage: "curlybraces",
                isOn: store.showVariablesSidebar,
                help: store.showVariablesSidebar ? "Hide Variables in Request" : "Show Variables in Request"
            ) {
                store.toggleVariablesSidebar()
            }
            InspectorToggleButton(
                systemImage: "chevron.left.forwardslash.chevron.right",
                isOn: store.showCodeSnippetSidebar,
                help: store.showCodeSnippetSidebar ? "Hide Code Snippet" : "Show Code Snippet"
            ) {
                store.toggleCodeSnippetSidebar()
            }
            .padding(.trailing, AppSpacing.small)
        }
        // The ScrollView is vertically greedy - pin the strip to its content
        // height so it never squeezes the request editor below.
        .fixedSize(horizontal: false, vertical: true)
        .background(AppColor.controlBackground)
        .onAppear { store.pruneDanglingTabs() }
        .onChange(of: store.vault.collections) { _, _ in store.pruneDanglingTabs() }
        .onChange(of: store.vault.environments) { _, _ in store.pruneDanglingTabs() }
    }

    /// Postman-style tab sizing: tabs share the strip width equally. They cap
    /// at `tabMaxWidth` when there are few and shrink to `tabMinWidth` when
    /// crowded; horizontal scrolling only takes over beyond that floor.
    private var tabWidth: CGFloat? {
        let count = store.visibleOpenTabs.count
        guard count > 0, availableWidth > 0 else { return nil }
        let gaps = AppSpacing.xSmall * CGFloat(count - 1)
        let usable = availableWidth - AppSpacing.small * 2 - gaps
        return min(AppSize.tabMaxWidth, max(AppSize.tabMinWidth, usable / CGFloat(count)))
    }
}

/// Postman-style environment selector living in the tab row (the window
/// toolbar row was removed; this is its new home).
struct EnvironmentPicker: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Picker(
            "Environment",
            selection: Binding<UUID?>(
                get: { store.activeEnvironment?.id },
                set: { store.setActiveEnvironment($0) }
            )
        ) {
            Text("No Environment").tag(UUID?.none)
            ForEach(store.activeWorkspaceEnvironments) { env in
                Text(env.name).tag(UUID?.some(env.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .lineLimit(1)
        .truncationMode(.tail)
        .help(store.activeEnvironment.map { "Active environment: \($0.name)" } ?? "No environment selected")
    }
}

/// Compact icon toggle for the right-edge inspectors (on = accent tint +
/// selection fill, hover = light gray).
private struct InspectorToggleButton: View {
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
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(
                            isOn
                                ? AppColor.tabActiveBackground
                                : (isHovering ? AppColor.tabHoverBackground : Color.clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct TabPill: View {
    @Environment(AppStore.self) private var store
    let tab: OpenTab
    let width: CGFloat?
    let isSelected: Bool
    let isSending: Bool
    @State private var isHovering = false
    @State private var isHoveringClose = false

    var body: some View {
        Button {
            store.selectedTab = tab
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                tabIcon
                tabTitle
            }
            .padding(.horizontal, AppSpacing.small)
            // Fixed pill height (content was 4pt-padded top and bottom); the
            // contents stay vertically centered inside the shared token.
            .frame(minHeight: AppSize.tabHeight)
            // nil = not measured yet; then the pill keeps its natural width.
            .frame(minWidth: width, maxWidth: width)
            // The label's padding and gaps are empty space: without an
            // explicit shape only the text/icon hit-test, so clicks on the
            // pill body fall through instead of selecting the tab.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No .focusable(): a focused pill draws the system focus ring, which
        // reads as a selection border. Tab switching is pointer-driven.
        .help(tabHelp)
        .background {
            // Selected > hovered > idle: hueless neutral grays one step apart,
            // so the fill marks the selected tab without competing with the
            // method colors inside it or following the system accent color.
            // The fill alone marks the selection - no underline (deemed
            // redundant).
            if isSelected {
                AppColor.tabActiveBackground
            } else if isHovering {
                AppColor.tabHoverBackground
            } else {
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .contentShape(Rectangle())
        // The close button (and send spinner) floats above the tab so its
        // appearance never changes the tab's width.
        .overlay(alignment: .trailing) {
            trailingAccessory
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close Tab") { store.closeTab(tab) }
            Button("Close Other Tabs") { store.closeOtherTabs(except: tab) }
        }
    }

    private var tabHelp: String {
        switch tab {
        case .request(let id):
            if let request = store.vault.collections.flatMap(\.requests).first(where: { $0.id == id }) {
                request.urlString.isEmpty ? request.name : "\(request.name)\n\(request.urlString)"
            } else {
                "Request"
            }
        case .environment(let id):
            if let env = store.vault.environments.first(where: { $0.id == id }) {
                "\(env.name) - environment variables"
            } else {
                "Environment"
            }
        case .collection(let id):
            if let collection = store.vault.collections.first(where: { $0.id == id }) {
                "\(collection.name) - collection settings"
            } else {
                "Collection"
            }
        case .workspace(let id):
            if let workspace = store.vault.workspaces.first(where: { $0.id == id }) {
                "\(workspace.name) - workspace variables"
            } else {
                "Workspace"
            }
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isSending {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
                .padding(.trailing, AppSpacing.xSmall + 2)
        } else if isHovering || (isSelected && !isDirty) {
            Button {
                store.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 16, height: 16)
                    // No resting fill - the circle only appears while the
                    // pointer is over the button, marking it as clickable.
                    .background {
                        Circle().fill(isHoveringClose ? AppColor.border : Color.clear)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringClose = $0 }
            .help("Close Tab (⌘W)")
            .padding(.trailing, AppSpacing.xSmall + 2)
        } else if isDirty {
            // Postman-style dirty dot: unsaved tabs show a dot where the
            // close button sits; hovering swaps it back to the × above.
            Circle()
                .fill(AppColor.warning)
                .frame(width: 8, height: 8)
                .padding(.trailing, AppSpacing.small + 2)
        }
    }

    /// Whether the tab's request, environment, or collection has unsaved
    /// modifications.
    private var isDirty: Bool {
        switch tab {
        case .request(let id):
            return store.hasPendingChanges(for: id)
        case .environment(let id):
            return store.hasPendingEnvironmentChanges(for: id)
        case .collection(let id):
            return store.hasPendingCollectionChanges(for: id)
        default:
            return false
        }
    }

    @ViewBuilder
    private var tabIcon: some View {
        switch tab {
        case .request(let id):
            if let request = store.vault.collections.flatMap(\.requests).first(where: { $0.id == id }) {
                MethodTag(method: request.httpMethod)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        case .environment:
            Image(systemName: "globe")
                .font(.caption)
                .foregroundStyle(AppColor.accent)
        case .collection:
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(AppColor.accent)
        case .workspace:
            Image(systemName: "square.stack.3d.up.fill")
                .font(.caption)
                .foregroundStyle(AppColor.accent)
        }
    }

    @ViewBuilder
    private var tabTitle: some View {
        switch tab {
        case .request(let id):
            if let request = store.vault.collections.flatMap(\.requests).first(where: { $0.id == id }) {
                Text(request.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(request.urlString.isEmpty ? request.name : "\(request.name)\n\(request.urlString)")
            }
        case .environment(let id):
            if let env = store.vault.environments.first(where: { $0.id == id }) {
                Text(env.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .collection(let id):
            if let collection = store.vault.collections.first(where: { $0.id == id }) {
                Text(collection.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(collection.name) - collection settings")
            }
        case .workspace(let id):
            if let workspace = store.vault.workspaces.first(where: { $0.id == id }) {
                Text(workspace.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("\(workspace.name) - workspace variables")
            }
        }
    }
}
