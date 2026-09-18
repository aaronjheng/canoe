import SwiftUI

/// Tab-based collection page: an Overview of what the collection holds
/// (Postman-style, opened by clicking the collection's name in the sidebar)
/// plus the Authorization helper inherited by its requests and the
/// collection's variables. Opened from the sidebar, the collection row's
/// context menu ("Edit Collection"), or the "Variables in Request"
/// inspector. Collection variables apply to every request in the collection
/// and lose only to environment variables of the same name.
struct CollectionDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: Collection
    @State private var section: Section = .overview

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case authorization = "Authorization"
        case variables = "Variables"

        var id: String { rawValue }
    }

    init(collection: Collection) {
        var collection = collection
        collection.variables.sortByName()
        _draft = State(initialValue: collection)
    }

    /// Whether the collection has unsaved edits (Save button).
    private var isDirty: Bool {
        store.hasPendingCollectionChanges(for: draft.id)
    }

    var body: some View {
        editorContent
            // Keep rows ordered by name (see EnvironmentDetailView).
            .onChange(of: draft.variables.map(\.key)) { _, _ in
                draft.variables.sortByName()
            }
            .onAppear { applyRequestedSection() }
            .onChange(of: store.selectedTab) { _, _ in applyRequestedSection() }
            // The deep link also lands while this tab is already frontmost (the
            // variables inspector's "Edit" with the collection tab open):
            // selectedTab does not change then, so watch the store's request
            // value directly or it would linger and fire on a later appear.
            .onChange(of: store.detailSectionRequests[draft.id]) { _, requested in
                if requested != nil { applyRequestedSection() }
            }
            .onChange(of: draft) { _, newValue in
                // Memory-only + dirty mark; the drafts mirror inside the store
                // is debounced, so no per-keystroke disk write happens here.
                // Each tracker diffs its own piece, so untouched parts stay out
                // of the pending set.
                store.updateCollectionVariables(newValue.id, variables: newValue.variables)
                store.updateCollectionAuthorization(newValue.id, authorization: newValue.authorization)
            }
            // Adopt vault-side content while the editor is clean: external
            // reloads (iCloud sync) replace clean entities in place, while a
            // dirty editor's live copy already equals its draft (rebasing
            // re-applies pending snapshots), so this is a no-op for it. Without
            // the adoption the stale draft would revert the external edit and
            // mark it dirty on the next keystroke.
            .onChange(of: liveCollectionVariables) { _, newVariables in
                guard let newVariables, !store.hasPendingCollectionVariables(for: draft.id),
                    newVariables != draft.variables
                else { return }
                var adopted = newVariables
                adopted.sortByName()
                draft.variables = adopted
            }
            .onChange(of: liveCollectionAuthorization) { _, newAuthorization in
                guard let newAuthorization, !store.hasPendingCollectionAuthorization(for: draft.id),
                    newAuthorization != draft.authorization
                else { return }
                draft.authorization = newAuthorization
            }
    }

    /// The vault's current variables/Authorization for this collection id
    /// (nil when the collection is gone) - what the adoption `onChange`s
    /// watch. `liveCollection` serves the overview stats.
    private var liveCollectionVariables: [Variable]? {
        store.vault.collections.first(where: { $0.id == draft.id })?.variables
    }

    private var liveCollectionAuthorization: RequestAuthorization? {
        store.vault.collections.first(where: { $0.id == draft.id })?.authorization
    }

    // MARK: - Section tabs

    /// The editor layout, split out of `body` so the modifier chain stays
    /// within the type-checker's budget.
    private var editorContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(AppColor.accent)
                Text(draft.name)
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                saveButton
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            sectionTabs
            Divider()

            switch section {
            case .overview:
                overviewPane
            case .authorization:
                AuthorizationForm(
                    type: $draft.authorization.type,
                    username: $draft.authorization.username,
                    password: $draft.authorization.password,
                    token: $draft.authorization.token,
                    variables: resolvedVariables,
                    suggestions: suggestions,
                    // The collection is the top of the inheritance chain;
                    // there is no parent to inherit from (and no inherit
                    // option in the picker, Postman-style).
                    inheritedSource: nil,
                    availableTypes: RequestAuthType.allCases.filter { $0 != .inherit }
                )
            case .variables:
                KeyValueEditor(
                    items: $draft.variables,
                    makeNew: Variable.init,
                    variables: resolvedVariables,
                    suggestions: suggestions,
                    keyHeader: "Variable",
                    valueHeader: "Value",
                    secretKeyPath: \.isSecret
                )
                .id(draft.id)
            }
        }
    }

    /// Applies a one-shot deep-link from the variables inspector:
    /// "Add Variables" / "Edit" land on Variables.
    private func applyRequestedSection() {
        guard let requested = store.consumeDetailSection(for: draft.id) else { return }
        switch requested {
        case .overview: section = .overview
        case .variables: section = .variables
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases) { tab in
                UnderlineTab(
                    title: tab.rawValue,
                    count: tab == .variables ? draft.variables.count : nil,
                    isSelected: section == tab,
                    action: { section = tab }
                )
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.small)
    }

    // MARK: - Overview

    /// The live collection: `draft` snapshots variables/authorization for
    /// editing, but folders and requests change from the sidebar while this
    /// page is open, so structure always reads the vault.
    private var liveCollection: Collection {
        store.vault.collections.first(where: { $0.id == draft.id }) ?? draft
    }

    /// Postman-style overview: totals describing what the collection holds.
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
        let live = liveCollection
        return HStack(spacing: AppSpacing.xLarge) {
            overviewStat(value: "\(live.requests.count)", label: "Requests")
            overviewStat(value: "\(live.folders.count)", label: "Folders")
            overviewStat(value: "\(draft.variables.count)", label: "Variables")
        }
    }

    private func overviewStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Variable scope for {{placeholder}} highlighting

    /// Workspace → collection → active environment, matching the resolution
    /// order the sender uses for the collection's own variables.
    private var resolvedVariables: [String: String] {
        var merged: [String: String] = [:]
        if let workspace = collectionWorkspace {
            merged = workspace.variables.resolvingDictionary(into: merged)
        }
        merged = draft.variables.resolvingDictionary(into: merged)
        if let environment = store.activeEnvironment {
            merged = environment.variables.resolvingDictionary(into: merged)
        }
        return merged
    }

    /// Completion candidates with scope metadata for `{{` auto-completion.
    private var suggestions: [VariableSuggestion] {
        var scopes: [RequestVariableScope] = []
        if let workspace = collectionWorkspace {
            scopes.append(
                RequestVariableScope(
                    kind: .workspace, ownerID: workspace.id,
                    ownerName: workspace.name, variables: workspace.variables
                )
            )
        }
        scopes.append(
            RequestVariableScope(
                kind: .collection, ownerID: draft.id,
                ownerName: draft.name, variables: draft.variables
            )
        )
        if let environment = store.activeEnvironment {
            scopes.append(
                RequestVariableScope(
                    kind: .environment, ownerID: environment.id,
                    ownerName: environment.name, variables: environment.variables
                )
            )
        }
        return VariableSuggestion.suggestions(from: scopes)
    }

    private var collectionWorkspace: Workspace? {
        draft.workspaceID.flatMap { id in store.vault.workspaces.first(where: { $0.id == id }) }
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Collection (⌘S)") {
            store.savePendingChanges()
        }
    }
}
