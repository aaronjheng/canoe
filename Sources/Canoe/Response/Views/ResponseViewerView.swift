import AppKit
import SwiftUI

struct ResponseViewerView: View {
    @Environment(AppStore.self) private var store
    @State private var bodyMode: BodyMode = .pretty
    @State private var wordWrap = true
    @State private var headerFilter = ""
    @State private var responseSection: ResponseSection = .body

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
            .foregroundStyle(.secondary.opacity(0.6))
    }

    private func statusMetric(_ value: String, systemImage: String) -> some View {
        Label(value, systemImage: systemImage)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    // MARK: - Response detail (Headers | Body tab bar)

    private func responseDetail(_ response: ResponseModel) -> some View {
        let display = bodyDisplay(response)
        return VStack(spacing: 0) {
            sectionBar(response)
            Divider()
            if responseSection == .body {
                bodyContent(response, display)
            } else {
                headersPane(response)
            }
        }
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

    private func bodyContent(_ response: ResponseModel, _ display: BodyDisplay) -> some View {
        Group {
            if display.text.isEmpty {
                ContentUnavailableView(
                    "Empty Response Body",
                    systemImage: "doc.text",
                    description: Text("This response did not return any body content.")
                )
            } else {
                VStack(spacing: 0) {
                    bodyToolbar(response, display.text)
                    Divider()
                    bodyScroll(display)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Body tools inside the content area (not on the tab row): the format
    /// switcher leads, per-body actions trail. Hidden for an empty body -
    /// the tools have nothing to act on.
    private func bodyToolbar(_ response: ResponseModel, _ bodyText: String) -> some View {
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
                .buttonStyle(.borderless)
                .foregroundStyle(wordWrap ? AppColor.accent : .secondary)
                .help(wordWrap ? "Disable word wrap" : "Enable word wrap")
                Button("Copy Body", systemImage: "doc.on.doc") {
                    copyToPasteboard(bodyText)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy response body")
                Button("Save Response", systemImage: "square.and.arrow.down") {
                    saveResponse(response)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Save response body to a file…")
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
    }

    private func bodyScroll(_ display: BodyDisplay) -> some View {
        VStack(spacing: 0) {
            if let totalCount = display.totalCount {
                let shown = display.text.count.formatted()
                let total = totalCount.formatted()
                HStack {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("Showing the first \(shown) of \(total) characters. Copy the body to see it all.")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.xSmall)
                Divider()
            }
            ScrollView(wordWrap ? .vertical : [.vertical, .horizontal]) {
                Group {
                    if display.isJSON {
                        JSONSyntaxHighlight.highlightedText(display.text)
                    } else {
                        Text(display.text)
                    }
                }
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
                FilterField(text: $headerFilter, placeholder: "Search Headers", verticalPadding: AppSpacing.small)
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
                    List(matches) { header in
                        headerRow(header)
                    }
                }
            }
        }
    }

    private func headerRow(_ header: HTTPHeaderField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.medium) {
            Text(header.key)
                .font(AppFont.monoSubheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(minWidth: 160, alignment: .leading)
            Text(header.value)
                .font(AppFont.monoSubheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button("Copy Value") { copyToPasteboard(header.value) }
            Button("Copy Header") { copyToPasteboard("\(header.key): \(header.value)") }
        }
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Saves the full (untruncated) response body to a file, like Postman's
    /// "Save Response". The suggested extension follows the response MIME.
    private func saveResponse(_ response: ResponseModel) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue =
            "response-\(response.statusCode)-\(Int(response.timestamp.timeIntervalSince1970)).\(fileExtension(for: response))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url)
        } catch {
            AppLogger.error("Failed to save response body: \(error)", category: "Response")
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
