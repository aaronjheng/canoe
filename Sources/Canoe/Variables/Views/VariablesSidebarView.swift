import AppKit
import SwiftUI

/// The "Variables in Request" inspector on the right edge of the detail area.
///
/// With a request selected it lists every variable in scope, grouped by scope
/// from highest to lowest precedence (environment → collection → workspace),
/// so higher-precedence variables appear at the top. Disabled rows are
/// excluded from resolution, overridden rows are annotated with the scope
/// that wins, secrets are masked, and placeholders the request references but
/// no scope defines are flagged as unresolved; keys that do resolve are
/// flattened into a "Resolved Variables" summary of the values the wire will
/// carry.
///
/// Without a request it falls back to Postman's "All variables" view: the
/// workspace- and environment-level scopes with actionable empty states, so
/// the panel is never a dead end.
struct VariablesSidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = ""
    @State private var revealedSecrets: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if let request = store.selectedRequest {
                requestContent(for: request)
            } else {
                workspaceContent
            }
        }
        // Greedy in both dimensions - without this the VStack hugs its ideal
        // height and centers inside the pane, leaving a void above the header.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.sidebarBackground)
        // The inspector outlives request switches (it sits outside the
        // detail pane), so reset per-request state explicitly: otherwise a
        // filter typed for one request yields a bogus "No Results" on the
        // next, and revealed secrets linger across requests.
        .onChange(of: store.selectedRequest?.id) { _, _ in
            filter = ""
            revealedSecrets = []
        }
    }

    // MARK: - Header

    private var header: some View {
        InspectorHeader(
            title: store.selectedRequest == nil ? "All Variables" : "Variables in Request",
            closeHelp: "Hide Variables in Request (⇧⌘V)"
        ) {
            store.showVariablesSidebar = false
        }
    }

    // MARK: - Request context

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestContent(for request: Request) -> some View {
        let scopes = store.variableScopesForRequest(request)
        let displayScopes = Array(scopes.reversed())
        let usedKeys = Set(store.placeholdersUsedByRequest(request))
        let resolvedVars = store.variablesForRequest(request)
        let resolvedKeys = Set(resolvedVars.keys)
        let unresolvedAll = usedKeys.subtracting(resolvedKeys).sorted()
        let unresolved = query.isEmpty ? unresolvedAll : unresolvedAll.filter { $0.localizedCaseInsensitiveContains(query) }
        // Placeholders that resolve toward a reference cycle: defined, so
        // not "unresolved", but the wire still carries literal `{{...}}`.
        let blockedSet = VariableResolver.keysBlockedByCycle(used: usedKeys, variables: resolvedVars)
        let blockedAll = blockedSet.sorted()
        let blocked = query.isEmpty ? blockedAll : blockedAll.filter { $0.localizedCaseInsensitiveContains(query) }
        // Used keys that do resolve, flattened to the winning value per key.
        let resolvedAll = resolvedEntries(usedKeys: usedKeys, resolvedVars: resolvedVars, blocked: blockedSet, scopes: scopes)
        let resolved =
            query.isEmpty
            ? resolvedAll
            : resolvedAll.filter { $0.key.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
        return VStack(spacing: 0) {
            filterField
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(displayScopes) { scope in
                        ScopeSection(
                            scope: scope,
                            query: query,
                            usedKeys: usedKeys,
                            overrideLabels: overrideLabels(for: scope, in: scopes),
                            revealedSecrets: $revealedSecrets,
                            onEdit: { openEditor(for: scope) }
                        )
                    }
                    if !resolved.isEmpty {
                        ResolvedSection(entries: resolved, revealedSecrets: $revealedSecrets)
                    }
                    if !unresolved.isEmpty || !blocked.isEmpty {
                        UnresolvedSection(keys: unresolved, cyclicKeys: Set(blocked))
                    }
                }
            }
            .overlay {
                if !query.isEmpty && totalVisibleRows(in: scopes) == 0 && unresolved.isEmpty && blocked.isEmpty && resolved.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No variables match the current filter.")
                    )
                }
            }
        }
    }

    private var filterField: some View {
        FilterField(text: $filter, placeholder: "Filter Variables", isBoxed: true)
            .padding(.vertical, AppSpacing.xSmall)
    }

    // MARK: - No request context (Postman's "All variables" view)

    private var workspaceContent: some View {
        let scopes = store.workspaceVariableScopes()
        let displayScopes = Array(scopes.reversed())
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(displayScopes) { scope in
                        ScopeSection(
                            scope: scope,
                            query: "",
                            usedKeys: [],
                            overrideLabels: overrideLabels(for: scope, in: scopes),
                            revealedSecrets: $revealedSecrets,
                            onEdit: { openEditor(for: scope) }
                        )
                    }
                }
            }
            Divider()
            Text("Select a request to see its collection variables.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.small)
        }
    }

    // MARK: - Helpers

    /// For each key, the highest-precedence scope that defines it (the scope
    /// whose value actually wins). Scopes arrive lowest-first, so walking
    /// upward lets a higher scope overwrite a lower one.
    private func overrideLabels(for scope: VariableScope, in scopes: [VariableScope]) -> [String: String] {
        guard let index = scopes.firstIndex(where: { $0.id == scope.id }) else { return [:] }
        var labels: [String: String] = [:]
        for higher in scopes.dropFirst(index + 1) {
            for variable in higher.variables where variable.isEnabled {
                let key = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                labels[key] = higher.kind.rawValue
            }
        }
        return labels
    }

    private func openEditor(for scope: VariableScope) {
        guard let ownerID = scope.ownerID else { return }
        switch scope.kind {
        case .workspace: store.openWorkspaceVariables(ownerID)
        case .collection: store.openCollectionVariables(ownerID)
        case .environment: store.openEnvironment(ownerID)
        }
    }

    /// The flattened resolution outcome for keys the request references:
    /// per key the variable that wins and its scope, ordered by key. Scopes
    /// arrive lowest-first, so within a scope the last enabled definition
    /// wins and across scopes the later (higher) scope does - matching
    /// `variablesForRequest`. Cyclic keys are excluded (defined, but they
    /// never expand), and `source` is only set when several scopes define
    /// the key, when knowing which one wins is the point.
    private func resolvedEntries(
        usedKeys: Set<String>,
        resolvedVars: [String: String],
        blocked: Set<String>,
        scopes: [VariableScope]
    ) -> [ResolvedEntry] {
        var winners: [String: (variable: Variable, source: VariableScope.Kind)] = [:]
        var definitionCounts: [String: Int] = [:]
        for scope in scopes.reversed() {
            var scopeWinners: [String: Variable] = [:]
            for variable in scope.variables where variable.isEnabled {
                let key = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard usedKeys.contains(key), resolvedVars[key] != nil, !blocked.contains(key) else { continue }
                scopeWinners[key] = variable
                definitionCounts[key, default: 0] += 1
            }
            for (key, variable) in scopeWinners where winners[key] == nil {
                winners[key] = (variable, scope.kind)
            }
        }
        return
            winners
            .map { key, winner in
                ResolvedEntry(
                    key: key,
                    value: resolvedVars[key] ?? "",
                    variable: winner.variable,
                    source: (definitionCounts[key] ?? 0) > 1 ? winner.source : nil
                )
            }
            .sorted { $0.key < $1.key }
    }

    private func totalVisibleRows(in scopes: [VariableScope]) -> Int {
        guard !query.isEmpty else { return 0 }
        return scopes.reduce(0) { count, scope in
            guard scope.ownerID != nil else { return count }
            return count + scope.variables.filter { variableMatchesFilter($0, query: query) }.count
        }
    }
}

