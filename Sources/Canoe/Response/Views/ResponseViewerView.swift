import AppKit
import SwiftUI

struct ResponseViewerView: View {
    /// Shorthand for the response data type (defined on the model).
    typealias BodyLanguage = ResponseModel.BodyLanguage

    @Environment(AppStore.self) private var store
    @State private var bodyMode: BodyMode = .pretty
    /// Data type selector (Postman): auto-detect by default; user can pin
    /// JSON/XML/HTML/Text. Only affects Pretty mode rendering.
    @State private var bodyLanguage: BodyLanguage = .auto
    @State private var wordWrap = false
    @State private var responseSection: ResponseSection = .body
    /// Render cache keyed by response + body mode (see refreshBodyRender).
    @State private var bodyRenderKey = ""
    @State private var bodyRenderDisplay = BodyDisplay(text: "", totalCount: nil, language: .text)
    @State private var bodyRenderText = Text("")
    /// The same render as an attributed string: the find overlay needs
    /// attribute access (match backgrounds) without re-running the
    /// tree-sitter parse per keystroke.
    @State private var bodyRenderAttributed = AttributedString("")
    @State private var saveError: String?
    /// Copy Body's in-place acknowledgement: the glyph turns into a
    /// checkmark for a moment. Same language as every other copy control in
    /// the app (the code-snippet copy button, the console's Copy action,
    /// the License panel, the workspace-ID card) - a copy that overwrites
    /// the pasteboard silently gives the user nothing to confirm it ran.
    @State private var didCopyBody = false
    /// Pending reset for the acknowledgement above. Cancelled on every new
    /// copy, so a second copy restarts the window instead of being cut short
    /// by the first one's timer (same pattern as the console's Copy action).
    @State private var copyResetTask: Task<Void, Never>?
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
    /// Media staging for the Preview pane (audio / video / PDF): the temp
    /// file the player or PDF view reads from, the response it was staged
    /// for (guards against re-staging on task restarts), and whether the
    /// last stage attempt failed. See `stageMediaForPreview`.
    @State private var stagedMediaID: UUID?
    @State private var stagedMediaURL: URL?
    @State private var mediaStageFailed = false
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
        case preview = "Preview"
        case hex = "Hex"
        var id: String { rawValue }
    }

    enum ResponseSection: String, CaseIterable, Identifiable {
        // Postman order: Body first and selected by default, then Cookies,
        // then Headers.
        case body = "Body"
        case cookies = "Cookies"
        case headers = "Headers"
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
        .background(AppColor.controlBackground)
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
        // The system empty state, like the console's and the inspectors':
        // the send shortcut rides in its action slot.
        ContentUnavailableView {
            Label("Send a request to get a response", systemImage: "arrow.up.circle")
        } actions: {
            HStack(spacing: AppSpacing.xSmall) {
                keyChip("⌘")
                keyChip("↩")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func keyChip(_ label: String) -> some View {
        Text(label)
            .font(AppFont.small.weight(.medium))
            .monospaced()
            .foregroundStyle(AppColor.textSecondary)
            .padding(.horizontal, AppSpacing.compact)
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
            // Same title token and band as the Console panel it is stacked
            // with (and as the inspectors' headers).
            Text("Response")
                .font(AppFont.panelTitle)
            if store.isSending {
                statusDot
                ProgressView().controlSize(.small)
                Text("Sending…")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
            }
            Spacer()
        }
        .panelToolbar(horizontalPadding: AppSpacing.medium)
        .background(AppColor.controlBackground)
    }

    private var statusDot: some View {
        Text("\u{00B7}")
            .font(AppFont.small)
            .foregroundStyle(AppColor.tertiaryText)
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
                    .font(AppFont.small)
                    .monospacedDigit()
                    .foregroundStyle(AppColor.textSecondary)
            }
        )
    }

    // MARK: - Response detail (Headers | Body tab bar)

    private func responseDetail(_ response: ResponseModel) -> some View {
        // Pretty-printing and tree-sitter highlighting a large body costs
        // hundreds of ms (measured ~80ms + ~90ms at 2MB, plus layout of the
        // resulting Text). Redoing it on every render - header-filter
        // keystrokes, switching tabs back and forth - is the visible lag, so
        // each response+mode renders once and reuses the result: a hit (this
        // frame's key matches) reuses the stored render, a miss (a fresh
        // response or a mode switch) computes synchronously so the first
        // paint is correct, and the task below publishes it for later
        // frames. State is only written from the task, never during view
        // evaluation. Preview mode renders in a player / PDF view / image
        // view and needs no text, so it skips the decode entirely.
        let key = "\(response.id)-\(bodyMode)-\(bodyLanguage)"
        let isPreview = bodyMode == .preview
        let isHex = bodyMode == .hex
        let display: BodyDisplay =
            key == bodyRenderKey
            ? bodyRenderDisplay
            : (isPreview || isHex ? BodyDisplay(text: "", totalCount: nil, language: .text) : bodyDisplay(response))
        let rendered: Text =
            key == bodyRenderKey
            ? bodyRenderText
            : (isPreview || isHex ? Text("") : renderedText(for: display))
        let renderedAttributed: AttributedString =
            key == bodyRenderKey
            ? bodyRenderAttributed
            : (isPreview || isHex
                ? AttributedString("")
                : SyntaxHighlight.attributedText(display.text, syntax: display.syntax))
        return VStack(spacing: 0) {
            sectionBar(response)
            // Same gutter as the request editor's tab bar (labels, underline,
            // divider, content all on one column).
            Divider()
                .padding(.horizontal, AppSpacing.medium)
            if responseSection == .headers {
                headersPane(response)
            } else if responseSection == .cookies {
                cookiesPane(response)
            } else if isPreview {
                previewContent(response)
            } else if isHex {
                hexContent(response)
            } else {
                bodyContent(response, display, rendered: rendered, renderedAttributed: renderedAttributed)
            }
        }
        .task(id: key) {
            // Publish what this frame computed; never recompute it. The body
            // is decoded and pretty-printed once per key, and a second pass
            // here would pay for values already in hand. A task cancelled
            // before it first ran still executes its body, so the stale ones
            // (the id moved on) must not land in the cache.
            guard !Task.isCancelled else { return }
            if key != bodyRenderKey {
                bodyRenderDisplay = display
                bodyRenderText = rendered
                bodyRenderAttributed = renderedAttributed
                bodyRenderKey = key
            }
            // Media previews stream from a staged file, not from `body`
            // (see `stageMediaForPreview`). Runs on every task start so a
            // file removed on disappear is re-staged on reappear, even when
            // the render cache above is already current.
            await stageMediaForPreview(response)
        }
        .onChange(of: response.id) { _, _ in
            saveError = nil
            // The acknowledgement belongs to the response it was copied
            // from: a fresh response must not wear a stale checkmark.
            didCopyBody = false
            // The staged media file belongs to the old response; the next
            // preview (if media again) stages its own.
            removeStagedMedia()
            findVisible = false
            findQuery = ""
            findCurrentIndex = 0
            dismissPanels()
        }
        .onDisappear {
            // Stop playback and drop the staged file; a reappear re-stages
            // it (the render task above runs on every task start).
            removeStagedMedia()
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

    private func renderedText(for display: BodyDisplay) -> Text {
        SyntaxHighlight.highlightedText(display.text, syntax: display.syntax)
    }

    /// Response tab bar - and the panel's top row while a response exists:
    /// Headers/Body tabs leading, the status capsule and send metrics
    /// (duration, size) trailing, mirroring the old title bar's summary.
    private func sectionBar(_ response: ResponseModel) -> some View {
        HStack(spacing: AppSpacing.large) {
            // Postman order: Body leads, then Cookies, then Headers.
            UnderlineTab(
                title: ResponseSection.body.rawValue,
                count: nil,
                labelInset: 0,
                isSelected: responseSection == .body,
                action: { responseSection = .body }
            )
            UnderlineTab(
                title: ResponseSection.cookies.rawValue,
                count: response.cookies.isEmpty ? nil : response.cookies.count,
                labelInset: 0,
                isSelected: responseSection == .cookies,
                action: { responseSection = .cookies }
            )
            UnderlineTab(
                title: ResponseSection.headers.rawValue,
                count: response.headers.isEmpty ? nil : response.headers.count,
                labelInset: 0,
                isSelected: responseSection == .headers,
                action: { responseSection = .headers }
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
        .padding(.horizontal, AppSpacing.medium)
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
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
            }
        )
    }

    /// Postman-style Network panel: connection details for the displayed
    /// response. Empty sections are omitted. Hover-driven - no close button.
    private func networkPanel(_ response: ResponseModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "network")
                    .foregroundStyle(AppColor.textSecondary)
                Text("Network")
                    .font(AppFont.small.weight(.semibold))
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
                        .font(AppFont.emptyStateBody)
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(AppSpacing.medium)
                }
            } else {
                Text("No network details captured for this response.")
                    .font(AppFont.emptyStateBody)
                    .foregroundStyle(AppColor.textSecondary)
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
                            .foregroundStyle(AppColor.textSecondary)
                            .frame(width: 110, alignment: .leading)
                        Text(value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .font(AppFont.small)
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
                    icon: "arrow.up", tint: AppColor.accent, title: "Request Size",
                    total: Int64(size.requestTotal).formattedByteCount,
                    rows: [
                        ("Headers", Int64(size.requestHeaders).formattedByteCount),
                        ("Body", Int64(size.requestBody).formattedByteCount),
                    ]
                )
            } else {
                Text("No size details captured for this response.")
                    .font(AppFont.emptyStateBody)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(AppSpacing.medium)
            }
        }
        .frame(width: AppSize.responsePanelWidth, alignment: .leading)
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
                        .font(AppFont.emptyStateBody)
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(AppSpacing.medium)
                } else {
                    hoverSection(
                        icon: "clock", tint: AppColor.done, title: "Time",
                        total: response.formattedDuration, rows: rows
                    )
                }
            } else {
                Text("No timing details captured for this response.")
                    .font(AppFont.emptyStateBody)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(AppSpacing.medium)
            }
        }
        .frame(width: AppSize.responsePanelWidth, alignment: .leading)
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
                    .font(AppFont.small.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: AppSize.statusChipGlyphBox, height: AppSize.statusChipGlyphBox)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                            // The shared badge wash, so a status chip here
                            // matches every other tinted chip in the app.
                            .fill(AppColor.badgeBackground(tint))
                    )
                Text(title)
                    .font(AppFont.small.weight(.semibold))
                Spacer(minLength: 0)
                Text(total)
                    .font(AppFont.small.weight(.semibold))
                    .monospacedDigit()
            }
            ForEach(rows, id: \.0) { label, value in
                HStack {
                    Text(label)
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(.leading, AppSize.statusChipGlyphBox + AppSpacing.small)
                    Spacer(minLength: 0)
                    Text(value)
                        .monospacedDigit()
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
        .font(AppFont.small)
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
                // Language is part of the key: the data-type selector changes
                // the display text (pretty-printed JSON vs raw), so ranges
                // computed on one language do not index into another.
                let rangesKey = "\(response.id)-\(bodyMode)-\(bodyLanguage)-\(findQuery)"
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
                    bodyScroll(
                        response, display, rendered: effectiveRender, matchCount: matchCount,
                        currentIndex: currentIndex)
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
            // Postman's data type selector (Pretty mode only): Auto resolves
            // to the detected type; JSON/XML/HTML highlight via the shared
            // tree-sitter grammars, Text stays plain.
            if bodyMode == .pretty {
                DropdownFieldButton(
                    id: "response.body.language",
                    label: bodyLanguageLabel,
                    width: 128
                ) {
                    ResponseModel.BodyLanguage.allCases.map { language in
                        DropdownRow.action(
                            language == .auto
                                ? "Auto (\(response.resolvedBodyLanguage(.auto)).rawValue)"
                                : language.rawValue,
                            isSelected: language == bodyLanguage
                        ) {
                            bodyLanguage = language
                        }
                    }
                }
                .help("Response data type (sets the syntax highlighting)")
            }
            Spacer()
            HStack(spacing: AppSpacing.small) {
                // Word wrap and find are text-mode tools: hidden in Preview
                // (the web view wraps its own content and has its own find)
                // and in Hex (fixed-width columns).
                if bodyMode != .preview && bodyMode != .hex {
                    // `text.wordwrap` does not exist in this OS's SF Symbols set
                    // (the button renders an empty glyph); `arrow.turn.down.left`
                    // is the wrap-arrow editors use.
                    Button("Toggle Word Wrap", systemImage: "arrow.turn.down.left") {
                        wordWrap.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(IconButtonStyle())
                    .foregroundStyle(wordWrap ? AppColor.accent : AppColor.textSecondary)
                    .help(wordWrap ? "Disable word wrap" : "Enable word wrap")
                    Button("Find in Response", systemImage: "magnifyingglass") {
                        findVisible = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(IconButtonStyle())
                    .foregroundStyle(findVisible ? AppColor.accent : AppColor.textSecondary)
                    .help("Find in Response (⌘F)")
                }
                Button("Copy Body", systemImage: didCopyBody ? "checkmark" : "doc.on.doc") {
                    let copyText: String
                    if bodyMode == .hex {
                        copyText = hexCopyText(for: response)
                    } else if bodyMode == .preview {
                        copyText = response.bodyString
                    } else {
                        copyText = fullBodyText(response, display: display)
                    }
                    copyBody(copyText)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(didCopyBody ? AppColor.success : AppColor.textPrimary)
                .help(
                    didCopyBody
                        ? "Copied"
                        : (response.bodyTruncated
                            ? "Copy response body (truncated)"
                            : "Copy full response body"))
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

    /// Label of the data-type selector: Auto shows the detected type in
    /// parentheses (Postman auto-selects by Content-Type), a manual pick
    /// shows its own name.
    private var bodyLanguageLabel: String {
        guard bodyLanguage == .auto, let response = store.displayedResponse else {
            return bodyLanguage.rawValue
        }
        return "Auto (\(response.resolvedBodyLanguage(.auto)).rawValue)"
    }

    private func bodyScroll(
        _ response: ResponseModel, _ display: BodyDisplay, rendered: Text,
        matchCount: Int, currentIndex: Int?
    ) -> some View {
        VStack(spacing: 0) {
            if response.bodyTruncated {
                // The transport-level cap (HTTPClient.maxResponseBytes), not
                // the render limit below: the bytes past it were never kept,
                // so "save the body" cannot recover them either.
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(AppFont.small)
                    Text(
                        "Response body exceeded \(Int64(HTTPClient.maxResponseBytes).formattedByteCount) and was truncated."
                    )
                    .font(AppFont.small)
                }
                .foregroundStyle(AppColor.textSecondary)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.xSmall)
                Divider()
            }
            if let totalCount = display.totalCount {
                let shown = display.text.count.formatted()
                let total = totalCount.formatted()
                HStack {
                    Image(systemName: "info.circle")
                        .font(AppFont.small)
                    // "Save the body" is only true for the render limit - a
                    // body cut at the transport cap has nothing more to save,
                    // and saying otherwise would send the user to a file that
                    // is missing the tail.
                    Text(
                        response.bodyTruncated
                            ? "Showing the first \(shown) of \(total) characters."
                            : "Showing the first \(shown) of \(total) characters. Save the body to keep it all."
                    )
                    .font(AppFont.small)
                }
                .foregroundStyle(AppColor.textSecondary)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.xSmall)
                Divider()
            }
            ScrollView(wordWrap ? .vertical : [.vertical, .horizontal]) {
                // Cached render (see responseDetail) - never rebuild
                // the highlighted Text here.
                rendered
                    .font(AppFont.monoSubheadline)
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
                    ScrolledUnderEdgeShadow()
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
                index == currentIndex
                ? AppColor.accent.opacity(AppOpacity.searchHighlight) : AppColor.warning.opacity(AppOpacity.searchHighlight)
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
                .font(AppFont.small)
                .foregroundStyle(AppColor.tertiaryText)
            TextField("Find", text: $findQuery)
                .borderlessFieldChrome(isFocused: findFieldFocused)
                .font(AppFont.small)
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
            .font(AppFont.small)
            .monospacedDigit()
            .foregroundStyle(AppColor.textSecondary)
            Button {
                stepFind(-1, matchCount: matchCount)
            } label: {
                Image(systemName: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .disabled(matchCount == 0)
            .accessibilityLabel("Previous Match")
            .help("Previous Match (⇧⌘G)")
            Button {
                stepFind(1, matchCount: matchCount)
            } label: {
                Image(systemName: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .disabled(matchCount == 0)
            .accessibilityLabel("Next Match")
            .help("Next Match (⌘G)")
            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Close Find")
            .help("Close Find (Esc)")
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.compact)
        .popupPanel()
    }

    private struct BodyDisplay {
        let text: String
        let totalCount: Int?
        /// The resolved display language: decides the highlight grammar.
        let language: ResponseModel.BodyLanguage

        /// The tree-sitter grammar for this language: JSON and XML have
        /// their own; HTML shares the XML one (SGML-style tags); Text is
        /// plain.
        var syntax: BodySyntax {
            switch language {
            case .json: .json
            case .xml, .html: .xml
            case .auto, .text: .plain
            }
        }
    }

    /// The body as this pane shows it: the current mode's text (with the
    /// data-type selector applied), capped at `bodyDisplayLimit` characters.
    private func bodyDisplay(_ response: ResponseModel) -> BodyDisplay {
        // One decode answers both questions the pane has - the resolved
        // language and its text - so they come from one parse.
        let decoded = response.bodyText(prettify: bodyMode == .pretty, language: bodyLanguage)
        guard decoded.text.count > Self.bodyDisplayLimit else {
            return BodyDisplay(text: decoded.text, totalCount: nil, language: decoded.language)
        }
        return BodyDisplay(
            text: String(decoded.text.prefix(Self.bodyDisplayLimit)),
            totalCount: decoded.text.count,
            language: decoded.language
        )
    }

    // MARK: - Preview (image / audio / video / PDF)

    /// Bodies above this skip the image render: a preview is a rendering
    /// convenience, not a reason to decode a 50 MB bitmap into memory.
    /// Audio/video/PDF previews are exempt - they stream from a staged
    /// file instead of decoding the whole body.
    private static let maxPreviewBodyBytes = 4 * 1024 * 1024

    /// Postman-style Preview: images render through `NSImage` (pure
    /// native, decode-capped), audio/video through the system player and
    /// PDFs through PDFKit (both streaming from a staged temp file);
    /// everything else points back to Pretty/Raw.
    @ViewBuilder
    private func previewContent(_ response: ResponseModel) -> some View {
        if response.body.isEmpty {
            ContentUnavailableView(
                "Empty Response Body",
                systemImage: "doc.text",
                description: Text("This response did not return any body content.")
            )
        } else if response.bodyTruncated {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "eye.slash",
                description: Text(
                    "The body was truncated at \(Int64(HTTPClient.maxResponseBytes).formattedByteCount);"
                        + " preview needs the complete content."
                )
            )
        } else if response.isVideoBody || response.isAudioBody {
            if MediaPlayerPreview.isPlayable(mimeType: response.mimeType) {
                mediaPreview(response)
            } else {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "eye.slash",
                    description: Text(
                        "The system cannot decode \(response.mimeType ?? "this media type") content; use Raw to inspect it."
                    )
                )
            }
        } else if response.isPDFBody {
            mediaPreview(response)
        } else if response.isImageBody {
            if response.body.count > Self.maxPreviewBodyBytes {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "eye.slash",
                    description: Text(
                        "The image is larger than \(Int64(Self.maxPreviewBodyBytes).formattedByteCount); use Raw to inspect it."
                    )
                )
            } else if let image = NSImage(data: response.body) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(minWidth: 100, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                        .padding(AppSpacing.medium)
                }
                .background(AppColor.codeBackground)
            } else {
                // Image-typed but undecodable (corrupt bytes).
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "eye.slash",
                    description: Text("The image data could not be decoded; use Raw to inspect it.")
                )
            }
        } else {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "eye.slash",
                description: Text(
                    "Canoe previews image, audio, video, and PDF responses."
                        + " This body is \(response.mimeType ?? "of unknown type"); use Pretty or Raw."
                )
            )
        }
    }

    /// The staged-media preview: the player (audio/video) or PDF view once
    /// the body has landed in its temp file, a loading state while the
    /// write runs, and a failure notice if it never does.
    @ViewBuilder
    private func mediaPreview(_ response: ResponseModel) -> some View {
        if let url = stagedMediaURL, stagedMediaID == response.id {
            if response.isPDFBody {
                PDFPreview(url: url)
            } else {
                MediaPlayerPreview(url: url)
            }
        } else if mediaStageFailed {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "eye.slash",
                description: Text("The media could not be staged for playback; use Raw to inspect it.")
            )
        } else {
            LoadingState(message: "Preparing preview…")
        }
    }

    // MARK: - Media staging (audio / video / PDF)

    /// Writes the body to a temp file so AVKit and PDFKit can read it (they
    /// load from URLs, not in-memory `Data`). Called from the body render
    /// task; the write itself hops to a detached task, so a 50 MB body
    /// never blocks the main actor. The previous response's file is removed
    /// first, so staged files don't pile up, and re-staging is skipped while
    /// this response's file still exists (task restarts on mode switches
    /// would otherwise rewrite it on every toggle).
    private func stageMediaForPreview(_ response: ResponseModel) async {
        guard bodyMode == .preview,
            response.isVideoBody || response.isAudioBody || response.isPDFBody
        else { return }
        if stagedMediaID == response.id,
            let url = stagedMediaURL,
            FileManager.default.fileExists(atPath: url.path)
        {
            return
        }
        removeStagedMedia()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "canoe-response-\(response.id).\(MediaPlayerPreview.fileExtension(forMimeType: response.mimeType))"
            )
        let body = response.body
        let wrote = await Task.detached(priority: .userInitiated) {
            (try? body.write(to: url, options: .atomic)) != nil
        }.value
        guard !Task.isCancelled else {
            // Stale stage (the response or mode moved on while the write
            // ran): drop the file so it doesn't linger unnoticed.
            try? FileManager.default.removeItem(at: url)
            return
        }
        if wrote {
            stagedMediaURL = url
            stagedMediaID = response.id
            mediaStageFailed = false
        } else {
            mediaStageFailed = true
        }
    }

    /// Deletes the staged file (if any) and forgets it: before a new stage,
    /// when the response changes, and when the viewer goes away.
    private func removeStagedMedia() {
        if let url = stagedMediaURL {
            try? FileManager.default.removeItem(at: url)
        }
        stagedMediaURL = nil
        stagedMediaID = nil
        mediaStageFailed = false
    }

    // MARK: - Hex dump

    /// Hex dump is only offered for bodies up to this size: a 50 MB body
    /// would expand to millions of rows and freeze the renderer, and the
    /// Copy Body text would be ~180 MB. Use Raw for anything larger.
    private static let maxHexBodyBytes = 5 * 1024 * 1024

    /// One line of the hex dump: 8-byte-grouped hex bytes plus an ASCII
    /// column (non-printable shown as `.`).
    private struct HexRow {
        let offset: String
        let hex: String
        let ascii: String
    }

    /// Splits `data` into 16-byte hex-dump rows.
    private func hexRows(for data: Data) -> [HexRow] {
        var rows: [HexRow] = []
        for offset in stride(from: 0, to: data.count, by: 16) {
            let end = min(offset + 16, data.count)
            let bytes = data[offset..<end]
            var hexParts: [String] = []
            for (index, byte) in bytes.enumerated() {
                if index > 0 {
                    hexParts.append(index % 8 == 0 ? "  " : " ")
                }
                hexParts.append(String(format: "%02X", byte))
            }
            let hex = hexParts.joined()
            let ascii = String(
                bytes.map { byte in
                    (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "."
                }
            )
            rows.append(
                HexRow(
                    offset: String(format: "%08X", offset),
                    hex: hex,
                    ascii: ascii
                )
            )
        }
        return rows
    }

    /// Hex-dump rendering of the response body: offset, 16 bytes per row,
    /// with an ASCII column. Mirrors the layout Postman shows for binary
    /// bodies in its response viewer.
    @ViewBuilder
    private func hexContent(_ response: ResponseModel) -> some View {
        if response.body.isEmpty {
            ContentUnavailableView(
                "Empty Response Body",
                systemImage: "doc.text",
                description: Text("This response did not return any body content.")
            )
        } else if response.body.count > Self.maxHexBodyBytes {
            ContentUnavailableView(
                "Hex Dump Unavailable",
                systemImage: "eye.slash",
                description: Text(
                    "The body is larger than \(Int64(Self.maxHexBodyBytes).formattedByteCount); use Raw to inspect it."
                )
            )
        } else {
            VStack(spacing: 0) {
                if response.bodyTruncated {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(AppFont.small)
                        Text(
                            "Response body exceeded \(Int64(HTTPClient.maxResponseBytes).formattedByteCount) and was truncated."
                        )
                        .font(AppFont.small)
                    }
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, AppSpacing.medium)
                    .padding(.vertical, AppSpacing.xSmall)
                    Divider()
                }
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hexRows(for: response.body).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 0) {
                                Text(row.offset)
                                    .font(AppFont.monoSubheadline)
                                    .foregroundStyle(AppColor.textSecondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(row.hex)
                                    .font(AppFont.monoSubheadline)
                                    .foregroundStyle(AppColor.textPrimary)
                                Spacer(minLength: 0)
                                Text(row.ascii)
                                    .font(AppFont.monoSubheadline)
                                    .foregroundStyle(AppColor.textSecondary)
                                    .frame(minWidth: 16, alignment: .leading)
                            }
                            .padding(.horizontal, AppSpacing.medium)
                            .padding(.vertical, 1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(AppColor.codeBackground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Hex string of the full body for the Copy Body action in Hex mode.
    /// Returns an empty string when the body is too large to safely dump.
    private func hexCopyText(for response: ResponseModel) -> String {
        guard response.body.count <= Self.maxHexBodyBytes else { return "" }
        return hexRows(for: response.body).map { row in
            "\(row.offset)  \(row.hex)  \(row.ascii)"
        }.joined(separator: "\n")
    }

    // MARK: - Cookies

    /// Postman-style response Cookies view: every cookie the response set,
    /// one row per cookie with its attributes. Read-only - these describe
    /// what the server asked for. Stored cookies are managed from the Cookie Jar.
    private var manageCookiesLink: some View {
        LinkButton("Manage Cookies…") {
            (NSApp.delegate as? AppDelegate)?.openCookies()
        }
        .help("Manage stored cookies")
    }

    @ViewBuilder
    private func cookiesPane(_ response: ResponseModel) -> some View {
        let cookies = response.cookies
        if cookies.isEmpty {
            VStack(spacing: AppSpacing.small) {
                ContentUnavailableView(
                    "No Cookies",
                    systemImage: "cookie",
                    description: Text("This response did not set any cookies.")
                )
                manageCookiesLink
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    manageCookiesLink
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.bottom, AppSpacing.xSmall)
                HStack(spacing: 0) {
                    cookieColumnHeader("Name", width: 160)
                    cookieColumnHeader("Value", width: nil)
                    cookieColumnHeader("Domain", width: 140)
                    cookieColumnHeader("Path", width: 110)
                    cookieColumnHeader("Expires", width: 150)
                    cookieColumnHeader("Flags", width: 120)
                }
                .frame(height: AppSize.tableRowHeight)
                .background(AppColor.tableHeaderBackground)
                Rectangle()
                    .fill(AppColor.tableBorder)
                    .frame(height: AppLine.hairline)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(cookies.enumerated()), id: \.offset) { index, cookie in
                            cookieRow(cookie)
                            if index < cookies.count - 1 {
                                Rectangle()
                                    .fill(AppColor.tableBorder)
                                    .frame(height: AppLine.hairline)
                            }
                        }
                    }
                }
            }
            .contextMenu {
                Button("Copy All as Text") {
                    copyToPasteboard(cookies.map { self.cookieText($0) }.joined(separator: "\n"))
                }
            }
        }
    }

    private func cookieColumnHeader(_ text: String, width: CGFloat?) -> some View {
        cookieTextColumn(text: text, mono: false, width: width)
            .font(AppFont.columnHeader)
            .foregroundStyle(AppColor.textSecondary)
    }

    /// One fixed-width (or flexible, `width` = nil) text cell of the
    /// cookies table.
    private func cookieTextColumn(text: String, mono: Bool, width: CGFloat?) -> some View {
        Group {
            if let width {
                Text(text).frame(width: width, alignment: .leading)
            } else {
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(mono ? AppFont.monoSubheadline : AppFont.small)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .padding(.horizontal, AppSpacing.small)
    }

    private func cookieRow(_ cookie: HTTPCookie) -> some View {
        HStack(spacing: 0) {
            cookieTextColumn(text: cookie.name, mono: true, width: 160)
            cookieTextColumn(text: cookie.value, mono: true, width: nil)
            cookieTextColumn(text: cookie.domain, mono: false, width: 140)
            cookieTextColumn(text: cookie.path, mono: false, width: 110)
            cookieTextColumn(
                text: cookie.expiresDate.map { formatter.string(from: $0) } ?? "Session",
                mono: false,
                width: 150
            )
            HStack(spacing: AppSpacing.xxSmall) {
                cookieFlag("Secure", isOn: cookie.isSecure)
                cookieFlag("HttpOnly", isOn: cookie.isHTTPOnly)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppSpacing.small)
            .frame(width: 120, alignment: .leading)
        }
        .frame(height: AppSize.tableRowHeight)
        .help(cookieText(cookie))
    }

    private func cookieFlag(_ label: String, isOn: Bool) -> some View {
        Text(label)
            .font(AppFont.small)
            .foregroundStyle(isOn ? AppColor.textSecondary : AppColor.tertiaryText)
            .opacity(isOn ? 1 : 0.5)
    }

    /// The Netscape-ish text form used by the copy action and the row help.
    private func cookieText(_ cookie: HTTPCookie) -> String {
        var parts = ["\(cookie.name)=\(cookie.value)", "Domain=\(cookie.domain)", "Path=\(cookie.path)"]
        if let expires = cookie.expiresDate {
            parts.append("Expires=\(formatter.string(from: expires))")
        }
        if cookie.isSecure { parts.append("Secure") }
        if cookie.isHTTPOnly { parts.append("HttpOnly") }
        return parts.joined(separator: "; ")
    }

    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }

    // MARK: - Headers

    @ViewBuilder
    private func headersPane(_ response: ResponseModel) -> some View {
        if response.headers.isEmpty && !response.usesPseudoHeaders {
            ContentUnavailableView(
                "No Headers",
                systemImage: "list.bullet.indent",
                description: Text("This response did not return any headers.")
            )
        } else {
            // Same grid as the request editor's headers table, in its bare
            // two-column form (no checkbox/action columns, no ghost row): a
            // pure content display whose leading edge sits on the shared
            // 12pt gutter. The 8pt top pad keeps it from crowding the
            // section-bar divider.
            KeyValueEditor(
                items: .constant([]),
                makeNew: { HTTPHeader() },
                readOnlyItems: headerRows(for: response),
                showsGhostRow: false,
                showsIconColumns: false,
                // Response tables skip the header wash.
                headerBackground: nil
            )
            .padding(.top, AppSpacing.small)
            .contextMenu {
                Button("Copy All as Text") {
                    copyToPasteboard(
                        headerRows(for: response)
                            .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                }
            }
        }
    }

    /// The rows shown above, in display order: HTTP/2+ leads with `:status`,
    /// which is where the HTTP/1.x status line went (RFC 9113 §8.2.2).
    private func headerRows(for response: ResponseModel) -> [KeyValueReadOnlyItem] {
        var rows: [KeyValueReadOnlyItem] = response.headers.map {
            KeyValueReadOnlyItem(
                id: $0.id.uuidString,
                key: $0.key,
                value: $0.value,
                showsKeyInfo: false
            )
        }
        guard response.usesPseudoHeaders else { return rows }
        rows.insert(
            KeyValueReadOnlyItem(
                id: ":status",
                key: ":status",
                value: "\(response.statusCode)",
                showsKeyInfo: false
            ),
            at: 0
        )
        return rows
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Copy plus the in-place acknowledgement.
    private func copyBody(_ text: String) {
        copyToPasteboard(text)
        didCopyBody = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            didCopyBody = false
        }
    }

    /// The full body text for the current mode (not the truncated preview):
    /// Copy and Save both act on everything the server returned.
    private func fullBodyText(_ response: ResponseModel, display: BodyDisplay) -> String {
        if display.totalCount == nil { return display.text }
        return response.bodyText(prettify: bodyMode == .pretty, language: bodyLanguage).text
    }

    /// Saves the response body to a file, like Postman's "Save Response".
    /// "Full" means everything this response holds: a body cut at the
    /// transport cap (`HTTPClient.maxResponseBytes`) is saved as the prefix
    /// that survived - the panel's truncation banner is the user's warning
    /// that the file is partial. The suggested extension follows the
    /// response MIME. The id suffix keeps two saves within the same second
    /// from suggesting the same filename and silently overwriting each other.
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
            .animation(AppMotion.quick, value: isHovering)
    }
}
