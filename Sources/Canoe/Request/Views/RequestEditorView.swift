import SwiftUI

/// Postman-style request editor: a breadcrumb name bar
/// (collection › folders › request name + Save) over a URL bar (method
/// picker + URL field + Send button), followed by underline section tabs
/// (Params / Headers / Body) and the matching editor below.
struct RequestEditorView: View {
    @Environment(AppStore.self) private var store
    let request: RequestItem

    @State private var draft: RequestItem
    @State private var section: RequestSection = .params

    enum RequestSection: String, CaseIterable, Identifiable {
        case params = "Params"
        case auth = "Authorization"
        case headers = "Headers"
        case body = "Body"
        var id: String { rawValue }
    }

    init(request: RequestItem) {
        self.request = request
        _draft = State(initialValue: request)
    }

    /// Shown on the Params tab. Mirrors what HTTPClient actually sends:
    /// enabled rows with a non-empty key. Blank leftover rows don't count.
    private var enabledParamCount: Int {
        draft.params.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Shown on the Headers tab; same non-blank rule as Params.
    private var enabledHeaderCount: Int {
        draft.headers.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Enabled row count for form bodies (shown on the Body tab like Postman).
    private var bodyRowCount: Int? {
        switch draft.requestBodyType {
        case .formData:
            draft.formFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.count
        case .urlEncoded:
            draft.urlEncodedFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.count
        case .none, .raw, .binary:
            nil
        }
    }

    /// Merged variable scope for `{{placeholder}}` highlighting in every
    /// editable request field (Postman-style green/red highlighting).
    private var resolvedVariables: [String: String] {
        store.variablesForRequest(draft)
    }

    /// Completion candidates with scope metadata for `{{` auto-completion.
    private var requestSuggestions: [VariableSuggestion] {
        VariableSuggestion.suggestions(from: store.variableScopesForRequest(draft))
    }

    // MARK: - URL bar <-> params two-way sync

    /// Which surface owns keyboard focus: the focused one drives the other.
    private enum URLFieldFocus: Hashable {
        case url
    }

    @FocusState private var urlFieldFocused: URLFieldFocus?
    /// Focus of the multi-line popup editor shown while the URL is edited.
    @FocusState private var urlPopupField: URLFieldFocus?
    /// Whether the URL popup (multi-line editor floating over the sections)
    /// is open.
    @State private var isURLPopupVisible = false
    /// Whether the method dropdown panel is open.
    @State private var isMethodMenuVisible = false
    /// Method under the pointer in the dropdown (hover highlight).
    @State private var hoveredMethod: HTTPMethod?
    /// The dropdown's type-to-filter query.
    @State private var methodFilter = ""
    @FocusState private var methodFilterFieldFocused: Bool

    /// Methods matching the dropdown's filter (empty shows all).
    private var filteredMethods: [HTTPMethod] {
        guard !methodFilter.isEmpty else { return HTTPMethod.allCases }
        return HTTPMethod.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains(methodFilter) }
    }
    /// Measured height of the URL bar row - anchors the popup right below it.
    @State private var urlBarHeight: CGFloat = 0
    /// The raw text currently shown in the URL bar.
    @State private var urlText = ""

    /// The URL bar text: the stored base URL plus the query rendered from the
    /// params table (the table is the source of truth for the query; the
    /// base lives in `urlString`).
    private func composedURLText(base: String, params: [QueryParam]) -> String {
        let query =
            params
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        guard !query.isEmpty else { return base }
        return base.contains("?") ? base + "&" + query : base + "?" + query
    }

    /// URL bar edits drive the params table: the query part is parsed into
    /// rows and the stored URL keeps only its base (no query), so the two
    /// never double up at send time.
    private func syncParamsFromURLText(_ text: String) {
        let parts = text.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        draft.urlString = String(parts[0])
        guard parts.count > 1 else {
            if !draft.params.isEmpty { draft.params = [] }
            return
        }
        let pairs = parts[1]
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { raw -> QueryParam in
                let kv = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return QueryParam(
                    key: kv.isEmpty ? "" : String(kv[0]),
                    value: kv.count > 1 ? String(kv[1]) : ""
                )
            }
        let changed =
            pairs.count != draft.params.count
            || zip(pairs, draft.params).contains { $0.key != $1.key || $0.value != $1.value }
        if changed { draft.params = pairs }
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { urlText },
            set: { newValue in
                urlText = newValue
                // The set only fires from the URL bar editor itself, so the
                // typed text is authoritative here.
                syncParamsFromURLText(newValue)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            nameBar
            urlBar
            sectionTabs
            Divider()
            sectionContent
        }
        .background(.background)
        .overlay { urlPopupOverlay }
        .onChange(of: draft) { _, newDraft in
            store.updateRequest(newDraft)
            // Params-table edits (and request switches) re-compose the URL
            // bar text - unless the user is typing in the URL bar itself. The
            // focused surface always wins, keeping the two-way sync loop-free.
            guard urlFieldFocused == nil, urlPopupField == nil else { return }
            urlText = composedURLText(base: newDraft.urlString, params: newDraft.params)
        }
        .onChange(of: request.id) { _, _ in
            draft = request
            isURLPopupVisible = false
        }
        // The bar field stays a single line; gaining focus opens the
        // multi-line popup editor below and hands focus over to it.
        .onChange(of: urlFieldFocused) { _, focused in
            guard focused == .url else { return }
            isMethodMenuVisible = false
            if isURLPopupVisible {
                // Clicking the bar while the popup is already open: the
                // popup keeps the keystrokes, so release the bar's focus
                // claim immediately instead of re-entering the fight below.
                urlFieldFocused = nil
                return
            }
            isURLPopupVisible = true
            // Hand focus to the popup's editor once it is inserted.
            DispatchQueue.main.async { urlPopupField = .url }
        }
        .onChange(of: isMethodMenuVisible) { _, visible in
            guard visible else { return }
            // The two floating surfaces are mutually exclusive.
            isURLPopupVisible = false
            hoveredMethod = nil
            methodFilter = ""
            // Postman drops you into the filter so typing narrows the list.
            DispatchQueue.main.async { methodFilterFieldFocused = true }
        }
        .onChange(of: urlPopupField) { _, focused in
            if focused == .url {
                // The popup editor owns the keystrokes now: drop the bar
                // field's focus claim. Otherwise the bar's focus pass calls
                // `makeFirstResponder` on every recompose, ripping focus back
                // from the popup mid-typing - which closed the popup after
                // the first typed character and dropped characters typed
                // during the handoff.
                urlFieldFocused = nil
            } else {
                isURLPopupVisible = false
            }
        }
        .onAppear {
            draft = request
            urlText = composedURLText(base: draft.urlString, params: draft.params)
        }
    }

    // MARK: - Name bar

    /// The breadcrumb leading to this request, outermost first and starting
    /// with the collection name - `Collection › Folder › Subfolder` - rendered
    /// before the editable request name like a file path.
    private var breadcrumbPath: [String] {
        store.breadcrumbPath(for: draft)
    }

    /// Whether the request has unsaved modifications (Save button + tab "*").
    private var isDirty: Bool {
        store.hasPendingChanges(for: draft.id)
    }

    private var nameBar: some View {
        HStack(spacing: AppSpacing.xSmall) {
            // Postman-style protocol badge leading the row ("HTTP" today;
            // more protocol types may come later).
            RequestTypeBadge(type: draft.requestType)
            if !breadcrumbPath.isEmpty {
                // One path text (not per-segment views) keeps the row stable
                // when folders are renamed or the window narrows: it truncates
                // from the head like a file path while the layout-priority
                // request name below stays fully visible.
                Text(breadcrumbPath.joined(separator: " › "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(breadcrumbPath.joined(separator: " › "))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            // The HTTP method joins the editable name, mirroring the sidebar
            // rows (`GET New Request`); it is changed from the URL bar.
            MethodTag(method: draft.httpMethod)
            TextField("Request Name", text: $draft.name)
                .font(.subheadline.weight(.semibold))
                .textFieldStyle(.plain)
                // NO layoutPriority here: a priority-1 plain TextField claims
                // the whole row and squeezes the breadcrumb Text to zero
                // width (the original "collection name never shows" bug).
                // At equal priority the less-flexible Text keeps its ideal
                // width and the flexible TextField takes the remainder.
                .frame(minWidth: 120)
            Spacer(minLength: AppSpacing.medium)
            saveButton
        }
        .padding(.horizontal, AppSpacing.medium)
        // Fixed-height row: padding-driven heights let extra vertical space
        // (VSplitView panes, taller windows) inflate into blank bands above
        // and below the bar. Pin it like the other toolbar rows.
        .frame(height: AppSize.toolbarHeight)
    }

    /// Postman-style Save: a filled chip with icon + label, enabled while the
    /// request has unsaved changes.
    private var saveButton: some View {
        Button {
            store.savePendingChanges()
        } label: {
            // Explicit Image + Text (not Label): plain-style buttons on macOS
            // can collapse a Label to title-only, dropping the icon. The icon
            // is macOS's standard Save symbol - "floppy.disk" does not exist
            // in SF Symbols and renders silently as nothing.
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "square.and.arrow.down")
                Text("Save")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isDirty ? AppColor.accent : .secondary)
            .padding(.horizontal, AppSpacing.small + 2)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isDirty ? AppColor.subtleBackground : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isDirty)
        .help("Save Request (⌘S)")
    }

    // MARK: - URL bar

    private var urlBar: some View {
        VStack(spacing: AppSpacing.xSmall) {
            HStack(spacing: AppSpacing.small) {
                // Postman-style unified bar: one bordered container holding
                // the method picker and the URL field, separated by a
                // hairline. Focusing the field highlights the whole bar.
                HStack(spacing: 0) {
                    MethodPicker(
                        selection: $draft.httpMethod,
                        isExpanded: $isMethodMenuVisible
                    )
                    Rectangle()
                        .fill(AppColor.border)
                        .frame(width: 1, height: 20)
                    VariableHighlightEditor(
                        text: urlBinding,
                        variables: resolvedVariables,
                        suggestions: requestSuggestions,
                        font: .monoURLBar,
                        placeholder: "https://api.example.com/users",
                        focus: $urlFieldFocused,
                        focusValue: .url,
                        // The bar is a display surface: the popup editor owns
                        // the keystrokes. Allowing the field to grab first
                        // responder during updates would restart its editing
                        // session mid-typing - a fresh NSTextField session
                        // selects all, so the next character overwrites the
                        // whole URL.
                        autoFocusOnUpdate: false
                    )
                    .padding(.leading, AppSpacing.small + 2)
                }
                .variableFieldBordered(isFocused: urlFieldFocused == .url, verticalPadding: 3)

                if store.isSending {
                    ProgressView().controlSize(.small)
                        .frame(width: AppSize.methodPickerWidth)
                } else {
                    Button {
                        store.send(draft)
                    } label: {
                        // Lifts the label so the styled button lands on the
                        // shared 30pt row height; the text itself is untouched.
                        Text("Send")
                            .frame(minHeight: 22)
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(draft.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Send Request (⌘↩)")
                }
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            urlBarHeight = $0
        }
    }

    // MARK: - URL popup

    /// Editing surface for long URLs: the bar field never wraps, so while it
    /// is focused a multi-line editor floats below the bar in a card. It is
    /// an overlay - the bar's height and the section layout below never
    /// change - and a click-outside catcher gives it popover dismissal
    /// semantics (the first click outside closes it without activating what
    /// is underneath).
    private var urlPopupOverlay: some View {
        ZStack(alignment: .topLeading) {
            if isURLPopupVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isURLPopupVisible = false }
                // Escape also dismisses (cancelAction); the zero-size hidden
                // button keeps the shortcut registered.
                Button("Cancel Editing") { isURLPopupVisible = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                urlPopup
                    .padding(
                        .top,
                        AppSize.toolbarHeight + urlBarHeight + AppSpacing.xxSmall
                    )
                    // Left edge tracks the URL field: bar padding + method
                    // picker + the spacing between them.
                    .padding(.leading, AppSpacing.medium + AppSize.methodPickerWidth + AppSpacing.small)
                    .padding(.trailing, AppSpacing.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if isMethodMenuVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isMethodMenuVisible = false }
                Button("Close Method Menu") { isMethodMenuVisible = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                methodMenuPanel
                    // Anchors below the URL bar, left-aligned with the method
                    // segment (the bar's leading padding).
                    .padding(
                        .top,
                        AppSize.toolbarHeight + urlBarHeight + AppSpacing.xxSmall
                    )
                    .padding(.leading, AppSpacing.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Postman-style method dropdown: a filter field up top (type to narrow
    /// the list, Return picks the first match), then colored method names,
    /// the current one (or the hovered one) highlighted with a soft pill.
    private var methodMenuPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Filter methods", text: $methodFilter)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($methodFilterFieldFocused)
                    .onSubmit {
                        guard let first = filteredMethods.first else { return }
                        draft.httpMethod = first
                        isMethodMenuVisible = false
                    }
                    .onExitCommand { isMethodMenuVisible = false }
            }
            .padding(.horizontal, AppSpacing.small)
            .frame(minHeight: 30)

            Divider()

            Group {
                if filteredMethods.isEmpty {
                    Text("No Matching Method")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                } else {
                    ForEach(filteredMethods) { method in
                        Button {
                            draft.httpMethod = method
                            isMethodMenuVisible = false
                        } label: {
                            Text(method.rawValue)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(method.color)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .padding(.horizontal, AppSpacing.small)
                                .background(
                                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                        .fill(
                                            method == draft.httpMethod || method == hoveredMethod
                                                ? AppColor.subtleBackground
                                                : Color.clear
                                        )
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredMethod = hovering ? method : nil
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xSmall)
        }
        .frame(width: 144)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(.background)
                .shadow(color: Color.primary.opacity(0.22), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(AppColor.border, lineWidth: 1)
        )
    }

    /// The floating multi-line URL editor: same two-way sync as the bar
    /// field, auto-grows up to the editor's internal cap.
    private var urlPopup: some View {
        VariableHighlightEditor(
            text: urlPopupBinding,
            variables: resolvedVariables,
            suggestions: requestSuggestions,
            isSingleLine: false,
            focus: $urlPopupField,
            focusValue: .url,
            // Return (with no completion popup open) commits and closes,
            // like the newline handling in `urlPopupBinding` for pasted text.
            onCommit: { isURLPopupVisible = false }
        )
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xSmall)
        .frame(minHeight: 56, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .fill(.background)
                .shadow(color: Color.primary.opacity(0.22), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                .strokeBorder(AppColor.border, lineWidth: 1)
        )
    }

    /// The popup editor's binding: mirrors `urlBinding`, but treats a line
    /// break as "done editing" - URLs never contain raw newlines, so Return
    /// commits and closes instead of inserting.
    private var urlPopupBinding: Binding<String> {
        Binding(
            get: { urlText },
            set: { newValue in
                guard newValue.contains("\n") || newValue.contains("\r") else {
                    urlText = newValue
                    syncParamsFromURLText(newValue)
                    return
                }
                let cleaned =
                    newValue
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                urlText = cleaned
                syncParamsFromURLText(cleaned)
                isURLPopupVisible = false
            }
        )
    }

    // MARK: - Section tabs

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            UnderlineTab(
                title: RequestSection.params.rawValue,
                count: enabledParamCount,
                isSelected: section == .params,
                action: { section = .params }
            )
            UnderlineTab(
                title: RequestSection.auth.rawValue,
                count: draft.hasAuthConfigured ? 1 : nil,
                isSelected: section == .auth,
                action: { section = .auth }
            )
            UnderlineTab(
                title: RequestSection.headers.rawValue,
                count: enabledHeaderCount,
                isSelected: section == .headers,
                action: { section = .headers }
            )
            UnderlineTab(
                title: RequestSection.body.rawValue,
                count: bodyRowCount,
                isSelected: section == .body,
                action: { section = .body }
            )
            Spacer()
        }
        .padding(.horizontal, AppSpacing.small)
    }

    // MARK: - Section content

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .params:
            KeyValueEditor(
                items: $draft.params,
                makeNew: { QueryParam() },
                title: "Query Params",
                variables: resolvedVariables,
                suggestions: requestSuggestions,
                keyPlaceholder: "parameter",
                valuePlaceholder: "value"
            )
        case .headers:
            KeyValueEditor(
                items: $draft.headers,
                makeNew: { HTTPHeader() },
                title: "Headers",
                variables: resolvedVariables,
                suggestions: requestSuggestions,
                keyPlaceholder: "Header-Name",
                valuePlaceholder: "value"
            )
        case .auth:
            AuthEditor(request: $draft)
        case .body:
            BodyEditor(request: $draft)
        }
    }
}

// MARK: - Method picker

/// Postman-style method segment inside the unified URL bar: method name in
/// its signature color plus a dropdown chevron, separated from the URL field
/// by the container's hairline. Clicking toggles the dropdown panel hosted
/// in the window-level overlay; while open the segment wears a focus ring.
private struct MethodPicker: View {
    @Binding var selection: HTTPMethod
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                Text(selection.rawValue)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(selection.color)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, AppSpacing.small + 2)
            .padding(.trailing, AppSpacing.small)
            .frame(width: AppSize.methodPickerWidth, height: 24)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isExpanded ? AppColor.accent : .clear,
                        lineWidth: isExpanded ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help("HTTP method")
    }
}
