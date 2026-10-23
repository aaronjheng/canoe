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
        case scripts = "Scripts"

        var id: String { rawValue }
    }

    init(collection: Collection) {
        _draft = State(initialValue: collection)
    }

    /// Whether the collection has unsaved edits (Save button).
    private var isDirty: Bool {
        store.hasPendingCollectionChanges(for: draft.id)
    }

    var body: some View {
        editorContent
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
                draft.variables = newVariables
            }
            .onChange(of: liveCollectionAuthorization) { _, newAuthorization in
                guard let newAuthorization, !store.hasPendingCollectionAuthorization(for: draft.id),
                    newAuthorization != draft.authorization
                else { return }
                draft.authorization = newAuthorization
            }
            // A send-path OAuth token renewal (AppStore+OAuth) patches only
            // the managed token fields, also while this editor holds other
            // pending edits. Adopt exactly those fields - setting them
            // re-pushes through updateCollectionAuthorization, which sees
            // the store is already there and no-ops.
            .onChange(of: store.oauthTokenRevision(forOwner: draft.id)) { _, _ in
                adoptRenewedOAuthTokens()
            }
            // The header reads the vault's name, not the draft's: a sidebar
            // rename (or an external reload) lands while this page is open,
            // and the title used to keep showing the pre-rename name until
            // the tab was reopened. The draft's name is not editable here,
            // so there is nothing to lose.
            .onChange(of: liveCollectionName) { _, newName in
                guard let newName, newName != draft.name else { return }
                draft.name = newName
            }
    }

    /// The vault's current variables/Authorization for this collection id
    /// (nil when the collection is gone) - what the adoption `onChange`s
    /// watch. `liveCollection` serves the overview stats.
    private var liveCollectionVariables: [Variable]? {
        store.vault.collections.first(where: { $0.id == draft.id })?.variables
    }

    private var liveCollectionAuthorization: Authorization? {
        store.vault.collections.first(where: { $0.id == draft.id })?.authorization
    }

    private var liveCollectionName: String? {
        store.vault.collections.first(where: { $0.id == draft.id })?.name
    }

    /// Pulls a send-path OAuth token renewal (AppStore+OAuth) into the
    /// Authorization draft: only the managed token fields, so it applies
    /// also while other Authorization edits are pending here (the whole-
    /// value adoption above is guarded off for those on purpose).
    private func adoptRenewedOAuthTokens() {
        guard
            let fresh = store.liveOAuthTokenFields(forOwner: draft.id),
            fresh.tokens != draft.authorization.oauthTokens
                || fresh.selectedID != draft.authorization.oauthSelectedTokenID
        else { return }
        draft.authorization.oauthTokens = fresh.tokens
        draft.authorization.oauthSelectedTokenID = fresh.selectedID
    }

    // MARK: - Section tabs

    // MARK: - Scripts

    /// Which collection script the Scripts tab edits (Postman's sidebar
    /// order). Edited text auto-saves (debounced, like the description).
    @State private var scriptColumn: CollectionScriptColumn = .preRequest
    @State private var scriptSaveTask: Task<Void, Never>?

    enum CollectionScriptColumn: String {
        case preRequest = "Before request"
        case postResponse = "After response"
    }

    /// Postman's collection Scripts tab: a sidebar picks the phase, the
    /// editor holds that phase's script. Every request in the collection
    /// runs these around its own scripts. Text auto-saves (debounced),
    /// like the Overview's description.
    private var scriptsPane: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                scriptColumnRow(.preRequest)
                scriptColumnRow(.postResponse)
                Spacer()
            }
            .padding(.top, AppSpacing.medium)
            .frame(width: 168, alignment: .topLeading)
            Divider()
            scriptEditor
        }
    }

    private func scriptColumnRow(_ column: CollectionScriptColumn) -> some View {
        Button {
            scriptColumn = column
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                Text(column.rawValue)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(AppColor.textPrimary)
                if hasScriptContent(column) {
                    Circle()
                        .fill(AppColor.success)
                        .frame(width: AppSize.contentDot, height: AppSize.contentDot)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.compact)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(scriptColumn == column ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickCursor()
        .padding(.horizontal, AppSpacing.compact)
    }

    private func hasScriptContent(_ column: CollectionScriptColumn) -> Bool {
        switch column {
        case .preRequest: !draft.preRequestScript.isEmpty
        case .postResponse: !draft.postResponseScript.isEmpty
        }
    }

    private var scriptEditor: some View {
        VariableHighlightEditor<Bool>(
            text: Binding(
                get: {
                    scriptColumn == .preRequest
                        ? draft.preRequestScript : draft.postResponseScript
                },
                set: {
                    if scriptColumn == .preRequest {
                        draft.preRequestScript = $0
                    } else {
                        draft.postResponseScript = $0
                    }
                }
            ),
            variables: resolvedVariables,
            suggestions: suggestions,
            isSingleLine: false,
            fillsContainer: true,
            font: .systemSubheadline,
            placeholder: scriptColumn == .preRequest
                ? "Runs before the request scripts of this collection (pm.variables.set, ...)"
                : "Runs after the request scripts of this collection (pm.expect, pm.test)"
        )
        .padding(.horizontal, AppSpacing.medium)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColor.controlBackground)
        .onChange(of: draft.preRequestScript) { _, _ in scheduleScriptSave() }
        .onChange(of: draft.postResponseScript) { _, _ in scheduleScriptSave() }
    }

    /// Debounces script keystrokes into one auto-save per idle gap (the
    /// description's pattern): both fields land together, so switching
    /// columns mid-edit never saves a half-typed phase alone.
    private func scheduleScriptSave() {
        scriptSaveTask?.cancel()
        scriptSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            store.updateCollectionScripts(
                draft.id,
                preRequestScript: draft.preRequestScript,
                postResponseScript: draft.postResponseScript)
        }
    }

    /// The editor layout, split out of `body` so the modifier chain stays
    /// within the type-checker's budget.
    private var editorContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                // The collection's tab icon, so a collection never reads as
                // one of its own folders (`folder`).
                Image(systemName: "list.bullet.rectangle.fill")
                    .foregroundStyle(AppColor.accent)
                Text(draft.name)
                    .font(AppFont.panelTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                saveButton
            }
            .panelToolbar(horizontalPadding: AppSpacing.medium)

            sectionTabs
            Divider()

            switch section {
            case .scripts:
                scriptsPane
            case .overview:
                overviewPane
            case .authorization:
                AuthorizationForm(
                    type: $draft.authorization.type,
                    username: $draft.authorization.username,
                    password: $draft.authorization.password,
                    token: $draft.authorization.token,
                    apiKey: $draft.authorization.apiKey,
                    apiKeyValue: $draft.authorization.apiKeyValue,
                    apiKeyLocation: $draft.authorization.apiKeyLocation,
                    oauth: $draft.authorization,
                    variables: resolvedVariables,
                    suggestions: suggestions,
                    // The collection is the top of the inheritance chain;
                    // there is no parent to inherit from (and no inherit
                    // option in the picker, Postman-style).
                    inheritedSource: nil,
                    availableTypes: AuthType.allCases.filter { $0 != .inherit }
                )
            case .variables:
                KeyValueEditor(
                    items: $draft.variables,
                    makeNew: Variable.init,
                    variables: resolvedVariables,
                    suggestions: suggestions,
                    keyHeader: "Variable",
                    valueHeader: "Value",
                    headerBackground: nil,
                    secretKeyPath: \.isSecret,
                    // Manual order (Postman-style): rows resolve and display in
                    // this order, so no auto-sort may rewrite it. The header
                    // still offers an explicit A→Z / Z→A sort, and Bulk Edit
                    // swaps the grid for key-value text lines.
                    allowsReorder: true,
                    allowsKeySort: true,
                    allowsBulkEdit: true
                )
                .id(draft.id)
                // The section divider must not sit flush on the header row:
                // the other sections (Overview / Authorization) carry their
                // own padding below the same divider, the bare table has
                // none.
                .padding(.top, AppSpacing.small)
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
                    hasContent: tab == .scripts
                        && (!draft.preRequestScript.isEmpty
                            || !draft.postResponseScript.isEmpty),
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
                descriptionBlock
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Postman-style collection description in the Overview: a labeled
    /// editor that auto-saves (debounced, like a rename). Editable inline;
    /// `{{variables}}` highlight like everywhere else.
    @ViewBuilder
    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text("Description")
                .font(AppFont.sectionTitle)
            // Explicit specialization: no programmatic focus wiring.
            VariableHighlightEditor<Bool>(
                text: $draft.requestDescription,
                variables: resolvedVariables,
                suggestions: suggestions,
                isSingleLine: false,
                font: .systemSubheadline,
                placeholder: "Document this collection..."
            )
            .padding(AppSpacing.small)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .strokeBorder(AppColor.border, lineWidth: AppLine.field)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: draft.requestDescription) { _, newValue in
            scheduleDescriptionSave(newValue)
        }
    }

    /// Debounces description keystrokes into one auto-save per idle gap.
    @State private var descriptionSaveTask: Task<Void, Never>?
    private func scheduleDescriptionSave(_ description: String) {
        descriptionSaveTask?.cancel()
        descriptionSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            store.updateCollectionDescription(draft.id, to: description)
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
                .font(AppFont.featureHeadline)
                .monospacedDigit()
            Text(label)
                .font(AppFont.small)
                .foregroundStyle(AppColor.textSecondary)
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
        var scopes: [VariableScope] = []
        if let workspace = collectionWorkspace {
            scopes.append(
                VariableScope(
                    kind: .workspace, ownerID: workspace.id,
                    ownerName: workspace.name, variables: workspace.variables
                )
            )
        }
        scopes.append(
            VariableScope(
                kind: .collection, ownerID: draft.id,
                ownerName: draft.name, variables: draft.variables
            )
        )
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
        draft.workspaceID.flatMap { id in store.vault.workspaces.first(where: { $0.id == id }) }
    }

    /// Postman-style Save: shared chip, enabled while dirty.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Collection (⌘S)") {
            store.savePendingChanges(scope: .activeTab)
        }
    }
}
