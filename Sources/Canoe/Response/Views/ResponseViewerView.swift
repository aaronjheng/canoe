import AppKit
import SwiftUI

struct ResponseViewerView: View {
    @Environment(AppStore.self) private var store
    @State private var bodyMode: BodyMode = .pretty
    @State private var wordWrap = false
    @State private var headerFilter = ""
    @State private var responseSection: ResponseSection = .body
    @State private var headerSort: [KeyPathComparator<HTTPHeader>] = []
    @State private var headerSelection: HTTPHeader.ID?
    /// Render cache keyed by response + body mode (see refreshBodyRender).
    @State private var bodyRenderKey = ""
    @State private var bodyRenderDisplay = BodyDisplay(text: "", totalCount: nil, isJSON: false)
    @State private var bodyRenderText = Text("")
    /// The same render as an attributed string: the find overlay needs
    /// attribute access (match backgrounds) without re-running the
    /// tree-sitter parse per keystroke.
    @State private var bodyRenderAttributed = AttributedString("")
    @State private var saveError: String?
    /// Response-body find (⌘F): query, bar visibility, and which match is
    /// the current one (index into the match list, cycled by ⌘G/⇧⌘G).
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findCurrentIndex = 0
    @FocusState private var findFieldFocused: Bool
    /// Find render cache (see bodyContent): keyed by response/mode/query/
    /// current index, so unrelated state changes (word wrap, banner) reuse
    /// it instead of rescanning a 200K body.
    @State private var findMatchRangesKey = ""
    @State private var findMatchRanges: [Range<String.Index>] = []
    /// Whether the body scroll view has moved away from the top: drives the
    /// toolbar/content hairline (Postman draws the same line once the
    /// content scrolls under the toolbar).
    @State private var isBodyScrolledPastTop = false
    /// Hover-panel machinery shared by the metrics-row entries (network
    /// chip, time metric, size metric): a panel stays up while its anchor
    /// or itself is under the cursor, and hides after a short grace once
    /// both have left, so crossing the gap does not flicker it away. Only
    /// one panel is ever up - they share the same top-trailing overlay
    /// slot, so showing one replaces any other.
    private enum HoverPanelKind: Equatable {
        case network, size, time
    }

    /// Per-anchor hover flags - independent booleans, because exit/enter
    /// events of adjacent chips can interleave and a single "which anchor"
    /// slot would lose the still-hovered one.
    @State private var networkStatusHovered = false
    @State private var sizeMetricHovered = false
    @State private var timeMetricHovered = false
    /// Which panel (if any) is under the cursor / currently shown. Only
    /// one panel is on screen at a time, so a single slot each is safe.
    @State private var hoveredPanel: HoverPanelKind?
    @State private var visiblePanel: HoverPanelKind?
    @State private var panelHideTask: Task<Void, Never>?

    /// Max characters rendered in the body pane. Beyond this a single SwiftUI
    /// `Text` becomes sluggish, so the view shows a prefix plus a notice.
    private static let bodyDisplayLimit = 200_000

    enum BodyMode: String, CaseIterable, Identifiable {
        case pretty = "Pretty"
        case raw = "Raw"
        var id: String { rawValue }
    }

