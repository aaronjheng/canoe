import SwiftUI

/// A protocol for editable key/value rows (query params and headers share the
/// same UI).
protocol KVItem: Identifiable, Hashable {
    var id: UUID { get set }
    var key: String { get set }
    var value: String { get set }
    var isEnabled: Bool { get set }
}

extension HTTPHeader: KVItem {}
extension QueryParam: KVItem {}
extension FormField: KVItem {}
extension Variable: KVItem {}

/// Which cell owns keyboard focus. Real rows address their id; the trailing
/// ghost row has its own markers.
private enum CellFocus: Hashable {
    case key(UUID)
    case value(UUID)
    case ghostKey
    case ghostValue
}

/// Postman-style key/value table: a bordered grid with a column header row
/// (labels configurable, "Key | Value" by default), dense borderless cells
/// separated by hairlines, and a permanently present trailing empty row -
/// typing into it materializes a real row and a fresh empty row appears
/// below, so adding entries never needs a separate button. Used for query
/// params, headers, form fields, and the variables tables (environment,
/// collection, workspace), which add a secret eye column.
struct KeyValueEditor<T: KVItem>: View {
    @Binding var items: [T]
    let makeNew: () -> T
    /// Optional section title rendered above the table (Postman shows
    /// "Query Params" above the params grid).
    var title: String?
    /// Resolved variable scope for `{{placeholder}}` highlighting.
    var variables: [String: String] = [:]
    /// Completion candidates for `{{` auto-completion; nil derives names
    /// from `variables`.
    var suggestions: [VariableSuggestion]?
    var keyPlaceholder: String = "key"
    var valuePlaceholder: String = "value"
    /// Header labels above the two text columns (the variables tables say
    /// "Variable" instead of "Key").
    var keyHeader: String = "Key"
    var valueHeader: String = "Value"
    /// Optional per-row secret column: when set to the item's flag, each row
    /// shows an eye button toggling it (environment variables' `isSecret`).
    var secretKeyPath: WritableKeyPath<T, Bool>?

    /// The in-progress trailing row. Display-only until the user types into
    /// it; then it materializes into `items` and focus follows the materialized
    /// row while a fresh empty row appears below.
    @State private var ghost: T?
    @FocusState private var focusedCell: CellFocus?

    /// Candidates shown by every cell's `{{` completion popup.
    private var rowSuggestions: [VariableSuggestion] {
        suggestions ?? VariableSuggestion.suggestions(from: variables)
    }

