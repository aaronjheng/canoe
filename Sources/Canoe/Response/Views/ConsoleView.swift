import SwiftUI

/// Postman-style network console: every send lands here with the actual
/// request (resolved URL, headers with a masked Authorization) and the
/// response or error it produced. Entries are session-scoped.
struct ConsoleView: View {
    @Environment(AppStore.self) private var store
    @State private var errorsOnly = false
    @State private var expandedIDs: Set<UUID> = []
    @State private var copiedEntryID: UUID?
    /// Whether the log is currently scrolled to the bottom. New entries only
    /// autoscroll when this holds, so sending never yanks the user away from
    /// history they are reading.
    @State private var isAtBottom = true
    /// Clear wipes the whole log (see the button), so it asks first - the
    /// session log has no undo.
    @State private var showClearConfirm = false

    private var visibleEntries: [ConsoleEntry] {
        errorsOnly ? store.consoleEntries.filter(\.isError) : store.consoleEntries
    }

    private var errorCount: Int {
        store.consoleEntries.filter(\.isError).count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if visibleEntries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .background(AppColor.controlBackground)
        .confirmationDialog(
            "Clear the console log",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Console", role: .destructive) { store.clearConsole() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(store.consoleEntries.count) entries from this session will be permanently deleted.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: AppSpacing.small) {
            Text("Console")
                .font(AppFont.panelTitle)
            if errorCount > 0 {
                Badge(
                    text: "\(errorCount)",
                    systemImage: "exclamationmark.triangle.fill",
                    foregroundColor: AppColor.error,
                    backgroundColor: AppColor.badgeBackground(AppColor.error)
                )
            }
            Spacer(minLength: 0)
            Picker("Filter", selection: $errorsOnly) {
                Text("All Logs").tag(false)
                Text("Errors").tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Button("Clear", systemImage: "trash") {
                showClearConfirm = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            // Clear wipes everything, not just the filtered view: with the
            // Errors filter on, an empty visible list must not enable the
            // destruction of the hidden successful entries.
            .disabled(visibleEntries.isEmpty)
            .help("Clear console")
        }
        .panelToolbar(horizontalPadding: AppSpacing.medium)
    }

    private var emptyState: some View {
        // The system empty state, like every other panel's (the key chips
        // ride in its action slot, so the shortcut is still spelled out).
        ContentUnavailableView {
            Label(
                errorsOnly ? "No errors in this session" : "No network activity yet",
                systemImage: "network")
        } description: {
            Text("Every request you send is logged here with its actual URL, headers, and response.")
        } actions: {
            HStack(spacing: AppSpacing.xSmall) {
                keyChip("⌘")
                keyChip("↩")
            }
        }
    }

    private func keyChip(_ label: String) -> some View {
        Text(label)
            .font(AppFont.small.weight(.medium))
            .monospaced()
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.compact)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(AppColor.subtleBackground)
            )
    }

    // MARK: - Entries

    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleEntries) { entry in
                        ConsoleEntryRow(
                            entry: entry,
                            isExpanded: expandedIDs.contains(entry.id),
                            copied: copiedEntryID == entry.id,
                            onToggle: { toggle(entry) },
                            onCopyRaw: { copyRaw(entry) }
                        )
                        Divider()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("console-bottom")
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
            }
            .onChange(of: store.consoleEntries.count) { _, _ in
                guard isAtBottom else { return }
                proxy.scrollTo("console-bottom", anchor: .bottom)
            }
        }
    }

    private func toggle(_ entry: ConsoleEntry) {
        if expandedIDs.contains(entry.id) {
            expandedIDs.remove(entry.id)
        } else {
            expandedIDs.insert(entry.id)
        }
    }

    private func copyRaw(_ entry: ConsoleEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.rawLog, forType: .string)
        copiedEntryID = entry.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }
}

