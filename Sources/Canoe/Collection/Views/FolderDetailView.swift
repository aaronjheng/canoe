import SwiftUI

/// Tab-based folder page: a folder is a unit of the collection, not just a tree
/// node (Postman-style), so it gets the same two things a collection page has -
/// what it holds, and the Authorization helper its requests inherit. Folders
/// carry no variables of their own, so there is no Variables section.
///
/// The header IS the breadcrumb: every ancestor is a button onto its own page
/// and the last crumb is the folder itself, editable in place. A rename is
/// structural and lands immediately (the rule every other rename in the app
/// follows); the Authorization edit uses the collection page's draft model, so
/// it waits for Save (⌘S / Save chip) and survives relaunches through
/// drafts.json.
struct FolderDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Folder
    @State private var nameDraft: String
    @State private var section: Section = .overview
    @FocusState private var isTitleFocused: Bool

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case authorization = "Authorization"

        var id: String { rawValue }
    }

    init(folder: Folder) {
        _draft = State(initialValue: folder)
        _nameDraft = State(initialValue: folder.name)
    }

    /// Whether the folder has unsaved Authorization edits (Save chip).
    private var isDirty: Bool {
        store.hasPendingFolderChanges(for: draft.id)
    }

    /// The collection whose file holds this folder: it owns both persistence
    /// and the top of the Authorization chain.
    private var collection: Collection? {
        store.collectionForFolder(draft.id)
    }

    var body: some View {
        editorContent
            .onChange(of: draft.authorization) { _, newValue in
                guard let collection else { return }
                store.updateFolderAuthorization(draft.id, in: collection.id, authorization: newValue)
            }
            // Adopt vault-side content while the editor is clean: external
            // reloads replace clean entities in place, and a sidebar rename
            // lands while this page is open. A dirty Authorization keeps its
            // draft (the live copy already equals it).
            .onChange(of: liveFolder) { _, newValue in
                guard let newValue else { return }
                // `draft.name` has to move with it: Esc and the empty/unchanged
                // guards restore from it, and a stale copy would quietly
                // rename the folder back to its pre-reload name on the next
                // blur.
                if !isTitleFocused {
                    nameDraft = newValue.name
                    draft.name = newValue.name
                }
                if !store.hasPendingFolderChanges(for: draft.id) {
                    draft.authorization = newValue.authorization
                }
            }
    }

    /// The vault's current copy of this folder - nil once it is deleted.
    private var liveFolder: Folder? {
        store.folder(withID: draft.id)
    }

    // MARK: - Layout

    private var editorContent: some View {
        VStack(spacing: 0) {
            header
            sectionTabs
            Divider()

            switch section {
            case .overview:
                overviewPane
            case .authorization:
                authorizationPane
            }
        }
    }

    // MARK: - Breadcrumb header

    private var header: some View {
        HStack(spacing: AppSpacing.xSmall) {
            breadcrumb
            Spacer(minLength: AppSpacing.medium)
            saveButton
        }
        .panelToolbar(horizontalPadding: AppSpacing.medium)
    }

    private var breadcrumb: some View {
        HStack(spacing: AppSpacing.xSmall) {
            if let collection {
                crumb(collection.name, help: "Open \(collection.name)") {
                    store.openTab(.collection(collection.id))
                }
            }
            ForEach(ancestorFolders) { folder in
                crumbSeparator
                crumb(folder.name, help: "Open folder \(folder.name)") {
                    store.openTab(.folder(folder.id))
                }
            }
            crumbSeparator
            titleField
        }
    }

    /// One ancestor crumb: quiet secondary text that opens its own page.
    private func crumb(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppFont.small)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help(help)
    }

    private var crumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(AppFont.small.weight(.semibold))
            .foregroundStyle(AppColor.tertiaryText)
    }

    /// The folder's own name: the last crumb and the page title. The shared
    /// inline name field (same language as the environment page's), so it
    /// carries that component's click-away dismissal - without it a rename
    /// stayed uncommitted after a click on dead space and was silently lost
    /// on the next tab switch. `onCommit` pushes the structural rename;
    /// Esc still restores the focus-time name without committing.
    private var titleField: some View {
        InlineNameField(
            text: $nameDraft,
            placeholder: "Folder Name",
            font: AppFont.panelTitle,
            onCommit: commitRename,
            focus: $isTitleFocused
        )
        .help("Click to rename")
    }

    /// The folder's ancestors, outermost first. The collection is not part of
    /// the list: it leads the breadcrumb on its own.
    private var ancestorFolders: [Folder] {
        guard let collection, let folder = collection.folders.first(where: { $0.id == draft.id }) else { return [] }
        var chain: [Folder] = []
        var visited: Set<UUID> = []
        var current = folder.parentFolderID
        while let id = current, let parent = collection.folders.first(where: { $0.id == id }) {
            guard visited.insert(id).inserted else { break }
            chain.append(parent)
            current = parent.parentFolderID
        }
        return chain.reversed()
    }

    /// Commits the header rename: trimmed, ignored when empty or unchanged,
    /// and persisted right away like every other rename in the app. The field
    /// snaps to the trimmed name, so a trailing space never shows as a pending
    /// edit after Return (focus stays in the field until the next blur).
    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collection, !trimmed.isEmpty else {
            nameDraft = draft.name
            return
        }
        guard trimmed != draft.name else {
            nameDraft = trimmed
            return
        }
        store.renameFolder(draft.id, in: collection.id, to: trimmed)
        draft.name = trimmed
        nameDraft = trimmed
    }

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases) { tab in
                UnderlineTab(
                    title: tab.rawValue,
                    count: nil,
                    isSelected: section == tab,
                    action: { section = tab }
                )
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.small)
    }

    // MARK: - Overview

    /// Postman-style overview: totals describing what the folder holds. Both
    /// counts cover the whole subtree, matching the collection page's totals.
    private var overviewPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                overviewStats
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overviewStats: some View {
        HStack(spacing: AppSpacing.xLarge) {
            overviewStat(value: "\(subtreeRequestCount)", label: "Requests")
            overviewStat(value: "\(descendantFolderIDs.count)", label: "Folders")
        }
    }

    /// Requests in this folder and everything below it - the folder's own
    /// share of the collection's totals.
    private var subtreeRequestCount: Int {
        let descendants = descendantFolderIDs
        return collection?.requests.count { request in
            guard let folderID = request.folderID else { return false }
            return folderID == draft.id || descendants.contains(folderID)
        } ?? 0
    }

    private func overviewStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(AppFont.small)
                .foregroundStyle(.secondary)
        }
    }

    /// Every folder below this one in the collection, used by the totals.
    /// Cycle-safe: a corrupted parent chain cannot hang the page.
    private var descendantFolderIDs: Set<UUID> {
        guard let collection else { return [] }
        var collected: Set<UUID> = []
        var frontier: Set<UUID> = [draft.id]
        var changed = true
        while changed {
            changed = false
            for folder in collection.folders {
                guard let parent = folder.parentFolderID, frontier.contains(parent) else { continue }
                if collected.insert(folder.id).inserted {
                    frontier.insert(folder.id)
                    changed = true
                }
            }
        }
        return collected
    }

    // MARK: - Authorization

    private var authorizationPane: some View {
        AuthorizationForm(
            type: $draft.authorization.type,
            username: $draft.authorization.username,
            password: $draft.authorization.password,
            token: $draft.authorization.token,
            variables: resolvedVariables,
            suggestions: suggestions,
            inheritedSource: inheritedSource,
            onEditInParent: editInParent
        )
    }

    /// What this folder inherits when its type stays on inherit: the nearest
    /// ancestor along Folder → Collection whose settings are not themselves
    /// inherit.
    private var inheritedSource: AuthorizationSource? {
        guard draft.authorization.type == .inherit, let collection else { return nil }
        return store.authorizationSource(forFolder: draft.id, in: collection)
    }

    /// "Edit in Parent": the parent folder's page, or the collection's.
    private func editInParent() {
        guard let source = inheritedSource else { return }
        switch source.kind {
        case .folder:
            store.openTab(.folder(source.ownerID))
        case .collection:
            store.openTab(.collection(source.ownerID))
        }
    }

    // MARK: - Variable scope for {{placeholder}} highlighting

    /// Workspace → collection → active environment, matching what the sender
    /// resolves for the folder's requests (folders add no variables).
    private var resolvedVariables: [String: String] {
        var merged: [String: String] = [:]
        if let workspace = collectionWorkspace {
            merged = workspace.variables.resolvingDictionary(into: merged)
        }
        if let collection {
            merged = collection.variables.resolvingDictionary(into: merged)
        }
        if let environment = store.activeEnvironment {
            merged = environment.variables.resolvingDictionary(into: merged)
        }
        return merged
    }

    /// Completion candidates with scope metadata for `{{` auto-completion.
    private var suggestions: [VariableSuggestion] {
        var scopes: [VariableScope] = []
        if let workspace = collectionWorkspace {
            scopes.append(
                VariableScope(
                    kind: .workspace, ownerID: workspace.id,
                    ownerName: workspace.name, variables: workspace.variables
                )
            )
        }
        if let collection {
            scopes.append(
                VariableScope(
                    kind: .collection, ownerID: collection.id,
                    ownerName: collection.name, variables: collection.variables
                )
            )
        }
        if let environment = store.activeEnvironment {
            scopes.append(
                VariableScope(
                    kind: .environment, ownerID: environment.id,
                    ownerName: environment.name, variables: environment.variables
                )
            )
        }
        return VariableSuggestion.suggestions(from: scopes)
    }

    private var collectionWorkspace: Workspace? {
        collection?.workspaceID.flatMap { id in store.vault.workspaces.first(where: { $0.id == id }) }
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Folder (⌘S)") {
            store.savePendingChanges()
        }
    }
}
