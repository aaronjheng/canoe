import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $store.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
            .help("Switch sidebar view")
            // macOS segmented pickers greedily fill the offered width - pin
            // to content size so the switcher hugs the leading edge.
            .fixedSize()
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)
            Divider()
            if store.sidebarTab == .items {
                ItemsView()
            } else {
                HistoryView()
            }
        }
        .background(AppColor.sidebarBackground)
    }
}

// MARK: - Items tab (collections + environments)

private struct ItemsView: View {
    @Environment(AppStore.self) private var store
    @State private var collectionsExpanded = true
    @State private var environmentsExpanded = true

    private var filteredEnvironments: [EnvProfile] {
        let query = store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = store.activeWorkspaceEnvironments
        guard !query.isEmpty else { return scoped }
        return scoped.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var isFiltering: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            FilterField(text: $store.sidebarFilter, placeholder: "Filter")
            Divider()
            // Manual tree rows instead of `List(selection:)`: the native
            // sidebar selection is a solid accent fill that swallows the
            // HTTP method colors, and its roomy rows don't match Postman's
            // density. Custom rows use the subtle selection fill (method
            // colors stay readable) and draw their own indent guides.
            ScrollView {
                LazyVStack(spacing: 0) {
                    GroupHeader(
                        title: "Collections",
                        // Matches the rows below, which render the filtered
                        // list (identical to the total when no filter is set).
                        count: store.filteredCollections.count,
                        isExpanded: collectionsExpanded,
                        onToggle: { collectionsExpanded.toggle() },
                        actions: {
                            Menu("Add", systemImage: "plus") {
                                Button("New Collection") { store.addCollection() }
                                Button("New Request") { store.addRequest() }
                            }
                            .menuStyle(.borderlessButton)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Add collection or request")
                        }
                    )
                    .padding(.leading, AppSpacing.medium)
                    .padding(.top, AppSpacing.xSmall)
                    .padding(.bottom, AppSpacing.xxSmall)
                    if collectionsExpanded {
                        ForEach(store.filteredCollections) { collection in
                            CollectionTree(collection: collection)
                        }
                    }
                    GroupHeader(
                        title: "Environments",
                        // Matches the rows below (see Collections above).
                        count: filteredEnvironments.count,
                        isExpanded: environmentsExpanded,
                        onToggle: { environmentsExpanded.toggle() },
                        actions: {
                            Button("Add Environment", systemImage: "plus") {
                                store.addEnvironment()
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Add environment")
                        }
                    )
                    .padding(.leading, AppSpacing.medium)
                    .padding(.top, AppSpacing.xSmall)
                    .padding(.bottom, AppSpacing.xxSmall)
                    if environmentsExpanded {
                        ForEach(filteredEnvironments) { env in
                            EnvironmentRow(env: env)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.xSmall)
                .padding(.bottom, AppSpacing.small)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if store.visibleCollections.isEmpty && store.activeWorkspaceEnvironments.isEmpty {
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: "folder",
                        description: Text("Press ⌘N to create a request.")
                    )
                } else if isFiltering && store.filteredCollections.isEmpty && filteredEnvironments.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("Nothing matches the current filter.")
                    )
                }
            }
        }
    }
}

/// A collapsible `> COLLECTIONS (3)  +` group header.
private struct GroupHeader<Actions: View>: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onToggle()
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Same chevron rhythm as tree rows: a 16pt centered
                        // glyph + 4pt gap, so the title still lands on the
                        // header content column but the spacing matches.
                        .frame(width: AppSize.treeChevronWidth)
                    Text(title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, AppSpacing.xSmall)
                    Text("\(count)")
                        .font(AppFont.countBadge)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.leading, AppSpacing.xSmall)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            actions()
        }
    }
}

private struct EnvironmentRow: View {
    @Environment(AppStore.self) private var store
    let env: EnvProfile
    @State private var isHovering = false
    @State private var showDeleteConfirm = false

    private var isActive: Bool { store.activeEnvironment?.id == env.id }
    private var isSelected: Bool { store.selectedTab == .environment(env.id) }

    var body: some View {
        Button {
            store.openTab(.environment(env.id))
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                Text(env.name)
                    .font(AppFont.sidebarRow)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(env.variables.count)")
                    .font(AppFont.countBadge)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColor.accent)
                }
            }
            // Level-1 leaf: name on the same content column as collections.
            .padding(.leading, 2 * AppSize.treeExpanderColumn)
            .padding(.trailing, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isSelected ? AppColor.selectionBackground : isHovering ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Set Active") { store.setActiveEnvironment(env.id) }
            Button("Duplicate") { store.duplicateEnvironment(env.id) }
            Divider()
            Button("Delete", role: .destructive) { showDeleteConfirm = true }
        }
        .help(isActive ? "\(env.name) (active environment)" : "Edit \(env.name)")
        .confirmationDialog(
            "Delete environment \"\(env.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { store.deleteEnvironment(env.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its variables will be permanently deleted.")
        }
    }
}

// MARK: - History tab

private struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.history.isEmpty ? "No requests yet" : "\(store.history.count) requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !store.history.isEmpty {
                    Button("Clear", systemImage: "trash") {
                        showClearConfirm = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear history")
                    .confirmationDialog(
                        "Clear all history?",
                        isPresented: $showClearConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Clear History", role: .destructive) { store.clearHistory() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)
            Divider()
            if store.history.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("Send a request and it will show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Same ScrollView + LazyVStack as the Items tab (not List):
                // one row language for hover, padding, and selection.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.history) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, AppSpacing.xSmall)
                    .padding(.bottom, AppSpacing.small)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Tree helpers (Collections)

// Guide hairlines: one per ancestor level (the collection plus every
// ancestor folder), each centered under that ancestor's expander chevron.
// Attached as a leading overlay - the per-level step is tighter than the
// chevron column, so the lines no longer fit in the layout flow.
private struct IndentGuides: View {
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(0, depth), id: \.self) { index in
                // The first hairline sits under the collection's chevron
                // center; each deeper ancestor is one tree step further in.
                Color.clear
                    .frame(
                        width: index == 0
                            ? AppSize.treeExpanderColumn + AppSize.treeChevronWidth / 2
                            : AppSize.treeIndent - 1
                    )
                AppColor.treeGuide
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
        }
    }
}

/// Fixed-width disclosure chevron so labels align across rows. Its frame
/// plus the row's xSmall gap make up `AppSize.treeExpanderColumn`.
private struct ExpanderChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: AppSize.treeChevronWidth)
    }
}

// MARK: - Collection tree (with folder/request tree)

private struct CollectionTree: View {
    @Environment(AppStore.self) private var store
    let collection: Collection
    @State private var isExpanded = true
    @State private var isHoveringHeader = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var showDeleteConfirm = false

    private var isFiltering: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Highlighted when the collection's page is the selected tab.
    private var isSelected: Bool { store.selectedTab == .collection(collection.id) }

    private var visibleFolders: [Folder] {
        let folders = store.childFolders(of: nil, in: collection)
        guard isFiltering else { return folders }
        return folders.filter { store.folderMatchesFilter($0.id, in: collection) }
    }

    private var visibleRequests: [RequestItem] {
        let requests = store.requests(in: nil, collection: collection)
        guard isFiltering else { return requests }
        return requests.filter { store.requestMatchesFilter($0) }
    }