/// One console row: status icon, method, actual URL, and - when expanded -
/// the full request/response details beneath it (Postman-style inline log).
private struct ConsoleEntryRow: View {
    let entry: ConsoleEntry
    let isExpanded: Bool
    let copied: Bool
    let onToggle: () -> Void
    let onCopyRaw: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow
                .contentShape(Rectangle())
                // Hover feedback for the whole clickable summary row; the
                // translucent fill sits on top of the error tint and merely
                // mutes it a little, so error rows keep their identity.
                .background(AppColor.subtleBackground.opacity(isHovering ? 1 : 0))
                .onTapGesture { onToggle() }
                .onHover { isHovering = $0 }
                .clickCursor()
                // LazyVStack recycling does not guarantee an onHover(false)
                // when a hovered row scrolls away - clear it so the fill
                // never reappears stuck on without the pointer.
                .onDisappear { isHovering = false }
            if isExpanded {
                ConsoleEntryDetail(entry: entry, copied: copied, onCopyRaw: onCopyRaw)
            }
        }
        .background(entry.isError ? AppColor.error.opacity(AppOpacity.errorBackground) : Color.clear)
    }

    private var summaryRow: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(AppFont.small.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                .font(AppFont.small)
                .foregroundStyle(entry.isError ? AppColor.error : AppColor.success)
            if let method = HTTPMethod(rawValue: entry.method) {
                MethodTag(method: method)
            } else {
                Text(entry.method)
                    .font(AppFont.cellText.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Text(entry.url)
                .font(AppFont.monoSubheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppSpacing.small)
            if entry.isError {
                Text("Error")
                    .font(AppFont.small.weight(.medium))
                    .foregroundStyle(AppColor.error)
            } else if let statusCode = entry.statusCode {
                Text("\(statusCode)")
                    .font(AppFont.statusCodeCompact)
                    .monospacedDigit()
                    .foregroundStyle(AppColor.statusColor(statusCode))
            }
            if let duration = entry.formattedDuration {
                Text(duration)
                    .font(AppFont.small)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.compact)
    }
}

/// The expanded log: request headers (Authorization masked), bodies, and the
/// response or error, with a "Copy Raw Log" shortcut.
private struct ConsoleEntryDetail: View {
    let entry: ConsoleEntry
    let copied: Bool
    /// Rendered body cap: the formatted view shows a triage excerpt, the
    /// full text goes through Copy.
    private static let bodyPreviewLimit = 16 * 1024
    /// Raw view cap: bodies are already capped on storage, keep the text
    /// view responsive on top of that.
    private static let rawViewLimit = 64 * 1024
    @State private var showRaw = false
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack {
                Text(entry.formattedTime)
                    .font(AppFont.small)
                    .monospacedDigit()
                    .foregroundStyle(AppColor.tertiaryText)
                Spacer(minLength: 0)
                Button(
                    action: { showRaw.toggle() },
                    label: {
                        Label(
                            showRaw ? "Show Formatted" : "Show Raw HTTP",
                            systemImage: showRaw ? "list.bullet.rectangle" : "curlybraces.square"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(AppFont.small)
                    }
                )
                .buttonStyle(LinkButtonStyle())
                .foregroundStyle(AppColor.accent)
                Button(action: onCopyRaw) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(AppFont.small)
                }
                .buttonStyle(LinkButtonStyle())
                .foregroundStyle(AppColor.accent)
            }
            if showRaw {
                bodyBlock(rawText)
            } else {
                sectionTitle("Request Headers")
                headerList(entry.requestHeaders)
                if let bodyText = bodyPreview(entry.requestBody, truncated: entry.requestBodyTruncated) {
                    sectionTitle("Request Body")
                    bodyBlock(bodyText)
                }
                if let statusCode = entry.statusCode {
                    sectionTitle("Response")
                    HStack(spacing: AppSpacing.small) {
                        Text(entry.statusText)
                            .font(AppFont.small.weight(.medium))
                            .foregroundStyle(AppColor.statusColor(statusCode))
                        if let duration = entry.formattedDuration {
                            Text(duration)
                                .font(AppFont.small)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !entry.responseHeaders.isEmpty {
                        sectionTitle("Response Headers")
                        headerList(entry.responseHeaders)
                    }
                    if let bodyText = bodyPreview(entry.responseBody, truncated: entry.responseBodyTruncated) {
                        sectionTitle("Response Body")
                        bodyBlock(bodyText)
                    }
                } else if let error = entry.error {
                    sectionTitle("Error")
                    bodyBlock(error)
                }
            }
        }
        .padding(.leading, AppSpacing.xLarge + AppSpacing.small)
        .padding(.trailing, AppSpacing.medium)
        .padding(.bottom, AppSpacing.small)
    }

    private let onCopyRaw: () -> Void

    /// The HTTP exchange, kept responsive: storage already caps bodies and
    /// the view further trims the tail (Copy carries the full text).
    private var rawText: String {
        let raw = entry.rawLog
        guard raw.count <= Self.rawViewLimit else {
            let remainder = raw.count - Self.rawViewLimit
            return String(raw.prefix(Self.rawViewLimit)) + "\n… (\(remainder) more characters; use Copy)"
        }
        return raw
    }

    init(entry: ConsoleEntry, copied: Bool, onCopyRaw: @escaping () -> Void) {
        self.entry = entry
        self.copied = copied
        self.onCopyRaw = onCopyRaw
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.microHeader)
            .foregroundStyle(.secondary)
    }

    private func headerList(_ headers: [HTTPHeader]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            ForEach(headers) { header in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(header.key): ")
                        .font(AppFont.monoSubheadline)
                        .foregroundStyle(.primary)
                    Text("\"\(header.value)\"")
                        .font(AppFont.monoSubheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// The triage excerpt: full text lives in the raw log copy.
    private func bodyPreview(_ data: Data?, truncated: Bool) -> String? {
        guard let data, !data.isEmpty else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            return "<binary data, \(data.count) bytes>"
        }
        guard text.count <= Self.bodyPreviewLimit else {
            let remainder = text.count - Self.bodyPreviewLimit
            return String(text.prefix(Self.bodyPreviewLimit)) + "\n… (\(remainder) more characters; use Copy Raw Log)"
        }
        if truncated {
            return text + "\n… (stored excerpt was capped)"
        }
        return text
    }

    private func bodyBlock(_ text: String) -> some View {
        Text(text)
            .font(AppFont.monoSubheadline)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.small)
            .background(AppColor.codeBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .strokeBorder(AppColor.hairline)
            )
    }
}