/// Case-insensitive match of a variable's key or value against the filter.
private func variableMatchesFilter(_ variable: Variable, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    return variable.key.localizedCaseInsensitiveContains(query)
        || variable.value.localizedCaseInsensitiveContains(query)
}

// MARK: - Scope section

/// One scope (workspace, collection, or environment): header with the scope
/// label and an edit shortcut, then its rows or a Postman-style hint with an
/// actionable link.
private struct ScopeSection: View {
    @Environment(AppStore.self) private var store
    let scope: VariableScope
    let query: String
    let usedKeys: Set<String>
    let overrideLabels: [String: String]
    @Binding var revealedSecrets: Set<UUID>
    let onEdit: () -> Void

    /// Leading inset for the hairline between rows so it lines up with the
    /// key column (used-marker dot + gap).
    private static let rowIndent: CGFloat = AppSpacing.large + 9

    private enum HintAction {
        /// Opens the scope's variable editor in a tab.
        case openEditor
        /// Offers a menu to pick the active environment.
        case selectEnvironment
    }

    private var isFiltering: Bool { !query.isEmpty }

    private var visibleVariables: [Variable] {
        guard isFiltering else { return scope.variables }
        return scope.variables.filter { variableMatchesFilter($0, query: query) }
    }

    /// Postman-style empty state: a sentence plus an actionable link.
    private var hint: (message: String, action: HintAction?)? {
        if scope.kind == .environment && scope.ownerID == nil {
            return ("No environment selected.", .selectEnvironment)
        }
        if scope.kind == .workspace && scope.ownerID == nil {
            return ("No active workspace.", nil)
        }
        if scope.variables.isEmpty {
            return ("No variables defined.", scope.ownerID == nil ? nil : .openEditor)
        }
        return nil
    }