    /// Fixed widths for the two non-text columns; Key and Value split the
    /// remaining width equally, matching the header labels above.
    private let toggleColumnWidth: CGFloat = 32
    private let deleteColumnWidth: CGFloat = 26
    private var secretColumnWidth: CGFloat { secretKeyPath == nil ? 0 : 26 }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title)
                        .font(AppFont.sectionTitle)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.top, AppSpacing.small)
                .padding(.bottom, AppSpacing.xSmall)
            }
            ScrollView {
                table
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.bottom, AppSpacing.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .onChange(of: focusedCell) { _, newValue in
            settleGhost(afterFocusChange: newValue)
            pruneAbandonedEmptyRows(newValue)
        }
    }

    // MARK: - Table

    private var table: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ForEach($items) { $item in
                KVRow(
                    isEnabled: $item.isEnabled,
                    key: $item.key,
                    value: $item.value,
                    isSecret: secretKeyPath.map { path in
                        Binding<Bool>(
                            get: { item[keyPath: path] },
                            set: { item[keyPath: path] = $0 }
                        )
                    },
                    secretColumnWidth: secretColumnWidth,
                    variables: variables,
                    suggestions: rowSuggestions,
                    keyPlaceholder: keyPlaceholder,
                    valuePlaceholder: valuePlaceholder,
                    focus: $focusedCell,
                    keyFocus: .key(item.id),
                    valueFocus: .value(item.id),
                    toggleColumnWidth: toggleColumnWidth,
                    deleteColumnWidth: deleteColumnWidth,
                    onDelete: { [id = item.id] in
                        items.removeAll { $0.id == id }
                        if ghost?.id == id { ghost = nil }
                    }
                )
                Divider()
            }
            // The permanently present empty row (Postman-style).
            KVRow(
                isEnabled: ghostEnabledBinding,
                key: ghostBinding(\.key, focusOn: { .key($0) }),
                value: ghostBinding(\.value, focusOn: { .value($0) }),
                isSecret: nil,
                secretColumnWidth: secretColumnWidth,
                variables: variables,
                suggestions: rowSuggestions,
                keyPlaceholder: keyPlaceholder,
                valuePlaceholder: valuePlaceholder,
                focus: $focusedCell,
                keyFocus: .ghostKey,
                valueFocus: .ghostValue,
                toggleColumnWidth: toggleColumnWidth,
                deleteColumnWidth: deleteColumnWidth
            )
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .strokeBorder(AppColor.border, lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: toggleColumnWidth)
            verticalRule
            headerLabel(keyHeader)
            verticalRule
            headerLabel(valueHeader)
            verticalRule
            if secretColumnWidth > 0 {
                Color.clear.frame(width: secretColumnWidth)
                verticalRule
            }
            Color.clear.frame(width: deleteColumnWidth)
        }
        .frame(height: 28)
    }

    private func headerLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ghost row (trailing empty row)

    private var ghostEnabledBinding: Binding<Bool> {
        Binding(
            get: { ghost?.isEnabled ?? true },
            set: {
                var row = ghost ?? makeNew()
                row.isEnabled = $0
                ghost = row
            }
        )
    }

    /// Editing the ghost row: the first character materializes it into
    /// `items` and moves keyboard focus to the materialized row, so typing
    /// continues seamlessly. Clearing a materialized row removes it again.
    private func ghostBinding(
        _ keyPath: WritableKeyPath<T, String>,
        focusOn: @escaping (UUID) -> CellFocus
    ) -> Binding<String> {
        Binding(
            get: { ghost?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var row = ghost ?? makeNew()
                row[keyPath: keyPath] = newValue
                let isEmpty = row.key.isEmpty && row.value.isEmpty
                if let index = items.firstIndex(where: { $0.id == row.id }) {
                    if isEmpty {
                        items.remove(at: index)
                    } else {
                        items[index] = row
                    }
                } else if !isEmpty {
                    items.append(row)
                }
                ghost = row
                focusedCell = isEmpty ? nil : focusOn(row.id)
            }
        )
    }

    /// Once focus lands on the materialized row, the ghost resets to an empty
    /// buffer - the real row owns the content from here on.
    private func settleGhost(afterFocusChange newValue: CellFocus?) {
        guard let ghost else { return }
        switch newValue {
        case .key(let id), .value(let id):
            if id == ghost.id { self.ghost = nil }
        case .ghostKey, .ghostValue, nil:
            break
        }
    }

    /// Postman-style hygiene: a row left completely blank is removed once the
    /// user moves focus elsewhere, so emptied rows never pile up in the model.
    private func pruneAbandonedEmptyRows(_ newValue: CellFocus?) {
        let focusedRowID: UUID?
        switch newValue {
        case .key(let id), .value(let id): focusedRowID = id
        case .ghostKey, .ghostValue, nil: focusedRowID = nil
        }
        items.removeAll { row in
            row.id != focusedRowID
                && row.key.trimmingCharacters(in: .whitespaces).isEmpty
                && row.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var verticalRule: some View {
        Rectangle()
            .fill(AppColor.hairline)
            .frame(width: 1)
    }
}

// MARK: - Row

/// One table row: checkbox, borderless key/value cells split by hairlines,
/// and a delete button that only appears while hovering (Postman-style).
private struct KVRow: View {
    @Binding var isEnabled: Bool
    @Binding var key: String
    @Binding var value: String
    /// nil for the trailing ghost row (nothing to hide yet) and for tables
    /// without a secret column.
    var isSecret: Binding<Bool>?
    let secretColumnWidth: CGFloat
    let variables: [String: String]
    let suggestions: [VariableSuggestion]
    let keyPlaceholder: String
    let valuePlaceholder: String
    let focus: FocusState<CellFocus?>.Binding
    let keyFocus: CellFocus
    let valueFocus: CellFocus
    let toggleColumnWidth: CGFloat
    let deleteColumnWidth: CGFloat
    /// nil for the trailing ghost row (nothing to delete yet).
    var onDelete: (() -> Void)?

    @State private var isHovering = false

    private var isGhostRow: Bool { onDelete == nil }

    /// Keyboard users tab into the row's cells without hovering: keep the
    /// delete visible while either cell owns focus so it stays reachable.
    private var isRowFocused: Bool {
        focus.wrappedValue == keyFocus || focus.wrappedValue == valueFocus
    }

    private var isDeleteVisible: Bool { isHovering || isRowFocused }

    var body: some View {
        HStack(spacing: 0) {
            // The trailing ghost row shows an unchecked, inert checkbox: it
            // only becomes a real (checked) row once the user types into it.
            Toggle("", isOn: isGhostRow ? .constant(false) : $isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(isGhostRow)
                .frame(width: toggleColumnWidth)
            verticalRule
            cell {
                VariableHighlightEditor(
                    text: $key,
                    variables: variables,
                    suggestions: suggestions,
                    placeholder: keyPlaceholder,
                    focus: focus,
                    focusValue: keyFocus
                )
            }
            verticalRule
            cell {
                VariableHighlightEditor(
                    text: $value,
                    variables: variables,
                    suggestions: suggestions,
                    placeholder: valuePlaceholder,
                    focus: focus,
                    focusValue: valueFocus
                )
            }
            verticalRule
            if secretColumnWidth > 0 {
                secretColumn
                verticalRule
            }
            deleteColumn
        }
        .frame(height: 32)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// A borderless spreadsheet-like cell; disabled rows dim, like Postman.
    private func cell(@ViewBuilder field: () -> some View) -> some View {
        field()
            .font(AppFont.cellText)
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .opacity(isEnabled ? 1 : 0.5)
            .padding(.horizontal, AppSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Eye button toggling the row's secret flag; the ghost row only
    /// reserves the space.
    @ViewBuilder
    private var secretColumn: some View {
        if let isSecret {
            Button {
                isSecret.wrappedValue.toggle()
            } label: {
                Image(systemName: isSecret.wrappedValue ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isSecret.wrappedValue ? "Hidden (secret)" : "Shown (toggle to hide)")
        } else {
            Color.clear
        }
    }

    private var deleteColumn: some View {
        Group {
            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isDeleteVisible ? 1 : 0)
                .disabled(!isDeleteVisible)
                .help("Remove row")
            } else {
                Color.clear
            }
        }
        .frame(width: deleteColumnWidth)
    }

    private var verticalRule: some View {
        Rectangle()
            .fill(AppColor.hairline)
            .frame(width: 1)
    }
}
