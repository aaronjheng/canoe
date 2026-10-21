import SwiftUI

/// Postman-style Save Request sheet: names the request and picks its vault
/// home - a collection or one of its folders - before anything is written.
/// Shown only for scratch (unfiled) requests, whose explicit save has no
/// default location to fall back on (see `AppStore.saveActiveTab`).
struct SaveRequestSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let requestID: UUID

    /// Where the request goes: a collection root or one of its folders.
    enum SaveTarget: Hashable {
        case collection(UUID)
        case folder(UUID)
    }

    /// One selectable row of the picker (flattened collection/folder tree of
    /// the active workspace). File-visible so the row button below can take
    /// one.
    struct PickerRow: Identifiable, Hashable {
        let target: SaveTarget
        let name: String
        let depth: Int
        /// Whether the node has child folders (drives the chevron).
        let hasChildren: Bool
        var id: SaveTarget { target }
        /// The tree node's UUID (collection or folder) - the collapse state's
        /// key. `id` stays the SaveTarget so ForEach keys differ per target.
        var nodeID: UUID {
            switch target {
            case .collection(let id), .folder(let id): id
            }
        }
        var isFolder: Bool {
            if case .folder = target { return true }
            return false
        }
    }

    @State private var name = ""
    @State private var nameHovered = false
    @State private var selection: SaveTarget?
    @State private var search = ""
    @State private var isCreatingCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionNameHovered = false
    /// Collapsed tree nodes (inverted on purpose): everything renders
    /// expanded until collapsed, so fresh collections/folders are visible
    /// without seeding state on appear.
    @State private var collapsedRows: Set<UUID> = []
    @FocusState private var isNameFocused: Bool
    @FocusState private var isNewCollectionFocused: Bool

    /// The scratch request being saved. Nil means it found a home (or was
    /// discarded) while the sheet was up - the sheet then has nothing to do.
    private var request: Request? {
        store.unfiledRequests[requestID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text("Save Request")
                .font(AppFont.panelTitle)

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text("Name")
                    .font(AppFont.microHeader)
                    .foregroundStyle(AppColor.textSecondary)
                TextField("Request Name", text: $name)
                    .font(AppFont.small)
                    .variableFieldBordered(
                        isFocused: isNameFocused,
                        isHovered: nameHovered,
                        verticalPadding: AppSpacing.compact
                    )
                    .focused($isNameFocused)
                    .onHover { nameHovered = $0 }
                    .onSubmit(saveIfReady)
            }

            HStack(spacing: AppSpacing.small) {
                Text("Save to")
                    .font(AppFont.microHeader)
                    .foregroundStyle(AppColor.textSecondary)
                if let targetName {
                    Text(targetName)
                } else if isSelectionStale {
                    Text("The selected location no longer exists. Pick another one.")
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.warning)
                        .lineLimit(1)
                } else {
                    Text("Select a collection")
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.tertiaryText)
                }
            }

            targetList

            HStack {
                newCollectionControl
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveIfReady)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!isReady)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.vertical, AppSpacing.large)
        .frame(width: AppSize.saveRequestSheetWidth)
        .sheetSurface()
        // The sheet is its own root: suppress SwiftUI focus chrome here too
        // so first focus in the name field never paints the white-box flash.
        .focusEffectDisabled()
        .onAppear {
            name = request?.name ?? ""
            isNameFocused = true
        }
    }

    // MARK: - Target picker

    /// Bordered list surface: search field (or the New Collection row while
    /// creating) over the collection/folder tree of the active workspace.
    /// Both header modes share one fixed height, so toggling creation never
    /// reflows the list underneath.
    private var targetList: some View {
        VStack(spacing: 0) {
            Group {
                if isCreatingCollection {
                    newCollectionRow
                } else {
                    // Same field height as the sheet's other inputs (compact
                    // vertical padding, like variableFieldBordered).
                    FilterField(
                        text: $search, placeholder: "Search for collection or folder",
                        verticalPadding: AppSpacing.compact)
                }
            }
            .frame(height: Self.pickerHeaderHeight)
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.top, AppSpacing.xSmall)
            Divider()
                .padding(.horizontal, AppSpacing.xSmall)
            if rows.isEmpty {
                emptyList
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            PickerRowButton(
                                row: row,
                                isSelected: selection == row.target,
                                isExpanded: !collapsedRows.contains(row.nodeID),
                                onSelect: { selection = row.target },
                                onToggle: { toggleExpanded(row) },
                                onConfirm: { saveIfReady() }
                            )
                        }
                    }
                    .padding(.vertical, AppSpacing.xSmall)
                }
            }
        }
        .frame(height: 300)
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(AppColor.borderStrong, lineWidth: AppLine.field)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private var emptyList: some View {
        VStack(spacing: AppSpacing.xSmall) {
            Spacer()
            Text(emptyMessage)
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.tertiaryText)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "No collections yet. Create one below to save this request."
        }
        return "No collection or folder matches \"\(query)\"."
    }

    /// Flattened picker rows from the collection/folder tree. Unfiltered:
    /// the tree as collapsed/expanded (new nodes start expanded). With a
    /// query: matching collections ride with their whole subtree, matching
    /// folders show wherever they nest (expansion ignored, like the sidebar
    /// filter).
    private var rows: [PickerRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [PickerRow] = []
        if query.isEmpty {
            for collection in store.visibleCollections {
                appendRow(
                    .collection(collection.id), name: collection.name, depth: 0, children: store.childFolders(of: nil, in: collection),
                    into: &result)
                guard isExpanded(collection.id) else { continue }
                appendExpandedFolders(of: nil, in: collection, depth: 1, into: &result)
            }
            return result
        }
        for collection in store.visibleCollections {
            let collectionMatches = collection.name.localizedCaseInsensitiveContains(query)
            if collectionMatches {
                appendRow(
                    .collection(collection.id), name: collection.name, depth: 0, children: store.childFolders(of: nil, in: collection),
                    into: &result)
            }
            appendMatchingFolders(of: nil, in: collection, depth: 1, ancestorMatched: collectionMatches, into: &result)
        }
        return result
    }

    private func appendExpandedFolders(of parentFolderID: UUID?, in collection: Collection, depth: Int, into result: inout [PickerRow]) {
        for folder in store.childFolders(of: parentFolderID, in: collection) {
            appendRow(
                .folder(folder.id), name: folder.name, depth: depth, children: store.childFolders(of: folder.id, in: collection),
                into: &result)
            guard isExpanded(folder.id) else { continue }
            appendExpandedFolders(of: folder.id, in: collection, depth: depth + 1, into: &result)
        }
    }

    private func appendMatchingFolders(
        of parentFolderID: UUID?, in collection: Collection, depth: Int, ancestorMatched: Bool,
        into result: inout [PickerRow]
    ) {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        for folder in store.childFolders(of: parentFolderID, in: collection) {
            let matches = folder.name.localizedCaseInsensitiveContains(query)
            if ancestorMatched || matches {
                appendRow(
                    .folder(folder.id), name: folder.name, depth: depth, children: store.childFolders(of: folder.id, in: collection),
                    into: &result)
            }
            appendMatchingFolders(
                of: folder.id, in: collection, depth: depth + 1,
                ancestorMatched: ancestorMatched || matches, into: &result)
        }
    }

    private func appendRow(
        _ target: SaveTarget, name: String, depth: Int, children: [Folder], into result: inout [PickerRow]
    ) {
        result.append(PickerRow(target: target, name: name, depth: depth, hasChildren: !children.isEmpty))
    }

    /// Tree nodes render expanded unless collapsed (see `collapsedRows`).
    private func isExpanded(_ id: UUID) -> Bool {
        !collapsedRows.contains(id)
    }

    private func toggleExpanded(_ row: PickerRow) {
        guard row.hasChildren else { return }
        if collapsedRows.contains(row.nodeID) {
            collapsedRows.remove(row.nodeID)
        } else {
            collapsedRows.insert(row.nodeID)
        }
    }

    /// Display name of the selected target (nil when nothing is picked or
    /// the target vanished - a raced deletion just disables Save).
    private var targetName: String? {
        guard let selection else { return nil }
        switch selection {
        case .collection(let id):
            return store.visibleCollections.first { $0.id == id }?.name
        case .folder(let id):
            guard let folder = store.folder(withID: id) else { return nil }
            return folder.name
        }
    }

    /// The target row currently selected is no longer in the picker's own
    /// list (deleted while the sheet sat open): the summary line says so
    /// rather than naming nothing, so a disabled Save explains itself.
    private var isSelectionStale: Bool {
        selection != nil && targetName == nil
    }

    // MARK: - New Collection

    /// Bottom-left affordance that starts the inline creation flow.
    private var newCollectionControl: some View {
        Button {
            // A stale filter would hide the fresh row below (and the search
            // field itself is replaced while creating), so clear it.
            search = ""
            isCreatingCollection = true
            isNewCollectionFocused = true
        } label: {
            Label("New Collection", systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    /// Height of the picker's header row (search field and the New
    /// Collection row share it), so switching modes never shifts the list.
    private static let pickerHeaderHeight: CGFloat = 32

    /// Postman-style creation row: collection icon + wide name field +
    /// Create/Cancel, replacing the search strip while active. Enter
    /// commits, Esc cancels.
    private var newCollectionRow: some View {
        let canCreate = !newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: AppSpacing.small) {
            Image(systemName: "list.bullet.rectangle.fill")
                .font(AppFont.iconLarge)
                .foregroundStyle(AppColor.textSecondary)
            TextField("Name your collection", text: $newCollectionName)
                .font(AppFont.small)
                .variableFieldBordered(
                    isFocused: isNewCollectionFocused,
                    isHovered: newCollectionNameHovered,
                    verticalPadding: AppSpacing.compact
                )
                .focused($isNewCollectionFocused)
                .onHover { newCollectionNameHovered = $0 }
                .onSubmit(createCollection)
                .onKeyPress(.escape) {
                    cancelCollectionCreation()
                    return .handled
                }
            Button("Create", action: createCollection)
                .buttonStyle(SecondaryButtonStyle(isAccented: true))
                .disabled(!canCreate)
            Button("Cancel", action: cancelCollectionCreation)
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func createCollection() {
        guard let collection = store.createCollection(named: newCollectionName) else { return }
        selection = .collection(collection.id)
        // The fresh node is visible immediately (collapsedRows only records
        // collapsed nodes), but its row only renders when the tree is
        // unfiltered - entering creation cleared the filter already.
        isCreatingCollection = false
        newCollectionName = ""
    }

    private func cancelCollectionCreation() {
        isCreatingCollection = false
        newCollectionName = ""
    }

    // MARK: - Commit

    private var isReady: Bool {
        guard selection != nil else { return false }
        // The chosen target is gone (deleted from the sidebar, or swapped
        // out by a sync reload) while the sheet is open: Save would be a
        // silent no-op. `targetName` is nil for exactly that case, so the
        // button disables itself instead of promising a save.
        guard targetName != nil else { return false }
        // The scratch request is gone (saved/discarded another way): Save
        // would silently commit nothing.
        guard request != nil else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveIfReady() {
        guard isReady, let selection else { return }
        guard let request else { return }
        switch selection {
        case .collection(let collectionID):
            store.commitRequestSave(request.id, name: name, collectionID: collectionID, folderID: nil)
        case .folder(let folderID):
            guard let collection = store.collectionForFolder(folderID) else { return }
            store.commitRequestSave(request.id, name: name, collectionID: collection.id, folderID: folderID)
        }
        dismiss()
    }

    /// Cancel: the store aborts anything the sheet was staging (a close that
    /// was waiting on it gives up) and clears the context, which dismisses.
    private func close() {
        store.cancelRequestSaveSheet()
        dismiss()
    }
}

/// One selectable row of the target picker: chevron on nodes with children
/// (click toggles the branch, row click selects), folder icon on folder
/// rows, checkmark on the selected row - the sidebar tree's language.
private struct PickerRowButton: View {
    let row: SaveRequestSheet.PickerRow
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    /// Second click on the selected row saves right away.
    let onConfirm: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            if isSelected {
                onConfirm()
            } else {
                onSelect()
            }
        } label: {
            HStack(spacing: 0) {
                // Chevron column keeps names aligned across depths, like the
                // sidebar's tree. Leaf nodes render a spacer instead.
                if row.hasChildren {
                    Button {
                        onToggle()
                    } label: {
                        ExpanderChevron(isExpanded: isExpanded)
                            .padding(.vertical, AppSpacing.xSmall)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clickCursor()
                    .help(isExpanded ? "Collapse" : "Expand")
                } else {
                    Color.clear
                        .frame(width: AppSize.treeChevronWidth)
                }
                if row.isFolder {
                    Image(systemName: "folder")
                        .font(AppFont.iconLarge)
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(.leading, AppSpacing.xSmall)
                }
                Text(row.name)
                    .font(AppFont.sidebarRow)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? AppColor.textPrimary : AppColor.textSecondary)
                    .padding(.leading, AppSpacing.xSmall)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(AppFont.microHeader)
                        .foregroundStyle(AppColor.accent)
                        .padding(.trailing, AppSpacing.xSmall)
                }
            }
            .padding(.leading, AppSpacing.small + CGFloat(row.depth) * AppSize.treeExpanderColumn)
            .padding(.trailing, AppSpacing.small)
            .frame(height: AppSize.treeRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(AppColor.rowFill(isSelected: isSelected, isHovering: isHovering))
            )
            .padding(.horizontal, AppSpacing.xSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .onHover { isHovering = $0 }
        .animation(AppMotion.quick, value: isHovering)
        .help("Save into \(row.name)")
    }
}

/// The shared chevron glyph (same shape and sizing language as the
/// sidebar's tree rows).
private struct ExpanderChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(AppFont.sidebarChevron)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: AppSize.treeChevronWidth)
    }
}
