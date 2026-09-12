import AppKit
import SwiftUI

/// The "Variables in Request" inspector on the right edge of the detail area.
///
/// With a request selected it lists every variable in scope, grouped by scope
/// from lowest to highest precedence (workspace → collection → environment),
/// so `{{placeholder}}` resolution is easy to trace: disabled rows are
/// excluded from resolution, overridden rows are annotated with the scope
/// that wins, secrets are masked, and placeholders the request references but
/// no scope defines are flagged as unresolved.
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
            Divider()
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
    }

    // MARK: - Header

    private var header: some View {
        InspectorHeader(closeHelp: "Hide Variables (⇧⌘V)") {
            store.showVariablesSidebar = false
        }
    }

    // MARK: - Request context

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requestContent(for request: RequestItem) -> some View {
        let scopes = store.variableScopesForRequest(request)
        let usedKeys = Set(store.placeholdersUsedByRequest(request))
        let resolvedKeys = Set(store.variablesForRequest(request).keys)
        let unresolvedAll = usedKeys.subtracting(resolvedKeys).sorted()
        let unresolved = query.isEmpty ? unresolvedAll : unresolvedAll.filter { $0.localizedCaseInsensitiveContains(query) }
        return VStack(spacing: 0) {
            filterField
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(scopes) { scope in
                        ScopeSection(
                            scope: scope,
                            query: query,
                            usedKeys: usedKeys,
                            overrideLabels: overrideLabels(for: scope, in: scopes),
                            revealedSecrets: $revealedSecrets,
                            onEdit: { openEditor(for: scope) }
                        )
                    }
                    if !unresolved.isEmpty {
                        UnresolvedSection(keys: unresolved)
                    }
                }
            }
            .overlay {
                if !query.isEmpty && totalVisibleRows(in: scopes) == 0 && unresolved.isEmpty {
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
        FilterField(text: $filter, placeholder: "Filter Variables")
    }

    // MARK: - No request context (Postman's "All variables" view)

    private var workspaceContent: some View {
        let scopes = store.workspaceVariableScopes()
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(scopes) { scope in
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

    /// For each key, the nearest higher-precedence scope that defines it (the
    /// scope whose value actually wins). Scopes arrive lowest-first, so the
    /// first writer for a key while walking upward is the effective one.
    private func overrideLabels(for scope: RequestVariableScope, in scopes: [RequestVariableScope]) -> [String: String] {
        guard let index = scopes.firstIndex(where: { $0.id == scope.id }) else { return [:] }
        var labels: [String: String] = [:]
        for higher in scopes[(index + 1)...] {
            for variable in higher.variables where variable.isEnabled {
                let key = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                if labels[key] == nil { labels[key] = higher.kind.rawValue }
            }
        }
        return labels
    }

    private func openEditor(for scope: RequestVariableScope) {
        guard let ownerID = scope.ownerID else { return }
        switch scope.kind {
        case .workspace: store.openTab(.workspace(ownerID))
        case .collection: store.openTab(.collection(ownerID))
        case .environment: store.openEnvironment(ownerID)
        }
    }

    private func totalVisibleRows(in scopes: [RequestVariableScope]) -> Int {
        guard !query.isEmpty else { return 0 }
        return scopes.reduce(0) { count, scope in
            guard scope.ownerName != nil else { return count }
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

/// One scope (workspace, collection, or environment): header with the owner's
/// name and an edit shortcut, then its rows or a Postman-style hint with an
/// actionable link.
private struct ScopeSection: View {
    @Environment(AppStore.self) private var store
    let scope: RequestVariableScope
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
            VStack(alignment: .leading, spacing: 0) {
                Text(scope.kind.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(scope.ownerName ?? "None")
                    .font(.subheadline)
                    .lineLimit(1)
            }
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
            Text("\(scope.variables.count)")
                .font(AppFont.countBadge)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.leading, AppSpacing.medium)
        .padding(.trailing, AppSpacing.medium)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.xSmall)
    }

    private var rows: some View {
        ForEach(Array(visibleVariables.enumerated()), id: \.element.id) { index, variable in
            VariableRow(
                variable: variable,
                isUsed: usedKeys.contains(variable.key.trimmingCharacters(in: .whitespacesAndNewlines)),
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
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppColor.accent)
                .underline()
        }
        .buttonStyle(.plain)
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
    }
}

// MARK: - Variable row

/// One variable row: used-in-request marker, key, value (masked until
/// revealed for secrets), state badges, and hover actions.
private struct VariableRow: View {
    let variable: Variable
    let isUsed: Bool
    let overriddenBy: String?
    @Binding var revealedSecrets: Set<UUID>
    @State private var isHovering = false
    @FocusState private var actionsFocused: Bool

    private var trimmedKey: String {
        variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
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
                }
                valueText
                if let overriddenBy {
                    Text("Overridden by \(overriddenBy)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    .help(isRevealed ? "Hide value" : "Reveal value")
                }
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(variable.value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy Value")
            }
            .font(.caption)
            .focused($actionsFocused)
            .opacity(isHovering || actionsFocused ? 1 : 0)
            .disabled(!(isHovering || actionsFocused))
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
                Text(variable.value)
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

// MARK: - Unresolved placeholders

/// Placeholders the request references but no enabled variable in any scope
/// defines - they will be sent literally instead of substituted.
private struct UnresolvedSection: View {
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Label("Unresolved Placeholders", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColor.warning)
            ForEach(keys, id: \.self) { key in
                HStack(spacing: AppSpacing.xSmall) {
                    Text("{{\(key)}}")
                        .font(AppFont.monoCaption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Text("Not defined")
                        .font(.caption2)
                        .foregroundStyle(AppColor.warning)
                }
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .help("These placeholders have no enabled variable in any scope and will be sent literally.")
    }
}
