import AppKit
import SwiftUI

/// The pane under a WebSocket request editor: the message log (Postman's
/// Response pane for WebSocket requests) - every frame sent and received
/// plus the connection's own system lines (connected, closed, error), with
/// search, direction filter, a time-difference readout, and per-message
/// copy / save / inspect. The message EDITOR is the request editor's Message
/// tab (`WebSocketMessageEditorView`).
struct WebSocketWorkspaceView: View {
    @Environment(AppStore.self) private var store
    let request: Request

    /// The request's freshest definition (the editor's pending edits
    /// included).
    private var liveRequest: Request {
        store.request(withID: request.id) ?? request
    }

    /// The direction filter (Postman's All Messages control).
    enum MessageFilter: String, CaseIterable, Identifiable {
        case all = "All Messages"
        case sent = "Sent"
        case received = "Received"

        var id: String { rawValue }
    }

    @State private var search = ""
    @State private var filter: MessageFilter = .all
    /// Rows expanded to their full payload (one at a time).
    @State private var expandedEntryID: UUID?
    /// Rows checked for the time-difference readout.
    @State private var diffSelection: Set<UUID> = []
    /// The row under the pointer: reveals its checkbox and actions.
    @State private var hoveredEntryID: UUID?
    /// Per-row display-format override for the expanded payload.
    @State private var detailFormats: [UUID: WebSocketMessageFormat] = [:]
    @State private var detailWrapsLines = true
    @State private var detailShowsHexdump = false
    /// Whether the list is scrolled to the bottom, so new traffic follows.
    @State private var isAtBottom = true

    private var connectionState: WebSocketConnectionState {
        store.webSocketState(for: request.id)
    }

    private var log: [WebSocketLogEntry] {
        store.webSocketLog(for: request.id)
    }

