import SwiftUI
import UniformTypeIdentifiers

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
    /// Drag-to-reorder rows via a grip handle (query params, headers, and
    /// environment variables). Off by default; each table opts in when order
    /// is editable.
    var allowsReorder: Bool = false

    /// The in-progress trailing row. Display-only until the user types into
    /// it; then it materializes into `items` and focus follows the materialized
    /// row while a fresh empty row appears below.
    /// Plain `@State`, not `@FocusState`: the cells are AppKit fields managed
    /// by `VariableHighlightEditor` (first-responder based), and an unregistered
    /// `@FocusState` made writes no-ops and reads always nil - focus moves
    /// silently failed, and per-update re-focus logic restarted the editing
    /// session on every keystroke (fresh sessions select all, so typing
    /// overwrote the whole text).
    @State private var ghost: T?
    @State private var focusedCell: CellFocus?
    /// Row being dragged for reorder, and the row currently under it.
    @State private var draggingID: UUID?
    @State private var dropTargetID: UUID?
    @State private var dropTargetEnd = false

    /// Candidates shown by every cell's `{{` completion popup.
    private var rowSuggestions: [VariableSuggestion] {
        suggestions ?? VariableSuggestion.suggestions(from: variables)
    }

    /// Fixed widths for the non-text columns; Key and Value split the
    /// remaining width equally, matching the header labels above. Reorder
    /// tables merge the drag grip and the checkbox into one leading column
    /// (two icons, one cell) so the grid carries one hairline fewer.
    private let toggleColumnWidth: CGFloat = 32
    private let gripGlyphWidth: CGFloat = 14
    private let deleteColumnWidth: CGFloat = 26
    private var secretColumnWidth: CGFloat { secretKeyPath == nil ? 0 : 26 }
    private var leadingColumnWidth: CGFloat { allowsReorder ? 38 : toggleColumnWidth }

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
                    leadingColumnWidth: leadingColumnWidth,
                    deleteColumnWidth: deleteColumnWidth,
                    onDelete: { [id = item.id] in
                        items.removeAll { $0.id == id }
                        if ghost?.id == id { ghost = nil }
                    },
                    onGripDrag: allowsReorder ? { dragProvider(for: item.id) } : nil,
                    onMoveUp: allowsReorder ? { moveRow(id: item.id, by: -1) } : nil,
                    onMoveDown: allowsReorder ? { moveRow(id: item.id, by: 1) } : nil,
                    isDragging: draggingID == item.id,
                    isDropTargeted: dropTargetID == item.id,
                    allowsReorder: allowsReorder
                )
                .onDrop(of: [.text], isTargeted: dropTargeted(for: item.id)) { _ in
                    moveDraggedRow(to: item.id)
                }
                Divider()
            }
            // The permanently present empty row (Postman-style). Its cells
            // report when their editing session ends: the ghost then resets
            // to an empty buffer - the real row owns the content from there.
            // It is also a drop target: dropping here moves the row to the end.
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
                leadingColumnWidth: leadingColumnWidth,
                deleteColumnWidth: deleteColumnWidth,
                onEditingEnded: { ghost = nil },
                allowsReorder: allowsReorder
            )
            .onDrop(of: [.text], isTargeted: $dropTargetEnd) { _ in
                moveDraggedRowToEnd()
            }
            .overlay(alignment: .bottom) {
                if allowsReorder && dropTargetEnd {
                    Rectangle()
                        .fill(AppColor.accent)
                        .frame(height: 2)
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .strokeBorder(AppColor.border, lineWidth: 1)
        )
    }

    private var headerRow: some View {
        // Icon columns (leading checkbox/grip, secret, delete) get no header
        // cells: empty ruled boxes read as missing labels. A single indent
        // keeps the text labels over their columns instead.
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingIconWidth)
            headerLabel(keyHeader)
            verticalRule
            headerLabel(valueHeader)
            Color.clear.frame(width: trailingIconWidth)
        }
        .frame(height: AppSize.tabHeight)
    }

    /// Indent matching the body rows' leading icon column (including its
    /// 1pt hairline) so the text labels land exactly over the cells.
    private var leadingIconWidth: CGFloat {
        leadingColumnWidth + 1
    }

    /// Reserve the same trailing columns and hairlines as the body so Key
    /// and Value divide the same remaining width in both header and rows.
    private var trailingIconWidth: CGFloat {
        1 + (secretColumnWidth > 0 ? secretColumnWidth + 1 : 0) + deleteColumnWidth
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

    /// Once the ghost's editing session ends (focus moved to the materialized
    /// row or elsewhere), the real row owns the content from here on: the
    /// buffer resets and the trailing row is empty again.
    private func settleGhost() {
        ghost = nil
    }

    // MARK: - Reorder

    /// Drag payload for a row: the row id as text. Drops are accepted only
    /// from our own grips (see `draggingID`), so foreign text cannot
    /// re-sort the table.
    private func dragProvider(for id: UUID) -> NSItemProvider {
        draggingID = id
        return NSItemProvider(object: id.uuidString as NSString)
    }

    private func dropTargeted(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { dropTargetID == id },
            set: {
                if $0 { dropTargetID = id } else if dropTargetID == id { dropTargetID = nil }
            }
        )
    }

    /// Moves the dragged row to `id`'s position.
    private func moveDraggedRow(to id: UUID) -> Bool {
        defer {
            draggingID = nil
            dropTargetID = nil
            dropTargetEnd = false
        }
        guard allowsReorder,
            let fromID = draggingID,
            let fromIndex = items.firstIndex(where: { $0.id == fromID }),
            let toIndex = items.firstIndex(where: { $0.id == id }),
            fromIndex != toIndex
        else { return false }
        withAnimation {
            items.move(fromOffsets: [fromIndex], toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
        return true
    }

    /// Moves the dragged row to the end (dropped on the trailing empty row).
    private func moveDraggedRowToEnd() -> Bool {
        defer {
            draggingID = nil
            dropTargetID = nil
            dropTargetEnd = false
        }
        guard allowsReorder,
            let fromID = draggingID,
            let fromIndex = items.firstIndex(where: { $0.id == fromID }),
            fromIndex != items.count - 1
        else { return false }
        withAnimation {
            items.move(fromOffsets: [fromIndex], toOffset: items.count)
        }
        return true
    }

    /// Keyboard/context-menu reorder step (the grip is pointer-only).
    private func moveRow(id: UUID, by delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard items.indices.contains(target) else { return }
        withAnimation {
            items.move(fromOffsets: [index], toOffset: delta > 0 ? target + 1 : target)
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
                && row.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && row.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    let focus: Binding<CellFocus?>
    let keyFocus: CellFocus
    let valueFocus: CellFocus
    /// Width of the merged leading column: drag grip (when reorder is on)
    /// plus the enabled checkbox share one cell and one hairline.
    let leadingColumnWidth: CGFloat
    let deleteColumnWidth: CGFloat
    private let gripGlyphWidth: CGFloat = 14
    /// nil for real rows; the trailing ghost row reports its editing session's
    /// end through this so the table can reset the ghost buffer.
    var onEditingEnded: (() -> Void)?
    /// nil for the trailing ghost row (nothing to delete yet).
    var onDelete: (() -> Void)?
    /// Drag-to-reorder: nil unless `allowsReorder`. The grip is pointer-only;
    /// keyboard users get Move Up/Down instead.
    var onGripDrag: (() -> NSItemProvider)?
    /// Keyboard/context-menu reorder steps; nil unless `allowsReorder`.
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    /// Dimmed while dragged; shows the insertion line while targeted.
    var isDragging: Bool = false
    var isDropTargeted: Bool = false
    var allowsReorder: Bool = false

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
            // One merged leading cell: drag grip (pointer-only, on hover)
            // and the enabled checkbox share a single column and hairline.
            // The frame centers the icon group so the grip's left inset
            // mirrors the checkbox's right inset. The trailing ghost row
            // keeps an empty grip slot - nothing to drag yet - so its
            // checkbox lines up with the real rows.
            HStack(spacing: AppSpacing.xxSmall) {
                if allowsReorder {
                    if isGhostRow {
                        Color.clear
                            .frame(width: gripGlyphWidth)
                    } else {
                        Image(systemName: "line.3.horizontal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: gripGlyphWidth)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .opacity(isHovering || isDragging ? 1 : 0)
                            .onDrag {
                                guard let onGripDrag else { return NSItemProvider() }
                                return onGripDrag()
                            }
                            .onHover { hovering in
                                // The grip drags the row: swap in the hand
                                // cursor while the pointer is over it.
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                    }
                }
                Toggle("", isOn: isGhostRow ? .constant(false) : $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(isGhostRow)
                    .helpIf(!isGhostRow, isEnabled ? "Disable row" : "Enable row")
            }
            .frame(width: leadingColumnWidth)
            verticalRule
            cell {
                VariableHighlightEditor(
                    text: $key,
                    variables: variables,
                    suggestions: suggestions,
                    placeholder: keyPlaceholder,
                    focus: focus,
                    focusValue: keyFocus,
                    onEditingEnded: onEditingEnded
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
                    focusValue: valueFocus,
                    onEditingEnded: onEditingEnded
                )
            }
            verticalRule
            if secretColumnWidth > 0 {
                secretColumn
                    .frame(width: secretColumnWidth)
                verticalRule
            }
            deleteColumn
        }
        .frame(height: AppSize.toolbarHeight)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(isDragging ? 0.5 : 1)
        .overlay(alignment: .top) {
            if allowsReorder && isDropTargeted {
                Rectangle()
                    .fill(AppColor.accent)
                    .frame(height: 2)
            }
        }
        .contextMenu {
            if let onMoveUp {
                Button("Move Up") { onMoveUp() }
            }
            if let onMoveDown {
                Button("Move Down") { onMoveDown() }
            }
        }
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