    var body: some View {
        Group {
            // Postman-style: the whole row opens the collection's page (an
            // overview of its requests, auth, and variables); only the
            // chevron toggles the tree. A tap on the chevron reaches the
            // inner button alone, anywhere else opens the page.
            Button {
                store.openTab(.collection(collection.id))
                isExpanded = true
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        ExpanderChevron(isExpanded: isExpanded)
                            .padding(.vertical, AppSpacing.xSmall)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse collection" : "Expand collection")
                    Text(collection.name)
                        .font(AppFont.sidebarRow.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Tree level 1: one expander column in from the header.
                .padding(.leading, AppSize.treeExpanderColumn)
                .padding(.vertical, AppSpacing.xSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(isSelected ? AppColor.selectionBackground : isHoveringHeader ? AppColor.subtleBackground : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringHeader = $0 }
            .help("Open \(collection.name)")
            .contextMenu {
                Button("Add Request", systemImage: "plus") {
                    store.addRequest(in: collection.id)
                    isExpanded = true
                }
                Button("Add Folder", systemImage: "folder.badge.plus") {
                    store.addFolder(in: collection.id, parentFolderID: nil)
                    isExpanded = true
                }
                Divider()
                Button("Edit Collection", systemImage: "folder.badge.gearshape") {
                    store.openTab(.collection(collection.id))
                }
                Button("Rename Collection") {
                    renameDraft = collection.name
                    isRenaming = true
                }
                Divider()
                Button("Delete Collection", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
            if isExpanded {
                ForEach(visibleFolders) { folder in
                    FolderTree(folder: folder, collection: collection, depth: 1)
                }
                ForEach(visibleRequests) { request in
                    RequestRow(request: request, depth: 1)
                }
            }
        }
        .alert("Rename Collection", isPresented: $isRenaming) {
            TextField("Collection Name", text: $renameDraft)
            Button("Rename") { store.renameCollection(collection.id, to: renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete collection \"\(collection.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Collection", role: .destructive) { store.deleteCollection(collection.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its folders and requests will be permanently deleted.")
        }
        .onChange(of: store.sidebarFilter) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isExpanded = true
            }
        }
    }
}

// MARK: - Folder tree (recursive)

private struct FolderTree: View {
    @Environment(AppStore.self) private var store
    let folder: Folder
    let collection: Collection
    let depth: Int
    @State private var isExpanded = true
    @State private var isHoveringHeader = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var showDeleteConfirm = false
    @State private var showEditSheet = false

    private var isFiltering: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleFolders: [Folder] {
        let folders = store.childFolders(of: folder.id, in: collection)
        guard isFiltering else { return folders }
        return folders.filter { store.folderMatchesFilter($0.id, in: collection) }
    }

    private var visibleRequests: [RequestItem] {
        let requests = store.requests(in: folder.id, collection: collection)
        guard isFiltering else { return requests }
        return requests.filter { store.requestMatchesFilter($0) }
    }

    var body: some View {
        Group {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 0) {
                    // The chevron sits one tree step per level right of the
                    // collection's chevron; the folder icon lands one expander
                    // column past it - the same x as sibling requests' tags.
                    Color.clear
                        .frame(width: AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
                    HStack(spacing: AppSpacing.xSmall) {
                        ExpanderChevron(isExpanded: isExpanded)
                        Image(systemName: "folder")
                            .font(.system(size: 16))  // VS Code uses 16px tree icons
                            .foregroundStyle(.secondary)
                        Text(folder.name)
                            .font(AppFont.sidebarRow)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.trailing, AppSpacing.xSmall)
                    .padding(.vertical, AppSpacing.xSmall)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(isHoveringHeader ? AppColor.subtleBackground : .clear)
                )
                .overlay(alignment: .leading) {
                    IndentGuides(depth: depth)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringHeader = $0 }
            .contextMenu {
                Button("Add Request", systemImage: "plus") {
                    store.addRequest(in: collection.id, folderID: folder.id)
                    isExpanded = true
                }
                Button("Add Subfolder", systemImage: "folder.badge.plus") {
                    store.addFolder(in: collection.id, parentFolderID: folder.id)
                    isExpanded = true
                }
                Divider()
                Button("Edit Folder", systemImage: "folder.badge.gearshape") {
                    showEditSheet = true
                }
                Button("Rename Folder") {
                    renameDraft = folder.name
                    isRenaming = true
                }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
            if isExpanded {
                ForEach(visibleFolders) { subfolder in
                    FolderTree(folder: subfolder, collection: collection, depth: depth + 1)
                }
                ForEach(visibleRequests) { request in
                    RequestRow(request: request, depth: depth + 1)
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            FolderEditSheet(collection: collection, folder: folder)
        }
        .alert("Rename Folder", isPresented: $isRenaming) {
            TextField("Folder Name", text: $renameDraft)
            Button("Rename") { store.renameFolder(folder.id, in: collection.id, to: renameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete folder \"\(folder.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id, in: collection.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Requests inside move to the collection root; the folder itself is permanently deleted.")
        }
        .onChange(of: store.sidebarFilter) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isExpanded = true
            }
        }
    }
}

// MARK: - Request row

private struct RequestRow: View {
    @Environment(AppStore.self) private var store
    let request: RequestItem
    let depth: Int
    @State private var isHovering = false
    @State private var showDeleteConfirm = false

    private var isSelected: Bool { store.selectedTab == .request(request.id) }

    var body: some View {
        Button {
            store.openTab(.request(request.id))
        } label: {
            HStack(spacing: 0) {
                // The method tag sits on the content column: one expander
                // column past the row's chevron position, which steps one
                // tree step per level - the same x as sibling folders' icons.
                Color.clear
                    .frame(width: 2 * AppSize.treeExpanderColumn + AppSize.treeIndent * CGFloat(depth))
                HStack(spacing: AppSpacing.xSmall) {
                    MethodTag(method: request.httpMethod)
                    Text(request.name)
                        .font(AppFont.sidebarRow)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, AppSpacing.xSmall)
                .padding(.vertical, AppSpacing.xSmall)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isSelected ? AppColor.selectionBackground : isHovering ? AppColor.subtleBackground : .clear)
            )
            .overlay(alignment: .leading) {
                IndentGuides(depth: depth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Duplicate") {
                store.duplicateRequest(request.id)
            }
            Divider()
            Button("Delete", role: .destructive) {
                showDeleteConfirm = true
            }
        }
        .help(request.name)
        .confirmationDialog(
            "Delete request \"\(request.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteRequest(request.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - History row

private struct HistoryRow: View {
    @Environment(AppStore.self) private var store
    let entry: HistoryEntry
    @State private var isHovering = false

    private var requestExists: Bool {
        guard let id = entry.requestID else { return false }
        return store.vault.collections.contains { $0.requests.contains { $0.id == id } }
    }

    var body: some View {
        Button {
            if let id = entry.requestID { store.openRequest(id) }
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                MethodTag(method: entry.method)
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text(entry.name)
                        .font(AppFont.sidebarRow)
                        .lineLimit(1)
                    Text(entry.urlString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if entry.statusCode > 0 {
                    Text("\(entry.statusCode)")
                        .font(AppFont.countBadge)
                        .monospacedDigit()
                        .foregroundStyle(AppColor.statusColor(entry.statusCode))
                }
            }
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isHovering ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
            .foregroundStyle(requestExists ? .primary : .tertiary)
            .opacity(requestExists ? 1 : AppOpacity.disabled)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(!requestExists)
        .help(
            requestExists
                ? "\(entry.urlString) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))" : "Original request was deleted"
        )
    }
}