    /// The rows on screen: direction filter first, then the search terms
    /// against the preview and the payload text.
    private var visibleEntries: [WebSocketLogEntry] {
        var entries = log
        switch filter {
        case .all: break
        case .sent: entries = entries.filter { $0.direction == .sent }
        case .received: entries = entries.filter { $0.direction == .received }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            entry.preview.localizedCaseInsensitiveContains(query)
                || entry.text?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(AppColor.controlBackground)
        .onChange(of: request.id) { _, _ in
            search = ""
            filter = .all
            expandedEntryID = nil
            diffSelection = []
            hoveredEntryID = nil
            detailFormats = [:]
            detailShowsHexdump = false
            detailWrapsLines = true
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: AppSpacing.small) {
            connectionBadge
            diffReadout
            Spacer(minLength: 0)
            if !log.isEmpty {
                Text(countLabel)
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.tertiaryText)
                    .monospacedDigit()
            }
            FilterField(text: $search, placeholder: "Search in messages")
                .frame(width: 180)
            DropdownFieldButton(
                id: "ws.filter.\(request.id)",
                label: filter.rawValue,
                width: 128
            ) {
                MessageFilter.allCases.map { option in
                    DropdownRow.action(option.rawValue, isSelected: option == filter) {
                        filter = option
                    }
                }
            }
            .help("Filter by direction")
            Button {
                store.clearWebSocketMessages(request.id)
                expandedEntryID = nil
                diffSelection = []
            } label: {
                Image(systemName: "trash")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .disabled(log.isEmpty)
            .help("Clear Messages")
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    private var countLabel: String {
        visibleEntries.count == log.count
            ? "\(log.count) \(log.count == 1 ? "message" : "messages")"
            : "\(visibleEntries.count) of \(log.count)"
    }

    /// Connection status badge (Postman's connection-details badge): the
    /// dot plus the state, with the endpoint or close reason on hover.
    private var connectionBadge: some View {
        let (color, label): (Color, String) = {
            switch connectionState {
            case .idle: (AppColor.tertiaryText, "Disconnected")
            case .connecting: (AppColor.warning, "Connecting…")
            case .connected: (AppColor.success, "Connected")
            case .disconnecting: (AppColor.warning, "Disconnecting…")
            case .disconnected: (AppColor.tertiaryText, "Disconnected")
            }
        }()
        return HStack(spacing: AppSpacing.xSmall) {
            Circle()
                .fill(color)
                .frame(width: AppSize.contentDot, height: AppSize.contentDot)
            Text(label)
                .font(AppFont.small.weight(.medium))
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(Capsule(style: .continuous).fill(AppColor.subtleBackground))
        .help(connectionDetails)
    }

    private var connectionDetails: String {
        switch connectionState {
        case .idle:
            return "Not connected. Press Connect to open the session."
        case .connecting:
            return "Opening \(liveRequest.urlString)…"
        case .connected(_, let subprotocol):
            var details = "Connected to \(liveRequest.urlString)"
            if let subprotocol, !subprotocol.isEmpty { details += " · \(subprotocol)" }
            return details
        case .disconnecting:
            return "Closing the connection…"
        case .disconnected(let reason):
            return reason ?? "Not connected. Press Connect to open the session."
        }
    }

    /// Checked rows' time difference (Postman's compare): one row asks for a
    /// second, two or more show the span between the earliest and latest.
    @ViewBuilder
    private var diffReadout: some View {
        let times = log.filter { diffSelection.contains($0.id) }.map(\.date).sorted()
        if !diffSelection.isEmpty {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "timelapse").font(AppFont.small)
                if times.count == 1 {
                    Text("Check another message to see the gap").font(AppFont.small)
                } else if let first = times.first, let last = times.last {
                    Text("Δ \(last.timeIntervalSince(first).formattedDuration)")
                        .font(AppFont.small.weight(.medium))
                        .monospacedDigit()
                }
                Button {
                    diffSelection = []
                } label: {
                    Image(systemName: "xmark").font(AppFont.small)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Deselect")
            }
            .foregroundStyle(AppColor.textPrimary)
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(Capsule(style: .continuous).fill(AppColor.subtleBackground))
        }
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if log.isEmpty {
            emptyState
        } else if visibleEntries.isEmpty {
            ContentUnavailableView(
                "No Matching Messages",
                systemImage: "magnifyingglass",
                description: Text("Try different search terms or clear the direction filter."))
        } else {
            messageList
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.small) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppColor.tertiaryText)
            Text("No Messages Yet")
                .font(AppFont.featureHeadline)
            Text(
                "Connect to the server, then compose a message in the Message tab. "
                    + "Everything sent and received shows up here."
            )
            .font(AppFont.emptyStateBody)
            .foregroundStyle(AppColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleEntries) { entry in
                        row(entry)
                        Divider().padding(.leading, AppSpacing.medium)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.bottom, AppSpacing.small)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let bottom = geometry.contentOffset.y + geometry.containerSize.height
                return bottom >= geometry.contentSize.height - 48
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onChange(of: log.count) { _, _ in
                // Follow the traffic only while the reader is already at the
                // bottom; scrolling up to inspect keeps the view put.
                guard isAtBottom else { return }
                withAnimation(AppMotion.quick) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    private var bottomID: String { "ws-bottom-\(request.id)" }

    private func row(_ entry: WebSocketLogEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id
        let isChecked = diffSelection.contains(entry.id)
        let isHovered = hoveredEntryID == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.xSmall) {
                // Checkbox for the time-difference readout (Postman shows it
                // on hover, or while checked).
                Button {
                    if isChecked { diffSelection.remove(entry.id) } else { diffSelection.insert(entry.id) }
                } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(AppFont.small)
                        .foregroundStyle(isChecked ? AppColor.accent : AppColor.tertiaryText)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .opacity(isChecked || isHovered ? 1 : 0)
                .help("Compare time difference")

                if entry.isExpandable {
                    Button {
                        withAnimation(AppMotion.quick) {
                            if isExpanded {
                                expandedEntryID = nil
                            } else {
                                expandedEntryID = entry.id
                                detailShowsHexdump = false
                                detailWrapsLines = true
                            }
                        }
                    } label: {
                        summary(entry, isExpanded: isExpanded)
                    }
                    .buttonStyle(.plain)
                    .clickCursor()
                } else {
                    summary(entry, isExpanded: isExpanded)
                }

                if isHovered || isExpanded {
                    CopyMessageButton(text: entry.copyText)
                    Button {
                        store.saveWebSocketLogEntry(request.id, entry: entry)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(AppFont.small)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .clickCursor()
                    .help("Save with the request")
                }
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    hoveredEntryID = entry.id
                } else if hoveredEntryID == entry.id {
                    hoveredEntryID = nil
                }
            }

            if isExpanded, entry.isExpandable {
                detail(entry)
            }
        }
    }

    /// The collapsed row: direction glyph, payload preview (or the system
    /// line), byte size, local timestamp. Hovering shows size, MIME type and
    /// time (Postman's info popover).
    private func summary(_ entry: WebSocketLogEntry, isExpanded: Bool) -> some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: entry.systemImage)
                .font(AppFont.small)
                .foregroundStyle(entry.directionColor)
                .frame(width: 16)
            if entry.direction == .system {
                Text(entry.preview)
                    .font(AppFont.small)
                    .foregroundStyle(entry.kind == .error ? AppColor.error : AppColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(entry.preview)
                    .font(AppFont.monoSubheadline)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: AppSpacing.small)
            if entry.isExpandable, let size = entry.payloadSize {
                Text(Int64(size).formattedByteCount)
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.tertiaryText)
                    .monospacedDigit()
            }
            Text(entry.date.formattedWebSocketTime)
                .font(AppFont.small)
                .foregroundStyle(AppColor.tertiaryText)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(AppFont.small.weight(.medium))
                .foregroundStyle(AppColor.tertiaryText)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(entry.isExpandable ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(entry.infoTooltip)
    }

    /// The expanded payload (Postman's expanded message): display format,
    /// Wrap Line, and Show Hexdump / Show Message.
    private func detail(_ entry: WebSocketLogEntry) -> some View {
        let showsHexdump = detailShowsHexdump
        let scrollsHorizontally = showsHexdump || !detailWrapsLines
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Text(entry.detailLabel)
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.tertiaryText)
                Spacer(minLength: 0)
                if entry.kind == .text {
                    DropdownFieldButton(
                        id: "ws.detail.\(entry.id)",
                        label: detailFormats[entry.id]?.label ?? "Auto",
                        width: 96
                    ) {
                        detailFormatRows(for: entry)
                    }
                    .help("Display format")
                }
                Button {
                    detailWrapsLines.toggle()
                } label: {
                    Image(systemName: "arrow.into.view")
                        .font(AppFont.small)
                        .foregroundStyle(detailWrapsLines ? AppColor.accent : AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help(detailWrapsLines ? "Wrap Line" : "Unwrap Line")
                Button {
                    detailShowsHexdump.toggle()
                } label: {
                    Text(showsHexdump ? "Show Message" : "Show Hexdump")
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .clickCursor()
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.bottom, AppSpacing.xSmall)

            ScrollView(showsIndicators: false) {
                Group {
                    if showsHexdump, let data = entry.wireData {
                        Text(WebSocketHexDump.string(for: data))
                            .font(AppFont.monoSubheadline)
                    } else {
                        SyntaxHighlight.highlightedText(detailText(entry), syntax: detailSyntax(entry))
                            .font(AppFont.monoSubheadline)
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: scrollsHorizontally, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.bottom, AppSpacing.small)
            }
            .frame(maxHeight: 260)
            .background(AppColor.subtleBackground)
        }
        .padding(.leading, AppSpacing.medium + 16 + AppSpacing.xSmall + 16 + AppSpacing.xSmall)
        .padding(.trailing, AppSpacing.medium)
        .padding(.bottom, AppSpacing.small)
    }

    private func detailFormatRows(for entry: WebSocketLogEntry) -> [DropdownRow] {
        var rows: [DropdownRow] = [
            .action("Auto", isSelected: detailFormats[entry.id] == nil) {
                detailFormats[entry.id] = nil
            }
        ]
        rows += [WebSocketMessageFormat.text, .json, .xml, .html].map { format in
            .action(format.label, isSelected: detailFormats[entry.id] == format) {
                detailFormats[entry.id] = format
            }
        }
        return rows
    }

    /// The payload as text: re-encoded through the chosen display format, or
    /// the sniffed default (binary shows as Base64).
    private func detailText(_ entry: WebSocketLogEntry) -> String {
        if let format = detailFormats[entry.id], let data = entry.wireData {
            return format.editorText(fromWireData: data)
        }
        return entry.detailText
    }

    private func detailSyntax(_ entry: WebSocketLogEntry) -> BodySyntax {
        detailFormats[entry.id]?.syntax ?? entry.detailSyntax
    }
}

// MARK: - Log entry presentation

extension WebSocketLogEntry {
    /// Direction/kind glyph for the row.
    var systemImage: String {
        switch (direction, kind) {
        case (.sent, .text), (.sent, .binary): "arrow.up.circle"
        case (.received, .text), (.received, .binary): "arrow.down.circle"
        case (.sent, .ping): "arrow.up.circle.dotted"
        case (.received, .pong): "arrow.down.circle.dotted"
        case (.system, .connected): "link"
        case (.system, .disconnected): "xmark.circle"
        case (.system, .error): "exclamationmark.triangle"
        default: "info.circle"
        }
    }

    var directionColor: Color {
        switch direction {
        case .sent: AppColor.methodWS
        case .received: AppColor.success
        case .system: AppColor.tertiaryText
        }
    }

    /// The frame's wire bytes (hexdump source): binary as-is, text as UTF-8.
    var wireData: Data? {
        if let data { return data }
        return text.map { Data($0.utf8) }
    }

    /// The expanded payload as text (binary frames as Base64, which is what
    /// can be copied back into the editor).
    var detailText: String {
        if let text { return text }
        if let data { return WebSocketMessageFormat.binaryBase64.editorText(fromWireData: data) }
        return preview
    }

    var detailLabel: String {
        switch kind {
        case .text:
            "Text · \(payloadSize ?? 0) bytes"
        case .binary:
            isTextPayload
                ? "Binary (UTF-8 text) · \(payloadSize ?? 0) bytes"
                : "Binary · \(payloadSize ?? 0) bytes"
        case .ping, .pong, .connected, .disconnected, .error:
            ""
        }
    }

    var copyText: String {
        if let text { return text }
        if let data { return WebSocketMessageFormat.binaryBase64.editorText(fromWireData: data) }
        return preview
    }

    /// MIME-type hint for the row's hover info.
    var mimeTypeHint: String {
        switch kind {
        case .binary:
            isTextPayload ? "text/plain" : "application/octet-stream"
        case .text:
            switch detailSyntax {
            case .json: "application/json"
            case .xml: "text/xml"
            default: "text/plain"
            }
        case .ping, .pong, .connected, .disconnected, .error:
            ""
        }
    }

    /// Hover text: size, MIME type, and local timestamp.
    var infoTooltip: String {
        var parts: [String] = []
        if kind == .ping { parts.append("Ping") }
        if kind == .pong { parts.append("Pong") }
        if let size = payloadSize { parts.append(Int64(size).formattedByteCount) }
        if !mimeTypeHint.isEmpty { parts.append(mimeTypeHint) }
        parts.append(date.formattedWebSocketTime)
        return parts.joined(separator: " · ")
    }
}

extension Date {
    /// Log-row timestamp: local time with milliseconds ("14:03:22.481").
    private static let webSocketTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var formattedWebSocketTime: String {
        Self.webSocketTimeFormatter.string(from: self)
    }
}

/// Copy action using the app's shared acknowledgement language: the glyph
/// becomes a checkmark for a beat.
private struct CopyMessageButton: View {
    let text: String
    @State private var ack = CopyAcknowledgement()

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            ack.acknowledge()
        } label: {
            Image(systemName: ack.didCopy ? "checkmark" : "doc.on.doc")
                .font(AppFont.small)
                .foregroundStyle(ack.didCopy ? AppColor.success : AppColor.textSecondary)
        }
        .buttonStyle(.plain)
        .clickCursor()
        .help("Copy message")
    }
}