    enum ResponseSection: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case body = "Body"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The title bar only exists before the first response arrives:
            // once there is a response the tab bar (status capsule + metrics)
            // becomes the top row, so a "Response" heading would waste a row.
            if store.displayedResponse == nil {
                statusBar
            }
            content
        }
        .background(.background)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.isSending {
            LoadingState(message: "Sending request…")
        } else if let error = store.sendError {
            ErrorBanner(message: error) { store.sendError = nil }
                .padding(AppSpacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let response = store.displayedResponse {
            responseDetail(response)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        // Postman-style hint: muted copy plus the actual send shortcut.
        VStack(spacing: AppSpacing.medium) {
            Text("Send a request to get a response")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: AppSpacing.xSmall) {
                keyChip("⌘")
                keyChip("↩")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func keyChip(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .monospaced()
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(AppColor.subtleBackground)
            )
    }

    // MARK: - Status bar

    /// Pre-response header: the panel title plus the sending indicator.
    /// Hidden entirely once a response exists - its other content (history
    /// menu, status capsule, metrics) has moved to the tab bar or away.
    private var statusBar: some View {
        HStack(spacing: AppSpacing.medium) {
            Text("Response")
                .font(.subheadline.weight(.bold))
            if store.isSending {
                statusDot
                ProgressView().controlSize(.small)
                Text("Sending…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(minHeight: AppSize.toolbarHeight)
        .background(AppColor.controlBackground)
    }

    private var statusDot: some View {
        Text("\u{00B7}")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    /// One trailing metric in the tab bar ("261 ms"). `onHover` opts a
    /// metric into the hover-panel behavior (the time and size breakdowns);
    /// the pill itself makes the panel discoverable.
    private func statusMetric(
        _ value: String,
        systemImage: String,
        onHover: ((Bool) -> Void)? = nil
    ) -> some View {
        MetricHoverChip(
            onHover: onHover,
            content: {
                Label(value, systemImage: systemImage)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        )
    }

    // MARK: - Response detail (Headers | Body tab bar)

    private func responseDetail(_ response: ResponseModel) -> some View {
        let key = "\(response.id)-\(bodyMode)"  // Cache hit: reuse the rendered Text. Miss (a fresh response or mode
        // switch): compute synchronously for this frame so the first paint is
        // correct; the task below warms the cache so later renders
        // (header-filter keystrokes, tab switches) reuse it. State is only
        // written from the task, never during view evaluation.
        let display: BodyDisplay = key == bodyRenderKey ? bodyRenderDisplay : bodyDisplay(response)
        let rendered: Text = key == bodyRenderKey ? bodyRenderText : renderedText(for: display)
        let renderedAttributed =
            key == bodyRenderKey
            ? bodyRenderAttributed
            : (display.isJSON ? SyntaxHighlight.attributedText(display.text) : AttributedString(display.text))
        return VStack(spacing: 0) {
            sectionBar(response)
            Divider()
            if responseSection == .body {
                bodyContent(response, display, rendered: rendered, renderedAttributed: renderedAttributed)
            } else {
                headersPane(response)
            }
        }
        .task(id: key) {
            updateBodyRenderCache(response, key: key)
        }
        // A header search typed for one response must not leak into the next:
        // without this a stale filter renders "No Matching Headers" for a
        // response that does have headers.
        .onChange(of: response.id) { _, _ in
            headerFilter = ""
            saveError = nil
            findVisible = false
            findQuery = ""
            findCurrentIndex = 0
            dismissPanels()
        }
        .overlay(alignment: .topTrailing) {
            switch visiblePanel {
            case .network:
                hoverPanel(networkPanel(response), kind: .network)
            case .size:
                hoverPanel(sizePanel(response), kind: .size)
            case .time:
                hoverPanel(timePanel(response), kind: .time)
            case .none:
                EmptyView()
            }
        }
    }

    /// Shared chrome for the hover panels: under the section bar (status
    /// row), clear of the trailing metrics - the anchor that opened the
    /// panel lives there - above other content; hovering the panel itself
    /// keeps it open. The hover tracking wraps ONLY the card: the outer
    /// padding must stay hover-inert, or the panel's frame would reach up
    /// into the metrics row and swallow the neighboring anchors' hover
    /// events (panels could then never hand off to each other).
    private func hoverPanel(_ panel: some View, kind: HoverPanelKind) -> some View {
        panel
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveredPanel = hovering ? kind : nil
                refreshPanel(kind)
            }
            .padding(.top, AppSize.toolbarHeight + AppSpacing.xSmall)
            .padding(.trailing, AppSpacing.small)
            .zIndex(1)
    }

    /// Show the panel for `kind` while its anchor chip or the panel itself
    /// is hovered; hide after the short grace once both have left.
    private func refreshPanel(_ kind: HoverPanelKind) {
        panelHideTask?.cancel()
        if isAnchorHovered(kind) || hoveredPanel == kind {
            visiblePanel = kind
        } else if visiblePanel == kind {
            panelHideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                if !Task.isCancelled, !isAnchorHovered(kind), hoveredPanel != kind, visiblePanel == kind {
                    visiblePanel = nil
                }
            }
        }
    }

    private func isAnchorHovered(_ kind: HoverPanelKind) -> Bool {
        switch kind {
        case .network: networkStatusHovered
        case .size: sizeMetricHovered
        case .time: timeMetricHovered
        }
    }

    private func dismissPanels() {
        panelHideTask?.cancel()
        networkStatusHovered = false
        sizeMetricHovered = false
        timeMetricHovered = false
        hoveredPanel = nil
        visiblePanel = nil
    }

    /// Pretty-printing and tree-sitter highlighting a large body costs
    /// hundreds of ms (measured ~80ms + ~90ms at 2MB, plus layout of the
    /// resulting Text). Redoing it on every render - header-filter
    /// keystrokes, switching tabs back and forth - is the visible lag, so
    /// each response+mode renders once and reuses the result.
    private func updateBodyRenderCache(_ response: ResponseModel, key: String) {
        guard key != bodyRenderKey else { return }
        let display = bodyDisplay(response)
        bodyRenderDisplay = display
        bodyRenderText = renderedText(for: display)
        bodyRenderAttributed =
            display.isJSON
            ? SyntaxHighlight.attributedText(display.text)
            : AttributedString(display.text)
        bodyRenderKey = key
    }

    private func renderedText(for display: BodyDisplay) -> Text {
        display.isJSON ? SyntaxHighlight.highlightedText(display.text) : Text(display.text)
    }

    /// Response tab bar - and the panel's top row while a response exists:
    /// Headers/Body tabs leading, the status capsule and send metrics
    /// (duration, size) trailing, mirroring the old title bar's summary.
    private func sectionBar(_ response: ResponseModel) -> some View {
        HStack(spacing: 0) {
            UnderlineTab(
                title: ResponseSection.headers.rawValue,
                count: response.headers.isEmpty ? nil : response.headers.count,
                isSelected: responseSection == .headers,
                action: { responseSection = .headers }
            )
            UnderlineTab(
                title: ResponseSection.body.rawValue,
                count: nil,
                isSelected: responseSection == .body,
                action: { responseSection = .body }
            )
            Spacer()
            HStack(spacing: AppSpacing.small) {
                statusDot
                StatusCapsule(statusCode: response.statusCode, statusText: response.statusText)
                statusDot
                statusMetric(
                    response.formattedDuration, systemImage: "clock",
                    onHover: { hovering in
                        timeMetricHovered = hovering
                        refreshPanel(.time)
                    })
                statusDot
                statusMetric(
                    response.formattedSize, systemImage: "doc",
                    onHover: { hovering in
                        sizeMetricHovered = hovering
                        refreshPanel(.size)
                    })
                statusDot
                networkStatus
            }
        }
        .padding(.horizontal, AppSpacing.small)
    }

    /// Network details entry in the metrics row - icon only. Not a button:
    /// hovering it reveals the Network details panel (chip wash makes the
    /// affordance visible).
    private var networkStatus: some View {
        MetricHoverChip(
            onHover: { hovering in
                networkStatusHovered = hovering
                refreshPanel(.network)
            },
            content: {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        )
    }

    /// Postman-style Network panel: connection details for the displayed
    /// response. Empty sections are omitted. Hover-driven - no close button.
    private func networkPanel(_ response: ResponseModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text("Network")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)

            if let network = response.network {
                let connectionRows: [(String, String?)] = [
                    ("HTTP Version", network.httpVersion),
                    ("Local Address", network.localAddress),
                    ("Remote Address", network.remoteAddress),
                ]
                let tlsRows: [(String, String?)] = [
                    ("TLS Protocol", network.tlsProtocol),
                    ("Cipher Name", network.cipherName),
                ]
                let certRows: [(String, String?)] = [
                    ("Certificate CN", network.certificateCN),
                    ("Issuer CN", network.issuerCN),
                    ("Valid Until", network.formattedValidUntil),
                ]
                let hasConnection = connectionRows.contains { $0.1 != nil }
                let hasTLS = tlsRows.contains { $0.1 != nil }
                let hasCert = certRows.contains { $0.1 != nil }
                if hasConnection {
                    Divider()
                    networkSection(connectionRows)
                }
                if hasTLS {
                    Divider()
                    networkSection(tlsRows)
                }
                if hasCert {
                    Divider()
                    networkSection(certRows)
                }
                if !hasConnection, !hasTLS, !hasCert {
                    Text("No network details captured for this response.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(AppSpacing.medium)
                }
            } else {
                Text("No network details captured for this response.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.medium)
            }
        }
        .frame(width: 380, alignment: .leading)
        .popupPanel()
    }

    private func networkSection(_ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            ForEach(rows, id: \.0) { label, value in
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.medium) {
                        Text(label)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    /// Postman-style Size panel: the displayed response's byte breakdown -
    /// what came back (headers + body) and what went out. Hover-driven - no
    /// close button.
    private func sizePanel(_ response: ResponseModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let size = response.size {
                hoverSection(
                    icon: "arrow.down", tint: AppColor.accent, title: "Response Size",
                    total: Int64(size.responseTotal).formattedByteCount,
                    rows: [
                        ("Headers", Int64(size.responseHeaders).formattedByteCount),
                        ("Body", Int64(size.responseBody).formattedByteCount),
                    ]
                )
                Divider()
                hoverSection(
                    icon: "arrow.up", tint: AppColor.warning, title: "Request Size",
                    total: Int64(size.requestTotal).formattedByteCount,
                    rows: [
                        ("Headers", Int64(size.requestHeaders).formattedByteCount),
                        ("Body", Int64(size.requestBody).formattedByteCount),
                    ]
                )
            } else {
                Text("No size details captured for this response.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.medium)
            }
        }
        .frame(width: 300, alignment: .leading)
        .popupPanel()
    }

    /// Chrome DevTools-style Time panel: where the displayed response's
    /// time went - DNS, connection, TLS, upload, wait, download. Hover-
    /// driven - no close button. Absent phases (a reused connection skips
    /// DNS/TCP/TLS) are omitted; the total matches the status bar metric.
    private func timePanel(_ response: ResponseModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let timing = response.timing {
                let rows: [(String, String)] = [
                    ("DNS Lookup", timing.dns?.formattedPhaseDuration),
                    ("TCP Handshake", timing.tcp?.formattedPhaseDuration),
                    ("TLS Handshake", timing.tls?.formattedPhaseDuration),
                    ("Request Sent", timing.requestSent?.formattedPhaseDuration),
                    ("Waiting (TTFB)", timing.waiting?.formattedPhaseDuration),
                    ("Content Download", timing.download?.formattedPhaseDuration),
                ]
                .compactMap { label, value in value.map { (label, $0) } }
                if rows.isEmpty {
                    Text("No timing phases captured for this response.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(AppSpacing.medium)
                } else {
                    hoverSection(
                        icon: "clock", tint: AppColor.done, title: "Time",
                        total: response.formattedDuration, rows: rows
                    )
                }
            } else {
                Text("No timing details captured for this response.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.medium)
            }
        }
        .frame(width: 300, alignment: .leading)
        .popupPanel()
    }

    /// One hover-panel block (Size, Time): tinted icon chip, title, and
    /// bold total on the first row; the label/value rows indented to align
    /// with the title under it (Postman layout).
    private func hoverSection(
        icon: String, tint: Color, title: String, total: String, rows: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            .fill(tint.opacity(0.15))
                    )
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(total)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            ForEach(rows, id: \.0) { label, value in
                HStack {
                    Text(label)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)  // clears the chip (20) + gap (8)
                    Spacer(minLength: 0)
                    Text(value)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    private func bodyContent(
        _ response: ResponseModel, _ display: BodyDisplay,
        rendered: Text, renderedAttributed: AttributedString
    ) -> some View {
        Group {
            if display.text.isEmpty {
                ContentUnavailableView(
                    "Empty Response Body",
                    systemImage: "doc.text",
                    description: Text("This response did not return any body content.")
                )
            } else {
                // Find state resolves here (the display text lives in this
                // scope): the render swaps to the match-highlighted variant
                // only while the bar is open with a query - the cached
                // no-find render stays the default path for large bodies.
                let findActive = findVisible && !findQuery.isEmpty
                let rangesKey = "\(response.id)-\(bodyMode)-\(findQuery)"
                // Match list cached per response/mode/query (keyed task
                // below warms it, sync-on-miss keeps the first paint
                // correct): word-wrap toggles, banners, and other unrelated
                // state changes reuse it instead of rescanning a 200K body.
                let matchRanges: [Range<String.Index>] =
                    findActive
                    ? (rangesKey == findMatchRangesKey
                        ? findMatchRanges
                        : computeMatches(in: display.text, query: findQuery))
                    : []
                let matchCount = matchRanges.count
                let currentIndex: Int? = matchCount > 0 ? abs(findCurrentIndex) % matchCount : nil
                let effectiveRender: Text =
                    findActive
                    ? findHighlightedBody(
                        attributed: renderedAttributed,
                        query: findQuery,
                        currentIndex: currentIndex
                    )
                    : rendered
                VStack(spacing: 0) {
                    if let saveError {
                        ErrorBanner(message: saveError) { self.saveError = nil }
                            .padding(.horizontal, AppSpacing.medium)
                            .padding(.top, AppSpacing.xSmall)
                    }
                    bodyToolbar(response, display: display)
                    bodyScroll(display, rendered: effectiveRender, matchCount: matchCount, currentIndex: currentIndex)
                    // ⌘F: open the find bar. Lives inside the body content, so
                    // the shortcut exists exactly while a body is on screen.
                    // The shortcut buttons MUST stay inside this VStack as
                    // zero-size rows: as Group siblings of the VStack they
                    // would each become their own flexible row under the
                    // shared .frame(maxHeight: .infinity) below, splitting the
                    // pane's height four ways and collapsing the body
                    // viewport to a quarter of the response pane.
                    Button("Find in Response") {
                        findVisible = true
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                    // ⌘G / ⇧⌘G: next / previous match (VS Code convention).
                    // No-op while find is closed (no matches counted).
                    Button("Next Match") {
                        stepFind(1, matchCount: matchCount)
                    }
                    .keyboardShortcut("g", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                    Button("Previous Match") {
                        stepFind(-1, matchCount: matchCount)
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
                .task(id: rangesKey) {
                    guard findActive else {
                        if !findMatchRangesKey.isEmpty {
                            findMatchRangesKey = ""
                            findMatchRanges = []
                        }
                        return
                    }
                    guard rangesKey != findMatchRangesKey else { return }
                    findMatchRanges = computeMatches(in: display.text, query: findQuery)
                    findMatchRangesKey = rangesKey
                }
                .onChange(of: findVisible) { _, visible in
                    if visible { findFieldFocused = true }
                }
                // Editing the query rewinds to the first match (VS Code
                // behavior); the old current index means nothing to a new
                // match list.
                .onChange(of: findQuery) { _, _ in
                    findCurrentIndex = 0
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Body tools inside the content area (not on the tab row): the format
    /// switcher leads, per-body actions trail. Hidden for an empty body -
    /// the tools have nothing to act on. Copy writes the full body (not the
    /// truncated preview); Save writes the full bytes to a file.
    private func bodyToolbar(_ response: ResponseModel, display: BodyDisplay) -> some View {
        HStack(spacing: AppSpacing.small) {
            Picker("Body Mode", selection: $bodyMode) {
                ForEach(BodyMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            HStack(spacing: AppSpacing.small) {
                // `text.wordwrap` does not exist in this OS's SF Symbols set
                // (the button renders an empty glyph); `arrow.turn.down.left`
                // is the wrap-arrow editors use.
                Button("Toggle Word Wrap", systemImage: "arrow.turn.down.left") {
                    wordWrap.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(wordWrap ? AppColor.accent : .secondary)
                .help(wordWrap ? "Disable word wrap" : "Enable word wrap")
                Button("Find in Response", systemImage: "magnifyingglass") {
                    findVisible = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(findVisible ? AppColor.accent : .secondary)
                .help("Find in Response (⌘F)")
                Button("Copy Body", systemImage: "doc.on.doc") {
                    copyToPasteboard(fullBodyText(response, display: display))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Copy full response body")
                Button("Save Response", systemImage: "square.and.arrow.down") {
                    saveResponse(response)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("Save response body to a file…")
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
    }

    private func bodyScroll(
        _ display: BodyDisplay, rendered: Text,
        matchCount: Int, currentIndex: Int?
    ) -> some View {
        VStack(spacing: 0) {
            if let totalCount = display.totalCount {
                let shown = display.text.count.formatted()
                let total = totalCount.formatted()
                HStack {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("Showing the first \(shown) of \(total) characters. Save the body to keep it all.")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.xSmall)
                Divider()
            }
            ScrollView(wordWrap ? .vertical : [.vertical, .horizontal]) {
                // Cached render (see updateBodyRenderCache) - never rebuild
                // the highlighted Text here.
                rendered
                    .font(AppFont.monoBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: wordWrap ? .infinity : nil, alignment: .leading)
                    .fixedSize(horizontal: !wordWrap, vertical: false)
                    .padding(AppSpacing.medium)
            }
            .background(AppColor.codeBackground)
            // Scroll state for the toolbar/content hairline above: visible
            // once the content has moved under the toolbar, hidden at the
            // top (a 1pt threshold ignores float noise; bounce above the top
            // stays hidden).
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, isPastTop in
                isBodyScrolledPastTop = isPastTop
            }
            // Postman-style scrolled-under affordance: hairline plus a short
            // shadow fading over the content. Overlaid, not laid out, so
            // crossing the scroll threshold never shifts the content.
            .overlay(alignment: .top) {
                if isBodyScrolledPastTop {
                    BodyToolbarEdgeShadow()
                }
            }
            // The find widget overlays the body area itself (below the
            // toolbar/banner): an ErrorBanner's dismiss stays clickable while
            // find is open.
            .overlay(alignment: .topTrailing) {
                if findVisible {
                    findBar(matchCount: matchCount, currentIndex: currentIndex)
                        .padding(AppSpacing.medium)
                }
            }
        }
    }

    // MARK: - Find in response body

    /// Case-insensitive, in-order occurrences of `query` in `text` (the
    /// match list both the count display and the highlights are built from,
    /// so "N of M" can never disagree with what's on screen).
    private func computeMatches(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchStart..<text.endIndex
        ) {
            ranges.append(range)
            searchStart = range.upperBound
            guard searchStart < text.endIndex else { break }
        }
        return ranges
    }

    private func countMatches(in text: String, query: String) -> Int {
        computeMatches(in: text, query: query).count
    }

    /// The body with every match of the find query backed in amber and the
    /// current one in accent. Single pass over a COPY of the cached
    /// attributed render (COW - no tree-sitter re-parse); the search runs in
    /// attributed space so highlight ranges never need index conversion.
    private func findHighlightedBody(
        attributed base: AttributedString,
        query: String,
        currentIndex: Int?
    ) -> Text {
        var attributed = base
        var searchRange = attributed.startIndex..<attributed.endIndex
        var index = 0
        while !searchRange.isEmpty {
            guard
                let found = attributed[searchRange].range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            else { break }
            attributed[found].backgroundColor =
                index == currentIndex ? AppColor.accent.opacity(0.45) : AppColor.warning.opacity(0.35)
            searchRange = found.upperBound..<attributed.endIndex
            index += 1
        }
        return Text(attributed)
    }

    /// Steps the current match (⌘G / ⇧⌘G / chevrons / Return), wrapping at
    /// both ends.
    private func stepFind(_ delta: Int, matchCount: Int) {
        guard matchCount > 0 else { return }
        findCurrentIndex = (findCurrentIndex + delta + matchCount) % matchCount
    }

    private func closeFind() {
        findVisible = false
        findFieldFocused = false
    }

    /// VS Code-style find widget, overlaid on the body's top-trailing
    /// corner: query field, match count, prev/next, close.
    private func findBar(matchCount: Int, currentIndex: Int?) -> some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Find", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .frame(width: 150)
                .focused($findFieldFocused)
                .onSubmit { stepFind(1, matchCount: matchCount) }
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) {
                        stepFind(-1, matchCount: matchCount)
                        return .handled
                    }
                    return .ignored
                }
                .onExitCommand { closeFind() }
            Group {
                if findQuery.isEmpty {
                    Text("Type to search")
                } else if matchCount == 0 {
                    Text("No Results")
                } else if let currentIndex {
                    Text("\(currentIndex + 1) of \(matchCount)")
                }
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            Button {
                stepFind(-1, matchCount: matchCount)
            } label: {
                Image(systemName: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .disabled(matchCount == 0)
            .help("Previous Match (⇧⌘G)")
            Button {
                stepFind(1, matchCount: matchCount)
            } label: {
                Image(systemName: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .disabled(matchCount == 0)
            .help("Next Match (⌘G)")
            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .help("Close Find (Esc)")
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xSmall + 2)
        .popupPanel()
    }

    private struct BodyDisplay {
        let text: String
        let totalCount: Int?
        /// True when Pretty mode shows JSON - then `text` renders highlighted.
        let isJSON: Bool
    }

    /// Computes the display text once per render (the pretty-print is the
    /// expensive part for large JSON bodies).
    private func bodyDisplay(_ response: ResponseModel) -> BodyDisplay {
        let isJSON = bodyMode == .pretty && response.isJSONBody
        let full =
            switch bodyMode {
            case .pretty: response.prettyBodyString
            case .raw: response.bodyString
            }
        guard full.count > Self.bodyDisplayLimit else {
            return BodyDisplay(text: full, totalCount: nil, isJSON: isJSON)
        }
        return BodyDisplay(text: String(full.prefix(Self.bodyDisplayLimit)), totalCount: full.count, isJSON: isJSON)
    }

    // MARK: - Headers

    @ViewBuilder
    private func headersPane(_ response: ResponseModel) -> some View {
        if response.headers.isEmpty {
            ContentUnavailableView(
                "No Headers",
                systemImage: "list.bullet.indent",
                description: Text("This response did not return any headers.")
            )
        } else {
            VStack(spacing: 0) {
                FilterField(text: $headerFilter, placeholder: "Search Headers", isBoxed: true)
                    .padding(.vertical, AppSpacing.xSmall)
                let query = headerFilter.trimmingCharacters(in: .whitespacesAndNewlines)
                let matches = response.headers.filter { header in
                    query.isEmpty
                        || header.key.localizedCaseInsensitiveContains(query)
                        || header.value.localizedCaseInsensitiveContains(query)
                }
                if matches.isEmpty {
                    ContentUnavailableView(
                        "No Matching Headers",
                        systemImage: "magnifyingglass",
                        description: Text("No headers match the current search.")
                    )
                } else {
                    Table(matches.sorted(using: headerSort), selection: $headerSelection, sortOrder: $headerSort) {
                        TableColumn("Key", value: \.key) { header in
                            Text(header.key)
                                .textSelection(.enabled)
                        }
                        .width(min: 120, ideal: 200)
                        TableColumn("Value", value: \.value) { header in
                            Text(header.value)
                                .textSelection(.enabled)
                        }
                    }
                    .contextMenu {
                        Button("Copy All as Text") {
                            copyToPasteboard(
                                matches.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                        }
                        if let selected = matches.first(where: { $0.id == headerSelection }) {
                            Button("Copy Value") { copyToPasteboard(selected.value) }
                            Button("Copy Header") { copyToPasteboard("\(selected.key): \(selected.value)") }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// The full body text for the current mode (not the truncated preview):
    /// Copy and Save both act on everything the server returned.
    private func fullBodyText(_ response: ResponseModel, display: BodyDisplay) -> String {
        if display.totalCount == nil { return display.text }
        switch bodyMode {
        case .pretty: return response.prettyBodyString
        case .raw: return response.bodyString
        }
    }

    /// Saves the full (untruncated) response body to a file, like Postman's
    /// "Save Response". The suggested extension follows the response MIME.
    /// The id suffix keeps two saves within the same second from suggesting
    /// the same filename and silently overwriting each other.
    private func saveResponse(_ response: ResponseModel) {
        saveError = nil
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let timestamp = Int(response.timestamp.timeIntervalSince1970)
        let idSuffix = response.id.uuidString.prefix(8)
        let ext = fileExtension(for: response)
        panel.nameFieldStringValue = "response-\(response.statusCode)-\(timestamp)-\(idSuffix).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url)
            saveError = nil
        } catch {
            AppLogger.error("Failed to save response body: \(error)", category: "Response")
            saveError = "Could not save the response body: \(error.localizedDescription)"
        }
    }

    private func fileExtension(for response: ResponseModel) -> String {
        let mime = (response.mimeType ?? "").lowercased()
        if mime.contains("json") { return "json" }
        if mime.contains("xml") { return "xml" }
        if mime.contains("html") { return "html" }
        if mime.hasPrefix("text/") { return "txt" }
        return "bin"
    }
}

/// Postman-style scrolled-under affordance for the body toolbar: a hairline
/// at the content's top edge plus a short shadow fading downward, so the
/// body reads as sliding under the toolbar once it scrolls. Pure overlay -
/// no layout impact, no hit testing.
private struct BodyToolbarEdgeShadow: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.12), location: 0),
                    .init(color: .black.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 7)
        }
        .allowsHitTesting(false)
    }
}

/// Metric chip that opens a hover panel: row-token wash on hover so the
/// panel is discoverable. `onHover` also feeds the panel's anchor state.
private struct MetricHoverChip<Content: View>: View {
    var onHover: ((Bool) -> Void)?
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, AppSpacing.xxSmall)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(isHovering ? AppColor.subtleBackground : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                onHover?(hovering)
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
