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

struct KeyValueReadOnlyItem: Identifiable, Hashable {
    let id: String
    let key: String
    let value: String
    var isMuted: Bool = false
    /// Whether the leading checkbox is interactive. On for generated rows
    /// the user may disable (every request generated header except
    /// Authorization); off for fixed display (response headers, the masked
    /// Authorization row).
    var isToggleable: Bool = false
    /// Info glyph trailing the key cell ("Calculated when request is sent").
    /// On for the request's generated headers; off for display-only tables
    /// such as the response headers, where nothing is calculated.
    var showsKeyInfo: Bool = true
}

struct KeyValueEditorTitleAction {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void
}

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
    var titleAction: KeyValueEditorTitleAction?
    var readOnlyItems: [KeyValueReadOnlyItem] = []
    /// Whether the trailing in-progress row is drawn. Read-only displays
    /// (the response headers) have nothing to type into, so they hide it.
    var showsGhostRow: Bool = true
    /// Drop the leading checkbox and trailing action columns (and their
    /// rules): the grid becomes a bare Key | Value table for pure content
    /// display - the response headers. Read-only tables only; editable rows
    /// need those columns for their controls.
    var showsIconColumns: Bool = true
    /// Gray wash behind the read-only rows: the request's auto-generated
    /// headers are filler, not user data (Postman shades them the same
    /// way). Off by default - display-only tables such as the response
    /// headers show real returned data, so they stay clean.
    var highlightsGeneratedRows: Bool = false
    /// IDs of read-only rows the user unchecked, and the toggle callback.
    /// Only consulted for rows flagged `isToggleable` with a callback set;
    /// everything else renders the fixed checked box.
    var disabledReadOnlyIDs: Set<String> = []
    var onToggleReadOnly: ((String) -> Void)?
    /// Resolved variable scope for `{{placeholder}}` highlighting.
    var variables: [String: String] = [:]
    /// Completion candidates for `{{` auto-completion; nil derives names
    /// from `variables`.
    var suggestions: [VariableSuggestion]?
    var keyPlaceholder: String = "Key"
    var valuePlaceholder: String = "Value"
    /// Header labels above the two text columns (the variables tables say
    /// "Variable" instead of "Key").
    var keyHeader: String = "Key"
    var valueHeader: String = "Value"
    /// Column-header fill for the table. Defaults to the shared gray wash so
    /// every key/value grid reads as a table; callers may still override.
    var headerBackground: Color? = AppColor.tableHeaderBackground
    /// Optional per-row secret column: when set to the item's flag, each row
    /// shows an eye button toggling it (environment variables' `isSecret`).
    var secretKeyPath: WritableKeyPath<T, Bool>?
    /// Drag-to-reorder rows via a grip handle (query params, headers, and
    /// environment variables). Off by default; each table opts in when order
    /// is editable.
    var allowsReorder: Bool = false
    /// Whether the table scrolls inside its own pane (the default: a
    /// section content that fills the pane). When false the table renders
    /// at its content height and the CALLER owns scrolling — used by the
    /// Params section, where the query table and the path variables table
    /// stack in one shared scroll view (Postman's layout).
    var scrollsInternally: Bool = true
    /// Whether rows offer the hover trash (rows can be removed). The path
    /// variables table turns this off: its rows derive from the URL, so
    /// deleting one would just resurrect on the next derivation.
    var allowsDelete: Bool = true
    /// Renders every row's KEY cell muted and non-editable (Postman's path
    /// variables: the key is derived from the URL, only the value is
    /// editable). The cell also opts out of hover/focus chrome.
    var disablesKeyCell: Bool = false
    /// Click-to-sort the key column via its header (workspace variables).
    /// Off by default: ordered tables like query params keep their sequence.
    var allowsKeySort: Bool = false
    /// Form-data only: when set, each row's key cell ends with a Type
    /// (Text/File) dropdown (Postman form-data) and file rows swap the value
    /// cell for a file picker. Keys off `FormField.fieldKind`.
    var kindKeyPath: WritableKeyPath<T, FormFieldKind>?
    /// Postman-style Bulk Edit: adds the table ↔ text toggle ("Bulk Edit" /
    /// "Key-Value Edit") that swaps the grid for a `key: value`-per-line
    /// text editor. Enabled rows only - disabled rows survive the round
    /// trip untouched - and deliberately not offered to tables with file
    /// rows (the Type dropdown cannot be expressed in text, so switching
    /// would silently convert file uploads to text).
    var allowsBulkEdit: Bool = false

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
    /// Active key-column sort from the header click; nil until first used.
    @State private var keySortOrder: KeySortOrder?
    /// Bulk Edit mode: the grid is swapped for a text editor whose lines
    /// are `key: value` pairs, synced live back into `items`.
    @State private var isBulkMode = false
    @State private var bulkText = ""

    /// Candidates shown by every cell's `{{` completion popup.
    private var rowSuggestions: [VariableSuggestion] {
        suggestions ?? VariableSuggestion.suggestions(from: variables)
    }

    /// Fixed widths for the non-text columns; Key and Value split the
    /// remaining width equally, matching the header labels above. Reorder
    /// tables merge the drag grip and the checkbox into one leading column
    /// (two icons, one cell); the secret eye and the delete button merge
    /// the same way into one trailing column. Neither icon column carries
    /// an inner hairline: they open toward the text columns (the leading
    /// column drops its right rule, the trailing its left), so the action
    /// glyphs read as floating on the row, not as cells of the grid.
    private let toggleColumnWidth: CGFloat = 32
    /// Width of the header's Bulk Edit cell (rule + button). Body rows
    /// reserve the same trailing space, so the header's Key/Value columns
    /// and their rules line up with the rows' dividers.
    private let bulkEditCellWidth: CGFloat = 88
    private let gripGlyphWidth: CGFloat = 14
    private let deleteColumnWidth: CGFloat = 26
    // Wide enough for the checkmark gutter plus "File" at the small size,
    // so the dropdown never truncates its own label.
    private let kindMenuWidth: CGFloat = 84
    private var secretColumnWidth: CGFloat { secretKeyPath == nil ? 0 : 26 }
    private var showsKindMenu: Bool { kindKeyPath != nil }
    private var leadingColumnWidth: CGFloat {
        guard showsIconColumns else { return 0 }
        return allowsReorder ? 38 : toggleColumnWidth
    }
    /// Merged trailing icon column. Eye and trash share one fixed glyph box
    /// each (18pt, squared so SF Symbols of different widths match) with the
    /// leading column's 2pt group gap, plus 4pt side insets so neither glyph
    /// hugs the table border: 4 + 18 + 2 + 18 + 4 = 46pt. Tables without a
    /// secret column keep the lone delete cell in a 26pt column (4pt insets
    /// around the same 18pt box).
    private var trailingColumnWidth: CGFloat {
        guard showsIconColumns else { return 0 }
        return secretColumnWidth > 0 ? 46 : deleteColumnWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title)
                        .font(AppFont.sectionTitle)
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer(minLength: 0)
                    if let titleAction {
                        Button(action: titleAction.action) {
                            Label(titleAction.title, systemImage: titleAction.systemImage)
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(SecondaryButtonStyle(minHeight: AppSize.controlHeight))
                        .help(titleAction.help)
                    }
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.top, AppSpacing.small)
                .padding(.bottom, AppSpacing.xSmall)
            }
            if isBulkMode {
                bulkEditor
            } else if scrollsInternally {
                ScrollView {
                    table
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.bottom, AppSpacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                table
                    .padding(.horizontal, AppSpacing.medium)
                    .padding(.bottom, AppSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: scrollsInternally ? .infinity : nil, maxHeight: scrollsInternally ? .infinity : nil, alignment: .top)
        .background(AppColor.controlBackground)
        .onChange(of: focusedCell) { _, newValue in
            pruneAbandonedEmptyRows(newValue)
            updateBlurMonitor()
        }
        .onDisappear { removeBlurMonitor() }
    }

    // MARK: - Click-outside blur

    /// While a table cell owns keyboard focus, a click anywhere outside
    /// that field editor (blank areas, buttons, other panes) retires the
    /// field editor — Postman's click-away commit. Without this, a raw
    /// NSTextField keeps first responder on blank clicks, since nothing in
    /// the hit path takes focus. Installed only while a cell is focused;
    /// clicks inside the field editor pass untouched, clicks on other
    /// controls resign before their own handling runs.
    @State private var blurMonitor: Any?

    private func updateBlurMonitor() {
        if focusedCell != nil {
            installBlurMonitor()
        } else {
            removeBlurMonitor()
        }
    }

    private func installBlurMonitor() {
        guard blurMonitor == nil else { return }
        blurMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard focusedCell != nil else { return }
                guard let window = event.window, let textView = window.firstResponder as? NSTextView,
                    textView.isFieldEditor
                else { return }
                // A click inside the editing field itself is a caret move,
                // not a dismissal. Anything else retires the field editor
                // (click-away commit).
                let editorFrame = textView.convert(textView.bounds, to: nil)
                if !editorFrame.contains(event.locationInWindow) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func removeBlurMonitor() {
        if let blurMonitor {
            NSEvent.removeMonitor(blurMonitor)
            self.blurMonitor = nil
        }
    }

    // MARK: - Bulk Edit

    /// The text-mode surface: a trailing "Key-Value Edit" toggle (where the
    /// table's toggle sits), then the same bordered chrome around a
    /// monospaced, `{{variable}}`-aware editor. Lines sync live into
    /// `items` while typing.
    private var bulkEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                LinkButton("Key-Value Edit") { isBulkMode = false }
                    .help("Switch back to the key-value table")
            }
            .frame(height: AppSize.tableRowHeight)
            .padding(.horizontal, AppSpacing.medium)
            // Explicit specialization: the bulk editor wires no programmatic
            // focus, so FocusValue would otherwise be uninferable.
            VariableHighlightEditor<Bool>(
                text: $bulkText,
                variables: variables,
                suggestions: rowSuggestions,
                isSingleLine: false,
                fillsContainer: true,
                font: .monoBody,
                placeholder: "key: value\nheader: value"
            )
            .background(AppColor.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .strokeBorder(AppColor.tableBorder, lineWidth: AppLine.field)
            )
            .padding(.horizontal, AppSpacing.medium)
            .padding(.bottom, AppSpacing.medium)
        }
        .onChange(of: bulkText) { _, newValue in
            applyBulkText(newValue)
        }
    }

    /// Enters Bulk Edit: the text starts from the enabled rows (disabled
    /// rows are invisible there and survive untouched); table focus state
    /// is reset so nothing leaks across the mode switch.
    private func enterBulkMode() {
        bulkText =
            items
            .filter { $0.isEnabled }
            .filter { !$0.key.isEmpty || !$0.value.isEmpty }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        ghost = nil
        focusedCell = nil
        isBulkMode = true
    }

    /// One `key: value` per line: the first colon splits (values may
    /// contain colons), a colon-less line becomes a bare key. Enabled
    /// rows are rebuilt in text order; disabled rows keep their position
    /// at the end, in their original order, so toggling in the table and
    /// editing in text never destroy each other.
    ///
    /// Existing enabled rows are reused so steady-state typing does not
    /// churn row identity (SwiftUI row diffing, drag state) — a line only
    /// materializes a fresh row when no enabled row matches anymore.
    /// Tables without a secret column (params, headers) match by
    /// `(key, value)`: duplicate keys are legal there, so only the exact
    /// pair proves a line is the same row. Variable tables (the ones with
    /// a secret column) match by key alone: keys are unique, and rows
    /// carry flags outside the text (the secret eye) that would be
    /// silently reset if an edited value spun up a fresh row.
    private func applyBulkText(_ text: String) {
        var parsed: [T] = []
        parsed.reserveCapacity(text.count / 8 + 1)
        // Reuse pool: the enabled rows currently in the model, in order.
        var reusable = items.filter(\.isEnabled)
        let reuseByKey = secretKeyPath != nil
        for line in text.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else { continue }
            let key: String
            let value: String
            if let colon = line.firstIndex(of: ":") {
                key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                key = trimmedLine
                value = ""
            }
            let row: T
            if let index = reusable.firstIndex(where: reuseByKey ? { $0.key == key } : { $0.key == key && $0.value == value }) {
                var reused = reusable.remove(at: index)
                if reuseByKey { reused.value = value }
                row = reused
            } else {
                var fresh = makeNew()
                fresh.key = key
                fresh.value = value
                fresh.isEnabled = true
                row = fresh
            }
            parsed.append(row)
        }
        items = parsed + items.filter { !$0.isEnabled }
    }

    // MARK: - Table

    private var table: some View {
        VStack(spacing: 0) {
            headerRow
            // The header's bottom rule is drawn on the table's own border
            // token, not the stock `Divider()`: the system separator color
            // is a different grey from `tableBorder`, so the header's bottom
            // edge read darker than the grid it terminates.
            Rectangle()
                .fill(AppColor.tableBorder)
                .frame(height: AppLine.hairline)
            ForEach(readOnlyItems) { item in
                ReadOnlyKVRow(
                    key: item.key,
                    value: item.value,
                    isMuted: item.isMuted,
                    isGenerated: highlightsGeneratedRows,
                    isOn: !disabledReadOnlyIDs.contains(item.id),
                    onToggle: item.isToggleable ? { onToggleReadOnly?(item.id) } : nil,
                    showsKeyInfo: item.showsKeyInfo,
                    showsIconColumns: showsIconColumns,
                    leadingColumnWidth: leadingColumnWidth,
                    trailingColumnWidth: trailingColumnWidth,
                    showsGrip: allowsReorder,
                    gripWidth: gripGlyphWidth
                )
            }
            ForEach($items) { $item in
                let kindBinding = kindKeyPath.map { path -> Binding<FormFieldKind> in
                    Binding(
                        get: { item[keyPath: path] },
                        set: { item[keyPath: path] = $0 }
                    )
                }
                let secretBinding = secretKeyPath.map { path -> Binding<Bool> in
                    Binding(
                        get: { item[keyPath: path] },
                        set: { item[keyPath: path] = $0 }
                    )
                }
                KVRow(
                    isEnabled: $item.isEnabled,
                    key: $item.key,
                    value: $item.value,
                    kind: kindBinding,
                    showsKindMenu: showsKindMenu,
                    kindMenuWidth: kindMenuWidth,
                    isKeyDisabled: disablesKeyCell,
                    isSecret: secretBinding,
                    secretColumnWidth: secretColumnWidth,
                    variables: variables,
                    suggestions: rowSuggestions,
                    keyPlaceholder: keyPlaceholder,
                    valuePlaceholder: valuePlaceholder,
                    focus: $focusedCell,
                    keyFocus: .key(item.id),
                    valueFocus: .value(item.id),
                    leadingColumnWidth: leadingColumnWidth,
                    trailingColumnWidth: trailingColumnWidth,
                    onDelete: allowsDelete
                        ? { [id = item.id] in
                            items.removeAll { $0.id == id }
                            if ghost?.id == id { ghost = nil }
                        }
                        : nil,
                    bulkEditCellWidth: allowsBulkEdit ? bulkEditCellWidth : 0,
                    onGripDrag: allowsReorder ? { dragProvider(for: item.id) } : nil,
                    onMoveUp: allowsReorder ? { moveRow(id: item.id, by: -1) } : nil,
                    onMoveDown: allowsReorder ? { moveRow(id: item.id, by: 1) } : nil,
                    isDragging: draggingID == item.id,
                    isDropTargeted: dropTargetID == item.id,
                    dropTarget: dropTargeted(for: item.id),
                    onDropRow: { moveDraggedRow(to: item.id) },
                    allowsReorder: allowsReorder
                )
            }
            // The permanently present empty row (Postman-style). Its cells
            // report when their editing session ends: the ghost then resets
            // to an empty buffer - the real row owns the content from there.
            // It is also a drop target: dropping here moves the row to the end.
            if showsGhostRow {
                KVRow(
                    isEnabled: ghostEnabledBinding,
                    key: ghostBinding(\.key, focusOn: { .key($0) }),
                    value: ghostBinding(\.value, focusOn: { .value($0) }),
                    kind: ghostKindBinding,
                    showsKindMenu: showsKindMenu,
                    kindMenuWidth: kindMenuWidth,
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
                    trailingColumnWidth: trailingColumnWidth,
                    onEditingEnded: { ghost = nil },
                    bulkEditCellWidth: allowsBulkEdit ? bulkEditCellWidth : 0,
                    dropTarget: $dropTargetEnd,
                    onDropRow: { moveDraggedRowToEnd() },
                    allowsReorder: allowsReorder
                )
            }
        }
        .background(AppColor.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .strokeBorder(AppColor.tableBorder, lineWidth: AppLine.field)
        )
    }

    private var headerRow: some View {
        // Icon columns (merged leading grip/checkbox, merged trailing
        // eye/delete) get no header cells: empty ruled boxes read as
        // missing labels. The clear reservations below match the body
        // rows' icon column widths exactly; the icon columns carry no
        // inner hairline, so unlike the Key/Value divider there is no rule
        // width to account for. Form-data's Type menu lives inside the key
        // cell, so it needs no header cell either.
        HStack(spacing: 0) {
            if showsIconColumns {
                Color.clear.frame(width: leadingColumnWidth)
            }
            headerLabel(keyHeader, isKey: true)
            verticalRule
            headerLabel(valueHeader)
            if showsIconColumns {
                Color.clear.frame(width: trailingColumnWidth)
            }
            if allowsBulkEdit {
                // Its own header cell: a left rule separates it from the
                // value column (Postman's header divider).
                HStack(spacing: 0) {
                    verticalRule
                    LinkButton("Bulk Edit") { enterBulkMode() }
                        .padding(.horizontal, AppSpacing.small)
                        .help("Edit as key-value text lines (Postman Bulk Edit)")
                }
                .frame(width: bulkEditCellWidth)
            }
        }
        .frame(height: AppSize.tableRowHeight)
        .background(headerBackground ?? .clear)
    }

    private func headerLabel(_ text: String) -> some View {
        Text(text)
            .font(AppFont.columnHeader)
            .foregroundStyle(AppColor.textSecondary)
            .padding(.horizontal, AppSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Key-column header: a plain-text label, or (when `allowsKeySort`) a
    /// button that cycles A→Z ↔ Z→A with a direction arrow, matching the
    /// Postman variables table.
    @ViewBuilder
    private func headerLabel(_ text: String, isKey: Bool) -> some View {
        if isKey, allowsKeySort {
            Button {
                toggleKeySort()
            } label: {
                HStack(spacing: AppSpacing.xxSmall) {
                    Text(text)
                    if let keySortOrder {
                        Image(systemName: keySortOrder == .ascending ? "arrow.up" : "arrow.down")
                            .font(AppFont.small.weight(.medium))
                    }
                }
                .font(AppFont.columnHeader)
                .foregroundStyle(AppColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            .padding(.horizontal, AppSpacing.small)
            .help(keySortHelp)
        } else {
            headerLabel(text)
        }
    }

    private var keySortHelp: String {
        switch keySortOrder {
        case .ascending: "Sorted A to Z"
        case .descending: "Sorted Z to A"
        case nil: "Sort A to Z"
        }
    }

    // MARK: - Key sort

    private enum KeySortOrder {
        case ascending
        case descending
    }

    /// Header click: first press sorts A→Z, then toggles direction.
    private func toggleKeySort() {
        let ascending = keySortOrder != .ascending
        keySortOrder = ascending ? .ascending : .descending
        applyKeySort(ascending: ascending)
    }

    /// Finder-style key comparison (case-insensitive, numeric-aware) with
    /// the id as a tiebreaker so equal keys keep a stable order.
    private func applyKeySort(ascending: Bool) {
        items.sort { lhs, rhs in
            let order = lhs.key.localizedStandardCompare(rhs.key)
            guard order != .orderedSame else { return lhs.id.uuidString < rhs.id.uuidString }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    /// Manual reorder leaves the header arrow stale - drop it so the
    /// indicator only reflects a sort the header last applied.
    private func clearKeySortIfNeeded() {
        if keySortOrder != nil { keySortOrder = nil }
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

    /// Ghost row's Type picker. Materializes on first non-default kind so a
    /// File row can hold a path before the user types a key; collapses back
    /// to the empty buffer when kind returns to Text with no content.
    private var ghostKindBinding: Binding<FormFieldKind>? {
        guard let kindKeyPath else { return nil }
        return Binding(
            get: { ghost?[keyPath: kindKeyPath] ?? .text },
            set: { newValue in
                var row = ghost ?? makeNew()
                row[keyPath: kindKeyPath] = newValue
                let isEmpty = row.key.isEmpty && row.value.isEmpty && newValue == .text
                if let index = items.firstIndex(where: { $0.id == row.id }) {
                    if isEmpty {
                        items.remove(at: index)
                    } else {
                        items[index] = row
                    }
                } else if !isEmpty {
                    items.append(row)
                }
                ghost = isEmpty ? nil : row
                if !isEmpty, focusedCell == nil || focusedCell == .ghostKey || focusedCell == .ghostValue {
                    focusedCell = .key(row.id)
                }
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
        clearKeySortIfNeeded()
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
        clearKeySortIfNeeded()
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
        clearKeySortIfNeeded()
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
            .fill(AppColor.tableBorder)
            .frame(width: AppLine.hairline)
    }
}

// MARK: - Row

/// One table row: merged leading cell (grip + checkbox), borderless
/// key/value cells split by a hairline, and a merged trailing cell (secret
/// eye + delete, the latter appearing only while hovering, Postman-style).
/// The icon columns are not fenced off by hairlines: the leading cell has
/// no right rule and the trailing cell no left rule, so they open toward
/// the text columns and the only vertical rule left is the Key/Value one.
private struct KVRow: View {
    @Binding var isEnabled: Bool
    @Binding var key: String
    @Binding var value: String
    /// Form-data Type menu, trailing inside the key cell (Postman).
    var kind: Binding<FormFieldKind>?
    let showsKindMenu: Bool
    let kindMenuWidth: CGFloat
    /// Muted, non-editable key cell (path variables: the key derives from
    /// the URL). Opts the key cell out of hover/focus chrome.
    var isKeyDisabled: Bool = false
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
    /// plus the enabled checkbox share one cell; no right hairline.
    let leadingColumnWidth: CGFloat
    /// Width of the merged trailing column: secret eye (variables tables
    /// only) plus the delete button share one cell; no left hairline.
    let trailingColumnWidth: CGFloat
    private let gripGlyphWidth: CGFloat = 14
    /// nil for real rows; the trailing ghost row reports its editing session's
    /// end through this so the table can reset the ghost buffer.
    var onEditingEnded: (() -> Void)?
    /// nil for the trailing ghost row (nothing to delete yet).
    var onDelete: (() -> Void)?
    /// Drag-to-reorder: nil unless `allowsReorder`. The grip is pointer-only;
    /// keyboard users get Move Up/Down instead.
    /// Trailing blank reservation matching the header's Bulk Edit cell (0
    /// = none). Keeps the header's Key/Value column split aligned with the
    /// rows' dividers.
    var bulkEditCellWidth: CGFloat = 0
    var onGripDrag: (() -> NSItemProvider)?
    /// Keyboard/context-menu reorder steps; nil unless `allowsReorder`.
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    /// Dimmed while dragged; shows the insertion line while targeted.
    var isDragging: Bool = false
    var isDropTargeted: Bool = false
    /// Live drop-target state; also drives `onDrop`'s `isTargeted` so the
    /// handler can live inside the row (an outer wrapper would re-order
    /// siblings relative to the cell's `zIndex`).
    var dropTarget: Binding<Bool>?
    var onDropRow: (() -> Bool)?
    var allowsReorder: Bool = false

    @State private var isHovering = false
    /// Which cell the pointer is over. Hover chrome is per-cell (Postman
    /// style), not per-row - the row `isHovering` only drives grip/delete
    /// visibility. Nested AppKit editors report through `onHoverChanged`
    /// (SwiftUI `.onHover` never fires above them).
    @State private var hoveredCell: HoveredCell?

    private enum HoveredCell: Hashable {
        case key
        case value
    }

    private var isGhostRow: Bool { onDelete == nil }

    /// File rows show a picker in the value cell instead of a text field
    /// (Postman form-data); the path still lives in `value`.
    private var isFileRow: Bool { kind?.wrappedValue == .file }

    /// Keyboard users tab into the row's cells without hovering: keep the
    /// delete visible while either cell owns focus so it stays reachable.
    private var isRowFocused: Bool {
        focus.wrappedValue == keyFocus || focus.wrappedValue == valueFocus
    }

    private var isDeleteVisible: Bool { isHovering || isRowFocused }

    var body: some View {
        HStack(spacing: 0) {
            // One merged leading cell: drag grip (pointer-only, on hover)
            // and the enabled checkbox share a single column, with no
            // right hairline opening the key cell next to it.
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
                            .font(AppFont.iconRow)
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(width: gripGlyphWidth)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .opacity(isHovering || isDragging ? 1 : 0)
                            .onDrag {
                                guard let onGripDrag else { return NSItemProvider() }
                                return onGripDrag()
                            }
                            // The grip drags the row, so the pointer becomes a
                            // hand over it - through the shared `clickCursor`
                            // pointer machinery, not `NSCursor.push()/pop()`.
                            // Push/pop strands a hand cursor whenever the view
                            // disappears before its exit event arrives, and
                            // the grip does exactly that: the drag hides the
                            // glyph and the row leaves its slot. The tracking
                            // is AppKit's, so it unwinds on its own.
                            .clickCursor()
                    }
                }
                // The trailing ghost row has nothing to enable yet: no
                // checkbox until it materializes into a real row.
                if isGhostRow {
                    Color.clear
                } else {
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help(isEnabled ? "Disable row" : "Enable row")
                }
            }
            .frame(width: leadingColumnWidth)
            cell(.key, muted: isKeyDisabled) {
                HStack(spacing: AppSpacing.xSmall) {
                    VariableHighlightEditor(
                        text: $key,
                        variables: variables,
                        suggestions: suggestions,
                        font: .systemSubheadline,
                        placeholder: keyPlaceholder,
                        focus: focus,
                        focusValue: keyFocus,
                        isEditable: !isKeyDisabled,
                        onEditingEnded: onEditingEnded,
                        onHoverChanged: { setHover(.key, $0) }
                    )
                    if showsKindMenu {
                        kindMenu
                    }
                }
            }
            verticalRule
            cell(.value) {
                if isFileRow {
                    fileValueCell
                } else {
                    VariableHighlightEditor(
                        text: $value,
                        variables: variables,
                        suggestions: suggestions,
                        font: .systemSubheadline,
                        placeholder: valuePlaceholder,
                        focus: focus,
                        focusValue: valueFocus,
                        onEditingEnded: onEditingEnded,
                        onHoverChanged: { setHover(.value, $0) }
                    )
                }
            }
            trailingColumn
            if bulkEditCellWidth > 0 {
                Color.clear.frame(width: bulkEditCellWidth)
            }
        }
        .frame(height: AppSize.tableRowHeight)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Bottom hairline lives inside the row (replacing the VStack's
        // per-row Divider): a sibling Divider paints after this row and
        // covers a stroke that overflows downward, which made the cell
        // border's bottom edge look thinner than the other three.
        .background(alignment: .bottom) {
            if !isGhostRow {
                Rectangle()
                    .fill(AppColor.tableBorder)
                    .frame(height: AppLine.hairline)
            }
        }
        .opacity(isDragging ? 0.5 : 1)
        .overlay(alignment: .top) {
            if allowsReorder && isDropTargeted {
                Rectangle()
                    .fill(AppColor.accent)
                    .frame(height: AppLine.focusedField)
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
        .overlay(alignment: .bottom) {
            if isGhostRow, allowsReorder, dropTarget?.wrappedValue == true {
                Rectangle()
                    .fill(AppColor.accent)
                    .frame(height: AppLine.focusedField)
            }
        }
        .onDrop(of: [.text], isTargeted: dropTarget ?? .constant(false)) { _ in
            onDropRow?() ?? false
        }
    }

    /// A borderless spreadsheet-like cell; disabled rows dim, like Postman.
    /// Rest draws no chrome; hover/focus lift to a brighter fill and add the
    /// standard field border. Focus recolors it to accent. The stroke expands
    /// 1pt on the top/left/right (`padding(-1)`) to sit on the column hairlines;
    /// the bottom edge stays flush with the cell so it covers the row's own
    /// bottom hairline (a stroke overflowing downward would land outside
    /// the row and read as thinner than the other three edges). The row
    /// lifts via `zIndex` only within the HStack - the vertical rule after
    /// this cell. Both the AppKit editor (`onHoverChanged`) and this
    /// SwiftUI shell report into the same `hoveredCell`.
    private func cell(_ id: HoveredCell, muted: Bool = false, @ViewBuilder field: () -> some View) -> some View {
        field()
            .font(AppFont.small)
            .foregroundStyle(muted || !isEnabled ? AppColor.textSecondary : AppColor.textPrimary)
            .opacity(isEnabled ? 1 : AppOpacity.disabled)
            .padding(.horizontal, AppSpacing.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                if muted {
                    // Disabled look: a solid muted fill (Postman's path
                    // variable key cell), no hover/focus chrome.
                    Rectangle().fill(AppColor.subtleBackground)
                } else if isCellFocused(id) || hoveredCell == id {
                    Rectangle()
                        .fill(
                            isCellFocused(id)
                                ? AppColor.fieldFocusBackground
                                : AppColor.fieldHoverBackground
                        )
                }
            }
            .overlay {
                if !muted, isCellFocused(id) || hoveredCell == id {
                    Rectangle()
                        .strokeBorder(
                            isCellFocused(id) ? AppColor.accent : AppColor.borderStrong,
                            lineWidth: isCellFocused(id) ? AppLine.focusedField : AppLine.field
                        )
                        .padding(.leading, -1)
                        .padding(.trailing, -1)
                        .padding(.top, -1)
                }
            }
            .onHover { hovering in
                if !muted {
                    setHover(id, hovering)
                }
            }
            // Outermost among the HStack's children: later siblings (the
            // vertical hairline after this cell) otherwise paint over the
            // right edge. A wrapper modifier below would swallow the zIndex.
            .zIndex(isCellFocused(id) || hoveredCell == id ? 1 : 0)
    }

    private func isCellFocused(_ id: HoveredCell) -> Bool {
        focus.wrappedValue == (id == .key ? keyFocus : valueFocus)
    }

    private func setHover(_ cell: HoveredCell, _ hovering: Bool) {
        if hovering {
            hoveredCell = cell
        } else if hoveredCell == cell {
            hoveredCell = nil
        }
    }

    /// Type menu inside the key cell: Text/File (form-data only). The ghost
    /// row's menu materializes the row via `kind`. The presentation id is
    /// derived from the row's focus identity, so two kind menus on different
    /// rows never share an anchor.
    private var kindMenu: some View {
        Group {
            if let kind {
                DropdownFieldButton(
                    id: "kv.kind.\(kindID)",
                    label: kind.wrappedValue == .text ? "Text" : "File",
                    width: kindMenuWidth,
                    isDisabled: !isEnabled
                ) {
                    FormFieldKind.allCases.map { pickedKind in
                        DropdownRow.action(
                            pickedKind == .text ? "Text" : "File",
                            isSelected: pickedKind == kind.wrappedValue
                        ) {
                            kind.wrappedValue = pickedKind
                        }
                    }
                }
            }
        }
        .frame(width: kindMenuWidth)
    }

    /// Stable per-row identity for the kind menu's presentation id (see
    /// `kindMenu`): the focus tag carries the row's item id; the ghost row
    /// is unique by construction.
    private var kindID: String {
        switch keyFocus {
        case .key(let id): id.uuidString
        default: "ghost"
        }
    }

    /// Value cell for a File row: filename + Browse, writing the path into
    /// `value` (same storage as Postman; the ghost row materializes on set).
    private var fileValueCell: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text(value.isEmpty ? "No file selected" : URL(fileURLWithPath: value).lastPathComponent)
                .font(AppFont.small)
                .foregroundStyle(value.isEmpty ? AppColor.tertiaryText : AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .helpIf(!value.isEmpty, value)
            LinkButton("Browse…", font: AppFont.small) {
                if let url = openFilePanel() { value = url.path }
            }
            .disabled(!isEnabled)
            .help("Choose a file to upload")
        }
        .opacity(isEnabled ? 1 : AppOpacity.disabled)
    }

    /// One merged trailing cell: the secret eye (variables tables only)
    /// and the delete button share a single column with no left hairline,
    /// mirroring the merged leading grip+checkbox cell exactly: one
    /// `xxSmall`-spaced group, fitted and centered, so the glyph gap and
    /// the side insets match the leading column. The ghost row reserves
    /// the same width so its cells line up with the real rows.
    private var trailingColumn: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            if secretColumnWidth > 0 {
                secretCell
            }
            deleteCell
        }
        .frame(width: trailingColumnWidth)
    }

    /// Eye button toggling the row's secret flag; the ghost row only
    /// reserves the space. Glyph-boxed and vertically centered (no
    /// `maxHeight: .infinity`) so the hover pill stays a compact square
    /// instead of a full-row-height bar.
    @ViewBuilder
    private var secretCell: some View {
        if let isSecret {
            Button {
                isSecret.wrappedValue.toggle()
            } label: {
                Image(systemName: isSecret.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(AppColor.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconButtonStyle(inset: 0))
            .help(isSecret.wrappedValue ? "Hidden (secret)" : "Shown (toggle to hide)")
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var deleteCell: some View {
        Group {
            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(AppFont.iconRow)
                        .foregroundStyle(AppColor.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IconButtonStyle(inset: 0))
                .opacity(isDeleteVisible ? 1 : 0)
                .disabled(!isDeleteVisible)
                .help("Remove row")
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var verticalRule: some View {
        Rectangle()
            .fill(AppColor.tableBorder)
            .frame(width: AppLine.hairline)
    }
}

private struct ReadOnlyKVRow: View {
    let key: String
    let value: String
    let isMuted: Bool
    /// Auto-generated filler (the request's calculated headers): shaded
    /// gray so it reads as non-user data. Real returned data (the response
    /// headers) passes false and stays clean.
    let isGenerated: Bool
    /// Checked state for toggleable rows; ignored for fixed display.
    let isOn: Bool
    /// Toggle callback; nil renders the fixed checked box.
    let onToggle: (() -> Void)?
    let showsKeyInfo: Bool
    let showsIconColumns: Bool
    let leadingColumnWidth: CGFloat
    let trailingColumnWidth: CGFloat
    let showsGrip: Bool
    let gripWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if showsIconColumns {
                readOnlyLeadingCell
            }
            readOnlyCell(key, showsInfo: showsKeyInfo)
            verticalRule
            readOnlyCell(value)
            if showsIconColumns {
                Color.clear.frame(width: trailingColumnWidth)
            }
        }
        .frame(height: AppSize.tableRowHeight)
        .background(alignment: .bottom) {
            // Closest to the content: the opaque wash below must not cover
            // it, or the row separators vanish under the fill.
            Rectangle()
                .fill(AppColor.tableBorder)
                .frame(height: AppLine.hairline)
        }
        .background(isGenerated ? AppColor.tableHeaderBackground : .clear)
    }

    private var readOnlyLeadingCell: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            if showsGrip {
                Color.clear
                    .frame(width: gripWidth)
                    .frame(maxHeight: .infinity)
            }
            Toggle(
                "",
                isOn: onToggle == nil
                    ? .constant(true)
                    : Binding(get: { isOn }, set: { _ in onToggle?() })
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            // Fixed display (the masked Authorization row): grayed out so it
            // does not read as clickable. Disabled also swallows hits, so no
            // separate allowsHitTesting is needed.
            .disabled(onToggle == nil)
        }
        .frame(width: leadingColumnWidth)
    }

    private func readOnlyCell(_ text: String, showsInfo: Bool = false) -> some View {
        // The info glyph is a real sibling, not an overlay: tooltips do not
        // fire reliably from inside an overlay, and the selectable text
        // below is AppKit-backed and would swallow the hover anyway (same
        // reason editable cells report hover through onHoverChanged).
        HStack(spacing: 0) {
            Text(text)
                .font(AppFont.small)
                .foregroundStyle(isMuted ? AppColor.textSecondary : AppColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.leading, AppSpacing.small)
                .padding(.trailing, AppSpacing.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if showsInfo {
                Image(systemName: "info.circle")
                    .font(AppFont.iconRow)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.trailing, AppSpacing.xSmall)
                    .help("Calculated when request is sent")
            }
        }
    }

    private var verticalRule: some View {
        Rectangle()
            .fill(AppColor.tableBorder)
            .frame(width: AppLine.hairline)
    }
}
