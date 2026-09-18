import AppKit
import SwiftUI

struct ResponseViewerView: View {
    @Environment(AppStore.self) private var store
    @State private var bodyMode: BodyMode = .pretty
    @State private var wordWrap = true
    @State private var headerFilter = ""
    @State private var responseSection: ResponseSection = .body
    @State private var headerSort: [KeyPathComparator<HTTPHeaderField>] = []
    @State private var headerSelection: HTTPHeaderField.ID?
    /// Render cache keyed by response + body mode (see refreshBodyRender).
    @State private var bodyRenderKey = ""
    @State private var bodyRenderDisplay = BodyDisplay(text: "", totalCount: nil, isJSON: false)
    @State private var bodyRenderText = Text("")
    @State private var saveError: String?

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

    private func statusMetric(_ value: String, systemImage: String) -> some View {
        Label(value, systemImage: systemImage)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
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
        return VStack(spacing: 0) {
            sectionBar(response)
            Divider()
            if responseSection == .body {
                bodyContent(response, display, rendered: rendered)
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
        }
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
                statusMetric(response.formattedDuration, systemImage: "clock")
                statusDot
                statusMetric(response.formattedSize, systemImage: "doc")
            }
        }
        .padding(.horizontal, AppSpacing.small)
    }

    private func bodyContent(_ response: ResponseModel, _ display: BodyDisplay, rendered: Text) -> some View {
        Group {
            if display.text.isEmpty {
                ContentUnavailableView(
                    "Empty Response Body",
                    systemImage: "doc.text",
                    description: Text("This response did not return any body content.")
                )
            } else {
                VStack(spacing: 0) {
                    if let saveError {
                        ErrorBanner(message: saveError) { self.saveError = nil }
                            .padding(.horizontal, AppSpacing.medium)
                            .padding(.top, AppSpacing.xSmall)
                    }
                    bodyToolbar(response, display: display)
                    Divider()
                    bodyScroll(display, rendered: rendered)
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
                Button("Toggle Word Wrap", systemImage: "text.wordwrap") {
                    wordWrap.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(wordWrap ? AppColor.accent : .secondary)
                .help(wordWrap ? "Disable word wrap" : "Enable word wrap")
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

    private func bodyScroll(_ display: BodyDisplay, rendered: Text) -> some View {
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
        }
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
                FilterField(text: $headerFilter, placeholder: "Search Headers")
                Divider()
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
