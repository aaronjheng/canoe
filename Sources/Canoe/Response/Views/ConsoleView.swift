import SwiftUI

/// Postman-style network console: every send lands here with the actual
/// request (resolved URL, headers with a masked Authorization) and the
/// response or error it produced. Entries are session-scoped.
struct ConsoleView: View {
    @Environment(AppStore.self) private var store
    @State private var errorsOnly = false
    @State private var expandedIDs: Set<UUID> = []
    /// Whether the log is currently scrolled to the bottom. New entries only
    /// autoscroll when this holds, so sending never yanks the user away from
    /// history they are reading.
    @State private var isAtBottom = true
    /// Whether each row leads with its timestamp (the "Show Timestamps"
    /// option in the overflow menu). Display-only, like the error filter -
    /// the expanded entry always spells its own time out.
    @State private var showTimestamps = false
    /// Whether the log is scrolled past its top, so the toolbar seam shows
    /// the same scrolled-under shadow the response body carries.
    @State private var isListScrolledPastTop = false
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
            // The section claims the remaining height. Without a flexible
            // child the stack sizes to its content and the caller's
            // .frame(height:) centers it, so the toolbar sits in a band that
            // moves as the console is dragged - worst on an empty log, whose
            // fixed-size empty state never fills the panel.
            if visibleEntries.isEmpty {
                emptyState.frame(maxHeight: .infinity)
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
            Text("All \(store.consoleEntries.count) entries will be permanently deleted.")
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
            DropdownFieldButton(
                id: "console.filter",
                label: errorsOnly ? "Errors" : "All Logs",
                width: 120
            ) {
                [
                    DropdownRow.action("All Logs", isSelected: !errorsOnly) { errorsOnly = false },
                    DropdownRow.action("Errors", isSelected: errorsOnly) { errorsOnly = true },
                ]
            }
            // An eraser, not a trash can: `trash` is this app's language for
            // deleting a thing (a request, a collection, a history entry),
            // while this wipes the log view and leaves nothing behind. It
            // also stays distinct from the ✕ sitting right next to it.
            Button("Clear", systemImage: "eraser") {
                showClearConfirm = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(AppColor.textSecondary)
            // Clear wipes everything, not just the filtered view: with the
            // Errors filter on, an empty visible list must not enable the
            // destruction of the hidden successful entries.
            .disabled(visibleEntries.isEmpty)
            .help("Clear console")
            // Overflow menu for the panel's display options (the ones that
            // do not deserve a permanent icon). The shared ellipsis trigger,
            // so it looks like every other overflow menu in the app.
            DropdownOverflowButton(id: "console.display", matchesIconButtons: true) {
                [
                    DropdownRow.action(
                        "Show Timestamps",
                        isSelected: showTimestamps
                    ) {
                        showTimestamps.toggle()
                    }
                ]
            }
            // Same close affordance the right-hand inspector panels carry
            // (see InspectorHeader), so a docked panel can always be put
            // away from its own row - not only from the View menu.
            Button("Hide", systemImage: "xmark") {
                store.showConsole = false
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(AppColor.textSecondary)
            .accessibilityLabel("Hide Console")
            .help("Hide Console (⌥⌘C)")
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
            .foregroundStyle(AppColor.textSecondary)
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
                            showsTimestamp: showTimestamps,
                            onToggle: { toggle(entry) }
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
            // Scroll state for the seam shadow above: visible once the log
            // has moved under the toolbar, hidden at the top (a 1pt threshold
            // ignores float noise; bounce above the top stays hidden).
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, isPastTop in
                isListScrolledPastTop = isPastTop
            }
            // Same Postman-style scrolled-under shadow the response body
            // carries, so both seams read as one affordance.
            .overlay(alignment: .top) {
                if isListScrolledPastTop {
                    ScrolledUnderEdgeShadow()
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
}

/// One console row: status icon, method, actual URL, and - when expanded -
/// the full request/response details beneath it (Postman-style inline log).
private struct ConsoleEntryRow: View {
    let entry: ConsoleEntry
    let isExpanded: Bool
    /// Whether the summary row leads with the entry's timestamp.
    let showsTimestamp: Bool
    let onToggle: () -> Void

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
                ConsoleEntryDetail(
                    entry: entry,
                    // The summary row already carries the time when the
                    // timestamp option is on; don't say it twice.
                    showsTimestamp: showsTimestamp)
            }
        }
        .background(entry.isError ? AppColor.error.opacity(AppOpacity.errorBackground) : Color.clear)
    }

    private var summaryRow: some View {
        HStack(spacing: AppSpacing.small) {
            if showsTimestamp {
                Text(entry.formattedTime)
                    .font(AppFont.monoCaption)
                    .monospacedDigit()
                    .foregroundStyle(AppColor.tertiaryText)
            }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(AppFont.small.weight(.semibold))
                .foregroundStyle(AppColor.textSecondary)
                .frame(width: 12)
            Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                .font(AppFont.small)
                .foregroundStyle(entry.isError ? AppColor.error : AppColor.success)
            if let method = HTTPMethod(rawValue: entry.method) {
                MethodTag(method: method)
            } else {
                Text(entry.method)
                    .font(AppFont.cellText.weight(.semibold))
                    .foregroundStyle(AppColor.textPrimary)
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
                    .foregroundStyle(AppColor.textSecondary)
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
    /// The summary row already shows the time; then the detail omits its
    /// own copy.
    let showsTimestamp: Bool
    /// Rendered body cap: the formatted view shows a triage excerpt, the
    /// full text goes through Copy.
    private static let bodyPreviewLimit = 16 * 1024
    /// Raw view cap: bodies are already capped on storage, keep the text
    /// view responsive on top of that.
    private static let rawViewLimit = 64 * 1024
    /// In-place copy acknowledgement (the shared one - see
    /// `CopyAcknowledgement`). Row-local: LazyVStack recycling retires the
    /// checkmark with the row, so it can never certify a different entry.
    @State private var copyAck = CopyAcknowledgement()
    @State private var showRaw = false
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack {
                if !showsTimestamp {
                    Text(entry.formattedTime)
                        .font(AppFont.small)
                        .monospacedDigit()
                        .foregroundStyle(AppColor.tertiaryText)
                }
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
                Button(action: copyRaw) {
                    Label(copyAck.didCopy ? "Copied" : "Copy", systemImage: copyAck.didCopy ? "checkmark" : "doc.on.doc")
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
                // HTTP/2+ has no request line: the same information rides
                // the header block as :method/:scheme/:authority/:path.
                headerList(entry.requestPseudoHeaders + entry.requestHeaders)
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
                                .foregroundStyle(AppColor.textSecondary)
                        }
                    }
                    // Same on the response side: :status stands in for the
                    // HTTP/1.x status line.
                    let responseHeaders = entry.responsePseudoHeaders + entry.responseHeaders
                    if !responseHeaders.isEmpty {
                        sectionTitle("Response Headers")
                        headerList(responseHeaders)
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

    /// Copy clears first (like every other copy path: a stale declared type
    /// from a previous owner can otherwise survive a paste elsewhere), then
    /// opens the shared acknowledgement window.
    private func copyRaw() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.rawLog, forType: .string)
        copyAck.acknowledge()
    }

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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppFont.microHeader)
            .foregroundStyle(AppColor.textSecondary)
    }

    private func headerList(_ headers: [HTTPHeader]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            ForEach(headers) { header in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(header.key): ")
                        .font(AppFont.monoSubheadline)
                        .foregroundStyle(AppColor.textPrimary)
                    Text("\"\(header.value)\"")
                        .font(AppFont.monoSubheadline)
                        .foregroundStyle(AppColor.textSecondary)
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
            .foregroundStyle(AppColor.textPrimary)
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