    var body: some View {
        if isFiltering {
            if !visibleVariables.isEmpty {
                section
            }
        } else {
            section
        }
    }

    private var section: some View {
        VStack(spacing: 0) {
            header
            if let hint {
                hintRow(hint)
            } else {
                rows
            }
            Divider()
        }
    }

    private var header: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: scope.kind.systemImage)
                .font(.caption)
                .foregroundStyle(AppColor.accent)
            Text(scope.kind.rawValue.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if scope.ownerID != nil {
                Button("Edit", systemImage: "square.and.pencil") {
                    onEdit()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Edit \(scope.kind.rawValue) variables in a tab")
            }
            Text("\(isFiltering ? visibleVariables.count : scope.variables.count)")
                .font(AppFont.countBadge)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, AppSpacing.medium)
        .padding(.trailing, AppSpacing.medium)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.small)
    }

    private var rows: some View {
        ForEach(Array(visibleVariables.enumerated()), id: \.element.id) { index, variable in
            VariableRow(
                variable: variable,
                // Disabled rows are excluded from resolution, so they never
                // earn the referenced-in-request marker.
                isUsed: variable.isEnabled && usedKeys.contains(variable.key.trimmingCharacters(in: .whitespacesAndNewlines)),
                overriddenBy: overrideLabels[variable.key.trimmingCharacters(in: .whitespacesAndNewlines)],
                revealedSecrets: $revealedSecrets
            )
            if index < visibleVariables.count - 1 {
                Divider()
                    .padding(.leading, Self.rowIndent)
            }
        }
    }

    private func hintRow(_ hint: (message: String, action: HintAction?)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xSmall) {
            Color.clear
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                Text(hint.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch hint.action {
                case .openEditor:
                    linkButton("Add Variables") { onEdit() }
                case .selectEnvironment:
                    SelectEnvironmentMenu()
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(.leading, AppSpacing.large)
        .padding(.trailing, AppSpacing.medium)
        .padding(.bottom, AppSpacing.small)
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        LinkButton(title, font: .caption.weight(.medium), action: action)
    }
}

/// Underlined menu link that switches the active environment, Postman's
/// "Select environment" action.
private struct SelectEnvironmentMenu: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            Button("No Environment") { store.setActiveEnvironment(nil) }
            if !store.activeWorkspaceEnvironments.isEmpty {
                Divider()
            }
            ForEach(store.activeWorkspaceEnvironments) { env in
                Button {
                    store.setActiveEnvironment(env.id)
                } label: {
                    if store.activeEnvironment?.id == env.id {
                        Label(env.name, systemImage: "checkmark")
                    } else {
                        Text(env.name)
                    }
                }
            }
        } label: {
            Text("Select Environment")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppColor.accent)
                .underline()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch the active environment")
    }
}

// MARK: - Variable row

/// One variable row: used-in-request marker, key, value (masked until
/// revealed for secrets), state badges, and hover actions.
private struct VariableRow: View {
    let variable: Variable
    let isUsed: Bool
    let overriddenBy: String?
    /// Value the row shows and copies - defaults to the variable's raw
    /// value; the resolved section passes the fully expanded value instead.
    var displayValue: String?
    /// Optional badge next to the key (the resolved section names the scope
    /// that wins when several define the key).
    var sourceLabel: String?
    @Binding var revealedSecrets: Set<UUID>
    @State private var isHovering = false
    /// Which hover action owns keyboard focus, if any. The actions stay
    /// visually hidden until hovered or focused - but unlike `disabled`,
    /// focus can always land on them, so keyboard and VoiceOver users can
    /// reveal and copy too.
    @FocusState private var focusedAction: ActionFocus?

    private enum ActionFocus: Hashable {
        case reveal, copy
    }

