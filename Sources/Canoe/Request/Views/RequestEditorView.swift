import SwiftUI

/// Postman-style request editor: a breadcrumb name bar
/// (collection › folders › request name + Save) over a URL bar (method
/// picker + URL field + Send button), followed by underline section tabs
/// (Params / Headers / Body) and the matching editor below.
struct RequestEditorView: View {
    @Environment(AppStore.self) private var store
    let request: Request

    @State private var draft: Request
    @State private var section: RequestSection = .params

    enum RequestSection: String, CaseIterable, Identifiable {
        case params = "Params"
        case auth = "Authorization"
        case headers = "Headers"
        case body = "Body"
        var id: String { rawValue }
    }

    init(request: Request) {
        self.request = request
        _draft = State(initialValue: request)
    }

    /// Shown on the Params tab. Mirrors what HTTPClient actually sends:
    /// enabled rows with a non-empty key. Blank leftover rows don't count.
    private var enabledParamCount: Int {
        draft.params.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// Shown on the Headers tab; same non-blank rule as Params.
    private var enabledHeaderCount: Int {
        draft.headers.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// Shown on the Authorization tab. Unlike `Request.hasAuthConfigured`
    /// this sees inherited settings (what HTTPClient actually sends) and a
    /// manually set Authorization header, which always wins over the helper.
    private var isAuthConfigured: Bool {
        if store.authorizationForRequest(draft).isConfigured { return true }
        return draft.headers.contains {
            $0.isEnabled
                && $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "authorization"
        }
    }

    /// Enabled row count for form bodies (shown on the Body tab like Postman).
    private var bodyRowCount: Int? {
        switch draft.requestBodyType {
        case .formData:
            draft.formFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        case .urlEncoded:
            draft.urlEncodedFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
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

    // Plain @State, not @FocusState: these only mirror which AppKit field
    // owns keyboard focus (first responder is managed inside the editors),
    // and an unregistered @FocusState made writes no-ops and reads unreliable.
    @State private var urlFieldFocused: URLFieldFocus?
    /// Whether the pointer is over the URL bar: drives its hover fill (the
    /// method picker's own hover signal, so the two halves of the bar read
    /// as one control).
    @State private var isURLBarHovered = false
    /// Whether the method dropdown panel is open.
    @State private var isMethodMenuVisible = false
    /// Method under the pointer in the dropdown (hover highlight).
    @State private var hoveredMethod: HTTPMethod?
    /// Method moved to with ↑/↓ in the dropdown filter. Return picks this
    /// (falling back to the first match); nil until the user arrows.
    @State private var keyboardMethod: HTTPMethod?
    /// The dropdown's type-to-filter query.
    @State private var methodFilter = ""
    @FocusState private var methodFilterFieldFocused: Bool
    /// Inline request-name editing (Postman-style): hover pill + focus ring.
    @FocusState private var isNameFieldFocused: Bool
    @State private var isNameHovered = false
    /// Name at focus time; Esc restores it (commit happens on blur/Enter).
    @State private var nameEditBaseline = ""
    /// The name field's frame in window coordinates - the click-away
    /// monitor needs it to spare clicks inside the field.
    @State private var nameFieldFrame: CGRect = .zero
    /// Local left-mouse-down monitor that ends name editing when a click
    /// lands outside the field. Installed while the editor is on screen.
    @State private var nameDismissMonitor: Any?

    /// Methods matching the dropdown's filter (empty shows all).
    private var filteredMethods: [HTTPMethod] {
        guard !methodFilter.isEmpty else { return HTTPMethod.allCases }
        return HTTPMethod.allCases.filter { $0.rawValue.localizedCaseInsensitiveContains(methodFilter) }
    }

    /// Moves the keyboard selection in the method dropdown, clamped to the
    /// current matches. Starts from the current method so the first arrow
    /// lands on a neighbor, not the list edge.
    private func moveKeyboardMethod(by delta: Int) {
        guard !filteredMethods.isEmpty else { return }
        let base = keyboardMethod ?? draft.httpMethod
        let idx = filteredMethods.firstIndex(of: base) ?? (delta > 0 ? -1 : filteredMethods.count)
        keyboardMethod = filteredMethods[min(max(idx + delta, 0), filteredMethods.count - 1)]
        hoveredMethod = nil
    }
    @State private var methodMenuAnchor: Anchor<CGRect>?
    /// The raw text currently shown in the URL bar.
    @State private var urlText = ""

    /// The URL bar text: the stored base URL plus the query rendered from the
    /// params table (the table is the source of truth for the query; the
    /// base lives in `urlString`). Only enabled rows with a non-empty key
    /// are shown - exactly what HTTPClient sends - so copying the bar never
    /// leaks a disabled value.
    private func composedURLText(base: String, params: [QueryParam]) -> String {
        let query =
            params
            .filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\(urlQueryEncoded($0.key))=\(urlQueryEncoded($0.value))" }
            .joined(separator: "&")
        guard !query.isEmpty else { return base }
        // A #fragment stays at the very end: the query goes before it.
        if let hash = base.firstIndex(of: "#") {
            let before = String(base[..<hash])
            let fragment = String(base[hash...])
            return before + (before.contains("?") ? "&" : "?") + query + fragment
        }
        return base.contains("?") ? base + "&" + query : base + "?" + query
    }

    /// Percent-encodes one query key/value for the URL bar, keeping compose
    /// and parse symmetric: the bar's parser splits on `&` and `#` and
    /// percent-decodes, so a raw `&` inside a value would come back as
    /// phantom rows, a raw `#` would land in the fragment, and a raw `%`
    /// could decode into different characters. `urlQueryAllowed` still
    /// admits `&`, `=`, and `#`, so those are reserved explicitly.
    private func urlQueryEncoded(_ raw: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=#")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// URL bar edits drive the params table: the query part is parsed into
    /// rows and the stored URL keeps only its base (no query), so the two
    /// never double up at send time. Row identity and `isEnabled` are
    /// preserved by key match, so editing a value never silently enables a
    /// disabled row; rows the bar does not show (disabled, blank-key) are
    /// kept untouched in the table.
    private func syncParamsFromURLText(_ text: String) {
        // A #fragment is not a query: keep it with the base URL.
        let (withoutFragment, fragment): (String, String) = {
            if let hash = text.firstIndex(of: "#") {
                return (String(text[..<hash]), String(text[hash...]))
            }
            return (text, "")
        }()
        let parts = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let newBase = String(parts[0]) + fragment
        guard parts.count > 1 else {
            if draft.urlString != newBase { draft.urlString = newBase }
            // Only the rows the bar showed (enabled, non-blank key) came
            // from the query; disabled and blank-key rows were never part
            // of it and must survive, matching the merge branch below.
            draft.params = draft.params.filter {
                !$0.isEnabled || $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return
        }
        let pairs: [(key: String, value: String)] = parts[1]
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { raw in
                let kv = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawKey = kv.isEmpty ? "" : String(kv[0])
                let rawValue = kv.count > 1 ? String(kv[1]) : ""
                // Percent-decode so `?q=a%26b` round-trips to the value
                // `a&b` instead of splitting into two rows on the next edit.
                return (
                    key: rawKey.removingPercentEncoding ?? rawKey,
                    value: rawValue.removingPercentEncoding ?? rawValue
                )
            }
        // Reuse identity for rows the bar shows: prefer an enabled row with
        // the same key so value edits never touch `isEnabled`. If only a
        // disabled row matches, the key was explicitly typed on the
        // enabled-rows surface, so reuse it as enabled rather than
        // duplicating the key.
        var remaining = draft.params
        var merged: [QueryParam] = []
        merged.reserveCapacity(pairs.count)
        for pair in pairs {
            if let idx = remaining.firstIndex(where: { $0.key == pair.key && $0.isEnabled }) {
                var row = remaining.remove(at: idx)
                row.value = pair.value
                merged.append(row)
            } else if let idx = remaining.firstIndex(where: { $0.key == pair.key }) {
                var row = remaining.remove(at: idx)
                row.value = pair.value
                row.isEnabled = true
                merged.append(row)
            } else {
                merged.append(QueryParam(key: pair.key, value: pair.value))
            }
        }
        // Rows the bar never shows survive bar edits untouched.
        merged += remaining.filter { !$0.isEnabled || $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Enabled non-blank rows absent from the bar text were deleted there.
        let changed =
            merged.count != draft.params.count
            || zip(merged, draft.params).contains {
                $0.id != $1.id || $0.key != $1.key || $0.value != $1.value || $0.isEnabled != $1.isEnabled
            }
        if draft.urlString != newBase { draft.urlString = newBase }
        if changed { draft.params = merged }
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { urlText },
            set: { newValue in
                let cleaned = newValue.components(separatedBy: .newlines).joined()
                urlText = cleaned
                syncParamsFromURLText(cleaned)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            nameBar
            urlBar
                .zIndex(1)
            sectionTabs
            Divider()
            sectionContent
        }
        .background(.background)
        // Click-anywhere-to-blur for the name field is driven by an NSEvent
        // monitor (see installNameDismissMonitor) - deliberately NOT a
        // SwiftUI tap gesture: a root gesture delays primary mouse events
        // and races the field editor's mouseDown, which makes clicking into
        // the name field itself fail most of the time.
        .onPreferenceChange(RequestNameFrameKey.self) { nameFieldFrame = $0 }
        .overlay { methodMenuOverlay }
        .onPreferenceChange(MethodMenuAnchorKey.self) { methodMenuAnchor = $0 }
        .onChange(of: draft) { _, newDraft in
            store.updateRequest(newDraft)
            // Params-table edits (and request switches) re-compose the URL
            // bar text - unless the user is typing in the URL bar itself. The
            // focused surface always wins, keeping the two-way sync loop-free.
            guard urlFieldFocused == nil else { return }
            urlText = composedURLText(base: newDraft.urlString, params: newDraft.params)
        }
        .onChange(of: request.id) { _, _ in
            urlFieldFocused = nil
            isMethodMenuVisible = false
            isNameFieldFocused = false
            draft = request
            urlText = composedURLText(base: request.urlString, params: request.params)
            section = .params
        }
        .onChange(of: request.folderID) { _, newFolderID in
            // Vault-side folder moves (deleteFolder) must reach the local
            // draft: the editor only fully re-syncs on id changes, and a
            // stale folderID would resurrect the deleted folder on the next
            // keystroke, orphaning the request out of the tree.
            guard draft.folderID != newFolderID else { return }
            draft.folderID = newFolderID
        }
        .onChange(of: request.updatedAt) { _, _ in
            // External reloads replace clean editors' requests in place; a
            // dirty editor keeps its draft (rebasing re-applies the pending
            // snapshot, which carries the draft's own updatedAt, so this
            // parameter never changes for it). Adopt the fresh content so
            // the next keystroke cannot revert the external edit and mark
            // it dirty. Our own saves bump updatedAt too, but then the
            // content is equal and the guard skips the swap.
            guard !store.hasPendingChanges(for: draft.id), !request.isContentEqual(to: draft) else { return }
            draft = request
            urlText = composedURLText(base: request.urlString, params: request.params)
        }
        .onChange(of: urlFieldFocused) { _, focused in
            // The URL bar (and the method dropdown over it) are AppKit-owned
            // fields: claiming them must visibly end name editing even when
            // the SwiftUI focus state lags behind the responder switch.
            if focused != nil { isNameFieldFocused = false }
            guard focused == .url else { return }
            isMethodMenuVisible = false
        }
        .onChange(of: isMethodMenuVisible) { _, visible in
            guard visible else {
                // Dismissing must release the filter's focus claim and drop
                // the arrowed position; otherwise a stranded focus keeps
                // swallowing keystrokes invisibly.
                methodFilterFieldFocused = false
                keyboardMethod = nil
                return
            }
            urlFieldFocused = nil
            hoveredMethod = nil
            keyboardMethod = nil
            methodFilter = ""
            // Postman drops you into the filter so typing narrows the list.
            DispatchQueue.main.async { methodFilterFieldFocused = true }
        }
        .onAppear {
            draft = request
            urlText = composedURLText(base: draft.urlString, params: draft.params)
            installNameDismissMonitor()
        }
        .onDisappear { removeNameDismissMonitor() }
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
            requestNameField
            Spacer(minLength: AppSpacing.medium)
            saveButton
        }
        .padding(.horizontal, AppSpacing.medium)
        // A touch of extra air between the tab strip and this row: the top
        // padding rides inside the pinned height, so nothing below shifts.
        .padding(.top, AppSpacing.xSmall)
        // Fixed-height row: padding-driven heights let extra vertical space
        // (VSplitView panes, taller windows) inflate into blank bands above
        // and below the bar. Pin it like the other toolbar rows.
        .frame(height: AppSize.toolbarHeight + AppSpacing.xSmall)
    }

    /// Postman-style inline request name: quiet heading at rest, light pill
    /// on hover, accent-ring field on focus. The field hugs its text so the
    /// chrome never reads as a wide empty input; a very long name falls back
    /// to the row remainder and scrolls inside while focused. One persistent
    /// TextField per branch - no view swap on state change - so caret, undo,
    /// and the draft push behave like every other field.
    private var requestNameField: some View {
        ViewThatFits(in: .horizontal) {
            requestNameFieldBody
                .fixedSize()
            requestNameFieldBody
        }
        .onHover { isNameHovered = $0 }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RequestNameFrameKey.self,
                    value: geo.frame(in: .global))
            }
        )
        .onChange(of: isNameFieldFocused) { _, focused in
            if focused { nameEditBaseline = draft.name }
        }
    }

    private var requestNameFieldBody: some View {
        TextField("Request Name", text: $draft.name)
            .font(.subheadline.weight(.semibold))
            .textFieldStyle(.plain)
            .focused($isNameFieldFocused)
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .padding(.vertical, AppSpacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(
                        isNameFieldFocused
                            ? AppColor.fieldBackground
                            : (isNameHovered ? AppColor.subtleBackground : .clear)
                    )
            )
            .overlay {
                if isNameFieldFocused {
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .strokeBorder(AppColor.accent, lineWidth: 2)
                }
            }
            .onSubmit { isNameFieldFocused = false }
            .onKeyPress(.escape) {
                draft.name = nameEditBaseline
                isNameFieldFocused = false
                return .handled
            }
    }

    /// Ends name editing when a click lands outside the field. A local
    /// NSEvent monitor observes without consuming, so TextField clicks are
    /// never delayed or stolen (a SwiftUI root gesture would race the field
    /// editor's mouseDown and break focus-by-click). Clicks anywhere else -
    /// chrome, other editors, buttons - read as blur and drop the ring.
    private func installNameDismissMonitor() {
        guard nameDismissMonitor == nil else { return }
        nameDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard isNameFieldFocused, let window = event.window else { return }
                // Window-base -> screen-top-left conversion for SwiftUI .global
                // frames (primary screen top edge, same as TabBarView).
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                let point = CGPoint(
                    x: window.frame.origin.x + event.locationInWindow.x,
                    y: screenTop - window.frame.origin.y - event.locationInWindow.y)
                if !nameFieldFrame.contains(point) {
                    isNameFieldFocused = false
                }
            }
            return event
        }
    }

    private func removeNameDismissMonitor() {
        if let monitor = nameDismissMonitor {
            NSEvent.removeMonitor(monitor)
            nameDismissMonitor = nil
        }
    }

    /// Postman-style Save: shared chip, enabled while the request has
    /// unsaved changes.
    private var saveButton: some View {
        SaveChipButton(isDirty: isDirty, help: "Save Request (⌘S)") {
            urlFieldFocused = nil
            isNameFieldFocused = false
            store.savePendingChanges()
        }
    }

    // MARK: - URL bar

    private var urlBar: some View {
        VStack(spacing: AppSpacing.xSmall) {
            HStack(spacing: AppSpacing.small) {
                HStack(spacing: 0) {
                    MethodPicker(
                        selection: $draft.httpMethod,
                        isExpanded: $isMethodMenuVisible,
                        onToggle: {
                            urlFieldFocused = nil
                            isNameFieldFocused = false
                        }
                    )
                    Color.clear
                        .frame(height: 30)
                        .overlay(alignment: .topLeading) {
                            urlEditor
                        }
                        .zIndex(1)
                }

                // One morphing slot: Send becomes Cancel while a response is
                // pending. A click meant for Cancel can land on the freshly
                // swapped-in Send (same position, double-click habit) - the
                // store drops Sends that immediately follow a cancel, so the
                // misfire never fires a brand-new request.
                if store.isSending {
                    Button {
                        urlFieldFocused = nil
                        store.cancelSend()
                    } label: {
                        Text("Cancel")
                            .frame(minHeight: 22)
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel Request (⎋)")
                } else {
                    Button {
                        urlFieldFocused = nil
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
            .anchorPreference(key: MethodMenuAnchorKey.self, value: .bounds) { $0 }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    private var urlEditor: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: AppRadius.medium,
            topTrailingRadius: AppRadius.medium
        )
        return VariableHighlightEditor(
            text: urlBinding,
            variables: resolvedVariables,
            suggestions: requestSuggestions,
            isSingleLine: false,
            wrapsWhenFocused: true,
            font: .monoURLBar,
            placeholder: "https://api.example.com/users",
            // Zero fragment padding in the bar (see `makeNSView`): the
            // placeholder must start at the view edge like the text.
            placeholderLeadingPadding: 0,
            focus: $urlFieldFocused,
            focusValue: .url,
            autoFocusOnUpdate: false,
            onCommit: { urlFieldFocused = nil },
            onHoverChanged: { hover in
                isURLBarHovered = hover
            }
        )
        .padding(.horizontal, AppSpacing.compact)
        .padding(.vertical, 3)
        // Background tiers mirror the method picker (the other half of the
        // bar): gray wash at rest, deeper gray on hover, bright white while
        // focused (with the accent border).
        .background(
            urlFieldFocused == .url
                ? AppColor.urlFieldBackground
                : (isURLBarHovered ? AppColor.subtleBackground : AppColor.fieldBackground),
            in: shape
        )
        .overlay {
            shape
                .strokeBorder(
                    // Both halves of the bar share the same border tier: the
                    // method picker's idle/hover border never changes, so the
                    // URL bar keeps its border constant too and signals hover
                    // through the fill instead.
                    urlFieldFocused == .url ? AppColor.accent : AppColor.borderStrong,
                    lineWidth: urlFieldFocused == .url ? 2 : 1
                )
                .allowsHitTesting(false)
        }
    }

    private var methodMenuOverlay: some View {
        GeometryReader { proxy in
            let rowBottom = methodMenuAnchor.map { proxy[$0].maxY } ?? 0
            ZStack(alignment: .topLeading) {
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
                        // Anchors below the URL bar row (its resolved bottom),
                        // left-aligned with the method field (the section's
                        // leading padding).
                        .offset(y: rowBottom + AppSpacing.xSmall)
                        .padding(.leading, AppSpacing.medium)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
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
                        guard let pick = keyboardMethod ?? filteredMethods.first else { return }
                        draft.httpMethod = pick
                        isMethodMenuVisible = false
                    }
                    .onExitCommand { isMethodMenuVisible = false }
                    .onKeyPress(.upArrow) {
                        moveKeyboardMethod(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveKeyboardMethod(by: 1)
                        return .handled
                    }
                    .onChange(of: methodFilter) { _, _ in
                        // A new filter invalidates the arrowed position.
                        keyboardMethod = nil
                    }
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
                                                || method == keyboardMethod
                                                ? AppColor.subtleBackground
                                                : Color.clear
                                        )
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            hoveredMethod = hovering ? method : nil
                            // A single highlight: the pointer takes over from
                            // the keyboard position.
                            if hovering { keyboardMethod = nil }
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xSmall)
        }
        .frame(width: 144)
        .popupPanel()
    }

    // MARK: - Section tabs

    private var sectionTabs: some View {
        HStack(spacing: 0) {
            UnderlineTab(
                title: RequestSection.params.rawValue,
                count: enabledParamCount,
                isSelected: section == .params,
                action: {
                    urlFieldFocused = nil
                    section = .params
                }
            )
            UnderlineTab(
                title: RequestSection.auth.rawValue,
                count: isAuthConfigured ? 1 : nil,
                isSelected: section == .auth,
                action: {
                    urlFieldFocused = nil
                    section = .auth
                }
            )
            UnderlineTab(
                title: RequestSection.headers.rawValue,
                count: enabledHeaderCount,
                isSelected: section == .headers,
                action: {
                    urlFieldFocused = nil
                    section = .headers
                }
            )
            UnderlineTab(
                title: RequestSection.body.rawValue,
                count: bodyRowCount,
                isSelected: section == .body,
                action: {
                    urlFieldFocused = nil
                    section = .body
                }
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
                valuePlaceholder: "value",
                allowsReorder: true
            )
            // Fresh table state per request: the editor holds ghost-row and
            // focus state internally, which must not leak across requests.
            .id(draft.id)
        case .headers:
            KeyValueEditor(
                items: $draft.headers,
                makeNew: { HTTPHeader() },
                title: "Headers",
                variables: resolvedVariables,
                suggestions: requestSuggestions,
                keyPlaceholder: "Header-Name",
                valuePlaceholder: "value",
                allowsReorder: true
            )
            .id(draft.id)
        case .auth:
            AuthEditor(request: $draft)
        case .body:
            BodyEditor(request: $draft)
        }
    }
}

// MARK: - Method picker

private struct MethodMenuAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Tracks the inline request-name field's frame so the editor's spatial
/// tap-to-dismiss can spare clicks inside the field.
private struct RequestNameFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct MethodPicker: View {
    @Binding var selection: HTTPMethod
    @Binding var isExpanded: Bool
    var onToggle: () -> Void
    @State private var isHovering = false

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: AppRadius.medium,
            bottomLeadingRadius: AppRadius.medium,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        )
    }

    var body: some View {
        Button {
            onToggle()
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
            .padding(.leading, AppSpacing.xSmall)
            .padding(.trailing, AppSpacing.xSmall)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("HTTP method")
        .padding(.horizontal, AppSpacing.compact)
        .padding(.vertical, 3)
        .background(isHovering && !isExpanded ? AppColor.subtleBackground : AppColor.fieldBackground, in: shape)
        .overlay {
            shape.strokeBorder(
                isExpanded ? AppColor.accent : AppColor.borderStrong,
                lineWidth: isExpanded ? 2 : 1
            )
        }
        .frame(width: AppSize.methodPickerWidth)
    }
}