    private var trimmedKey: String {
        variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shownValue: String {
        displayValue ?? variable.value
    }

    private var isRevealed: Bool {
        revealedSecrets.contains(variable.id)
    }

    private var isMasked: Bool {
        variable.isSecret && !isRevealed
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xSmall) {
            Circle()
                .fill(isUsed ? AppColor.accent : Color.clear)
                .frame(width: 5, height: 5)
                .helpIf(!trimmedKey.isEmpty && isUsed, "Referenced by this request")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(trimmedKey.isEmpty ? "(blank key)" : trimmedKey)
                        .font(AppFont.monoSubheadline)
                        .foregroundStyle(variable.isEnabled ? .primary : .tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if !variable.isEnabled {
                        Badge(text: "Disabled")
                    }
                    if let sourceLabel {
                        Badge(text: sourceLabel)
                    }
                }
                valueText
                if let overriddenBy {
                    Badge(text: "Overridden by \(overriddenBy)")
                        .help("A higher-precedence scope defines this key, so this value is never used.")
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: AppSpacing.xSmall) {
                if variable.isSecret {
                    Button {
                        if isRevealed {
                            revealedSecrets.remove(variable.id)
                        } else {
                            revealedSecrets.insert(variable.id)
                        }
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .focused($focusedAction, equals: .reveal)
                    .accessibilityLabel(isRevealed ? "Hide value" : "Reveal value")
                    .help(isRevealed ? "Hide value" : "Reveal value")
                }
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(shownValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .focused($focusedAction, equals: .copy)
                .accessibilityLabel("Copy value")
                .help("Copy Value")
            }
            .font(.caption)
            .opacity(isHovering || focusedAction != nil ? 1 : 0)
            // The buttons fade with the row hover; an invisible button must
            // not keep hit-testing (stray clicks could reveal a secret or
            // overwrite the pasteboard with no visible control).
            .allowsHitTesting(isHovering || focusedAction != nil)
        }
        .padding(.leading, AppSpacing.large)
        .padding(.trailing, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder private var valueText: some View {
        Group {
            if isMasked {
                Text("••••••••")
            } else {
                Text(shownValue)
            }
        }
        .font(AppFont.monoCaption)
        .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }

    private var isDimmed: Bool {
        !variable.isEnabled || overriddenBy != nil
    }
}

// MARK: - Resolved variables

/// One flattened resolution outcome: a key the request references, the final
/// value the wire will carry, the winning variable (its identity drives
/// secret masking and reveal), and - when several scopes define the key -
/// the scope that wins.
private struct ResolvedEntry: Identifiable {
    let key: String
    let value: String
    let variable: Variable
    let source: VariableScope.Kind?

    var id: String { key }
}

/// The counterpart of the unresolved section: keys the request references
/// that do resolve, shown with the value they expand to at send time.
/// Hidden entirely when the request references nothing that resolves.
private struct ResolvedSection: View {
    let entries: [ResolvedEntry]
    @Binding var revealedSecrets: Set<UUID>

    var body: some View {
        VStack(spacing: 0) {
            Label("Resolved Variables", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColor.success)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.top, AppSpacing.small)
            ForEach(entries) { entry in
                VariableRow(
                    variable: entry.variable,
                    isUsed: true,
                    overriddenBy: nil,
                    displayValue: entry.value,
                    sourceLabel: entry.source.map { "From \($0.rawValue)" },
                    revealedSecrets: $revealedSecrets
                )
            }
            Divider()
        }
        .padding(.bottom, AppSpacing.small)
        .help("The values these placeholders expand to at send time; secrets stay masked until revealed.")
    }
}

// MARK: - Unresolved variables

/// Keys the request references but no enabled variable in any scope
/// defines - they will be sent literally instead of substituted - plus
/// placeholders stuck in a variable reference cycle, which also arrive on
/// the wire unsubstituted.
private struct UnresolvedSection: View {
    let keys: [String]
    var cyclicKeys: Set<String> = []

    private var orderedKeys: [String] {
        // Cyclic entries sort with the rest; the per-row label tells them
        // apart. `keys` and `cyclicKeys` are disjoint by construction, but
        // union defensively so a key never renders twice.
        Array(Set(keys).union(cyclicKeys)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Label("Unresolved Variables", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColor.warning)
            ForEach(orderedKeys, id: \.self) { key in
                HStack(spacing: AppSpacing.xSmall) {
                    Text(key)
                        .font(AppFont.monoCaption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if cyclicKeys.contains(key) {
                        Text("Cyclic reference")
                            .font(.caption2)
                            .foregroundStyle(AppColor.warning)
                    } else {
                        Text("Not defined")
                            .font(.caption2)
                            .foregroundStyle(AppColor.warning)
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .help("These variables are undefined or resolve toward a reference cycle, and will be sent literally.")
    }
}
