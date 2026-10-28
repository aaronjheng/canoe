import AppKit
import SwiftUI

/// The bottom pane of a WebSocket request tab (Postman's WebSocket
/// workspace): the message log on top (sent/received frames plus
/// connection system lines) and the message editor below (format picker,
/// Beautify, saved messages, Ping, Send). The connection itself is driven
/// from the editor's URL bar above.
struct WebSocketWorkspaceView: View {
    @Environment(AppStore.self) private var store
    let request: Request

    /// The request's freshest definition (the editor's pending edits
    /// included) - the send path resolves variables against it.
    private var liveRequest: Request {
        store.request(withID: request.id) ?? request
    }

    private var connectionState: WebSocketConnectionState {
        store.webSocketState(for: request.id)
    }

    private var log: [WebSocketLogEntry] {
        store.webSocketLog(for: request.id)
    }

    private var draft: WebSocketMessageDraft {
        store.webSocketDraft(for: request.id)
    }

    /// Merged variable scope for `{{placeholder}}` highlighting.
    private var resolvedVariables: [String: String] {
        store.variablesForRequest(liveRequest)
    }

    /// Completion candidates with scope metadata for `{{` auto-completion.
    private var requestSuggestions: [VariableSuggestion] {
        VariableSuggestion.suggestions(from: store.variableScopesForRequest(liveRequest))
    }

    // MARK: - Local state

    /// Which log row is expanded (nil = none). One at a time, like the
    /// response viewer's single focus.
    @State private var expandedEntryID: UUID?
    /// The saved-messages pane's open state.
    @State private var isSavedPanelOpen = false
    /// The message formatter's diagnostic, shown in the editor's bottom
    /// capsule for a beat (same language as the body editor's).
    @State private var invalidMessageNote: String?
    /// Whether the log's scroll view sits near the bottom: new messages
    /// auto-scroll only when the user has not scrolled up to read.
    @State private var isLogAtBottom = true

    var body: some View {
        VSplitView {
            messagesPane
                .frame(minHeight: AppSize.responseViewerMinHeight)
            messageEditorPane
                .frame(minHeight: 160, idealHeight: 220)
        }
        // A tab switch reuses this view for the next request: drop the
        // per-request local state so nothing leaks across requests.
        .onChange(of: request.id) { _, _ in
            expandedEntryID = nil
            isSavedPanelOpen = false
            invalidMessageNote = nil
            isLogAtBottom = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message log

    private var messagesPane: some View {
        VStack(spacing: 0) {
            messagesToolbar
            Divider()
            if log.isEmpty {
                emptyLog
            } else {
                logList
            }
        }
        .background(AppColor.controlBackground)
    }

    /// Connection status badge (Postman's connection details badge) plus
    /// the pane's Clear action.
    private var messagesToolbar: some View {
        HStack(spacing: AppSpacing.small) {
            connectionBadge
            Spacer(minLength: 0)
            if !log.isEmpty {
                Text("\(log.count) \(log.count == 1 ? "message" : "messages")")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.tertiaryText)
                    .monospacedDigit()
                Button {
                    store.clearWebSocketMessages(request.id)
                    expandedEntryID = nil
                } label: {
                    Image(systemName: "trash")
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Clear Messages")
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    @ViewBuilder
    private var connectionBadge: some View {
        let (color, label): (Color, String) = {
            switch connectionState {
            case .idle:
                (AppColor.tertiaryText, "Disconnected")
            case .connecting:
                (AppColor.warning, "Connecting…")
            case .connected:
                (AppColor.success, "Connected")
            case .disconnecting:
                (AppColor.warning, "Disconnecting…")
            case .disconnected:
                (AppColor.tertiaryText, "Disconnected")
            }
        }()
        HStack(spacing: AppSpacing.xSmall) {
            Circle()
                .fill(color)
                .frame(width: AppSize.contentDot, height: AppSize.contentDot)
            Text(label)
                .font(AppFont.small.weight(.medium))
                .foregroundStyle(AppColor.textPrimary)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(
            Capsule(style: .continuous)
                .fill(AppColor.subtleBackground)
        )
        .help(connectionDetails)
    }

    /// The badge's hover text: where the session stands, with the close
    /// reason (or error) spelled out once the connection ended.
    private var connectionDetails: String {
        switch connectionState {
        case .idle:
            return "Not connected. Press Connect to open the session."
        case .connecting:
            return "Opening \(liveRequest.urlString)…"
        case .connected(_, let subprotocol):
            var details = "Connected to \(liveRequest.urlString)"
            if let subprotocol, !subprotocol.isEmpty {
                details += " · subprotocol: \(subprotocol)"
            }
            return details
        case .disconnecting:
            return "Closing the connection…"
        case .disconnected(let reason):
            return reason ?? "Not connected. Press Connect to open the session."
        }
    }

    private var emptyLog: some View {
        VStack(spacing: AppSpacing.small) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppColor.tertiaryText)
            Text("No Messages Yet")
                .font(AppFont.featureHeadline)
            Text("Connect to the server, then compose and send a message below. Everything sent and received shows up here.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(log) { entry in
                        logRow(entry)
                        Divider().padding(.leading, AppSpacing.medium)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("ws-log-bottom-\(request.id)")
                }
                .padding(.bottom, AppSpacing.small)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let bottom = geometry.contentOffset.y + geometry.containerSize.height
                return bottom >= geometry.contentSize.height - 48
            } action: { _, atBottom in
                isLogAtBottom = atBottom
            }
            .onChange(of: log.count) { _, _ in
                // Follow the traffic only while the reader is already at the
                // bottom; scrolling up to inspect keeps the view put.
                guard isLogAtBottom else { return }
                withAnimation(AppMotion.quick) {
                    proxy.scrollTo("ws-log-bottom-\(request.id)", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func logRow(_ entry: WebSocketLogEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id
        VStack(alignment: .leading, spacing: 0) {
            if entry.isExpandable {
                Button {
                    withAnimation(AppMotion.quick) {
                        expandedEntryID = isExpanded ? nil : entry.id
                    }
                } label: {
                    logRowContent(entry, isExpanded: isExpanded)
                }
                .buttonStyle(.plain)
                .clickCursor()
            } else {
                logRowContent(entry, isExpanded: isExpanded)
            }
            if isExpanded, entry.isExpandable {
                logRowDetail(entry)
            }
        }
    }

    /// One collapsed log row: direction glyph, payload preview (or the
    /// system line), time on the right, byte size for frames.
    private func logRowContent(_ entry: WebSocketLogEntry, isExpanded: Bool) -> some View {
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
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
        .contentShape(Rectangle())
    }

    /// The expanded frame: full payload with the sniffed syntax colors, a
    /// copy action, and (for frames) a save-into-saved-messages action.
    private func logRowDetail(_ entry: WebSocketLogEntry) -> some View {
        let detail = entry.detailText
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Text(entry.detailLabel)
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.tertiaryText)
                Spacer(minLength: 0)
                CopyActionButton(text: entry.copyText)
                Button {
                    store.saveWebSocketLogEntry(request.id, entry: entry)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Save message with the request")
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.bottom, AppSpacing.xSmall)
            ScrollView {
                SyntaxHighlight.highlightedText(detail, syntax: entry.detailSyntax)
                    .font(AppFont.monoSubheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppSpacing.medium)
                    .padding(.bottom, AppSpacing.small)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)
            .background(AppColor.subtleBackground)
        }
        .padding(.leading, AppSpacing.medium + 16 + AppSpacing.small)
        .padding(.trailing, AppSpacing.medium)
        .padding(.bottom, AppSpacing.small)
    }

    // MARK: - Message editor

    private var messageEditorPane: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            editorBody
            if let invalidMessageNote {
                editorNote(invalidMessageNote)
            }
        }
        .background(AppColor.controlBackground)
    }

    private var editorToolbar: some View {
        HStack(spacing: AppSpacing.small) {
            DropdownFieldButton(
                id: "ws.messageFormat.\(request.id)",
                label: draft.format.isBinary ? "Binary · \(draft.format.label)" : draft.format.label,
                width: 148
            ) {
                formatRows
            }
            .help("Message format (sets the wire encoding)")

            if let beautify = beautifyHandler {
                Button {
                    doFormat(beautify)
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Beautify (⌘⇧F)")
            }

            Button {
                store.pingWebSocket(liveRequest)
            } label: {
                Image(systemName: "waveform")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .disabled(!connectionState.isConnected)
            .help("Ping")

            Button {
                isSavedPanelOpen.toggle()
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Image(systemName: "tray.full")
                        .font(AppFont.small)
                    Text("Saved (\(liveRequest.wsSavedMessages.count))")
                        .font(AppFont.small)
                }
                .foregroundStyle(isSavedPanelOpen ? AppColor.textPrimary : AppColor.textSecondary)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .disabled(liveRequest.wsSavedMessages.isEmpty && draft.text.isEmpty)
            .help("Saved messages")
            .popover(isPresented: $isSavedPanelOpen, arrowEdge: .bottom) {
                savedMessagesPanel
            }

            Spacer(minLength: 0)

            // ⌘↩ is registered only while connected: disconnected it maps to
            // the URL bar's Connect, connected it means "send the message" -
            // one enabled owner of the shortcut at any moment.
            if connectionState.isConnected {
                sendButton.keyboardShortcut(.return, modifiers: [.command])
            } else {
                sendButton
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .overlay(alignment: .top) {
            if isSavedPanelOpen {
                savedMessagesPanel
            }
        }
    }

    private var formatRows: [DropdownRow] {
        var rows: [DropdownRow] = []
        for format in WebSocketMessageFormat.allCases where !format.isBinary {
            rows.append(
                .action(format.label, isSelected: format == draft.format) {
                    store.updateWebSocketMessageDraft(request.id, format: format)
                })
        }
        rows.append(.divider())
        for format in WebSocketMessageFormat.allCases where format.isBinary {
            rows.append(
                .action(format.label, isSelected: format == draft.format) {
                    store.updateWebSocketMessageDraft(request.id, format: format)
                })
        }
        return rows
    }

    private var editorBody: some View {
        // Explicit specialization: no programmatic focus wiring.
        VariableHighlightEditor<Bool>(
            text: messageTextBinding,
            variables: resolvedVariables,
            suggestions: requestSuggestions,
            isSingleLine: false,
            fillsContainer: true,
            font: .monoSubheadline,
            placeholder: "Compose a message… ({{variables}} resolve at send time)",
            placeholderLeadingPadding: AppSpacing.compact,
            syntax: draft.format.syntax,
            formatHandler: beautifyHandler,
            formatActionName: "Beautify Message",
            onFormatError: showInvalidMessageNote
        )
        .padding(.horizontal, AppSpacing.compact)
        .padding(.top, AppSpacing.xSmall)
        .padding(.bottom, AppSpacing.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Whether Send is live: a connection on the wire and something
    /// composed to send.
    private var isSendEnabled: Bool {
        connectionState.isConnected && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The message Send button, split out so the toolbar can attach the
    /// ⌘↩ shortcut only while a connection is up (see `editorToolbar`).
    private var sendButton: some View {
        Button {
            sendCurrentMessage()
        } label: {
            Text("Send")
                .frame(minHeight: 22)
        }
        .buttonStyle(SendButtonStyle())
        .disabled(!isSendEnabled)
        .help(isSendEnabled ? "Send Message (⌘↩)" : "Connect first, then send")
    }

    /// The editor's text, bound through the store's session draft (the
    /// request editor never owns this field, so no draft conflicts).
    private var messageTextBinding: Binding<String> {
        Binding(
            get: { store.webSocketDraft(for: request.id).text },
            set: { store.updateWebSocketMessageDraft(request.id, text: $0) }
        )
    }

    /// The format's beautifier (nil for text/binary, which have no
    /// format step): the same native token rebuilders the body editor uses.
    private var beautifyHandler: ((String) throws -> String?)? {
        switch draft.format {
        case .json:
            return { try BodyFormatter.format($0, kind: .json) }
        case .xml:
            return { try BodyFormatter.format($0, kind: .xml) }
        case .text, .html, .binaryBase64, .binaryHex:
            return nil
        }
    }

    private func doFormat(_ handler: (String) throws -> String?) {
        do {
            if let formatted = try handler(draft.text) {
                store.updateWebSocketMessageDraft(request.id, text: formatted)
            }
        } catch let error as TextFormatError {
            showInvalidMessageNote(error.message)
        } catch {
            showInvalidMessageNote("Unexpected token")
        }
    }

    /// Surfaces the beautifier's diagnostic and retires it after a beat
    /// (the same device as the Scripts tab's invalid-script note).
    private func showInvalidMessageNote(_ message: String) {
        invalidMessageNote = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if invalidMessageNote == message {
                invalidMessageNote = nil
            }
        }
    }

    private func editorNote(_ message: String) -> some View {
        Text(message)
            .font(AppFont.small)
            .foregroundStyle(AppColor.error)
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xSmall)
            .background(
                Capsule(style: .continuous)
                    .fill(AppColor.error.opacity(AppOpacity.errorBackground))
            )
            .padding(.bottom, AppSpacing.small)
    }

    private func sendCurrentMessage() {
        guard isSendEnabled else { return }
        store.sendWebSocketMessage(liveRequest, text: draft.text, format: draft.format)
    }

    // MARK: - Saved messages

    /// The saved-messages pane (a popover dropped from the Saved button):
    /// click a row to load it into the editor, hover to delete.
    private var savedMessagesPanel: some View {
        let saved = liveRequest.wsSavedMessages
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved Messages")
                    .font(AppFont.small.weight(.semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Spacer(minLength: 0)
                Button {
                    store.saveWebSocketMessage(
                        request.id, text: draft.text, format: draft.format)
                } label: {
                    Label("Save Current", systemImage: "plus")
                        .font(AppFont.small)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save the composed message with the request")
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xSmall)
            Divider()
            if saved.isEmpty {
                Text("Compose a message, then save it here to load and resend it later.")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(AppSpacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(saved) { message in
                    savedMessageRow(message)
                    Divider().padding(.leading, AppSpacing.small)
                }
            }
        }
        .frame(width: 320)
        .padding(.vertical, AppSpacing.xSmall)
    }

    private func savedMessageRow(_ message: WebSocketSavedMessage) -> some View {
        HStack(spacing: AppSpacing.small) {
            Button {
                store.updateWebSocketMessageDraft(
                    request.id, text: message.text, format: message.formatKind)
                isSavedPanelOpen = false
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(message.displayName)
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)
                    Text(message.formatKind.isBinary ? "Binary" : message.formatKind.label)
                        .font(AppFont.countBadge)
                        .foregroundStyle(AppColor.tertiaryText)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            Button {
                store.deleteWebSocketSavedMessage(request.id, id: message.id)
            } label: {
                Image(systemName: "trash")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .help("Delete saved message")
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xSmall)
    }
}

// MARK: - Entry presentation

extension WebSocketLogEntry {
    var systemImage: String {
        switch (direction, kind) {
        case (.sent, .text), (.sent, .binary):
            "arrow.up.circle"
        case (.received, .text), (.received, .binary):
            "arrow.down.circle"
        case (.sent, .ping):
            "arrow.up.circle.dotted"
        case (.received, .pong):
            "arrow.down.circle.dotted"
        case (.system, .connected):
            "link"
        case (.system, .disconnected):
            "xmark.circle"
        case (.system, .error):
            "exclamationmark.triangle"
        default:
            "info.circle"
        }
    }

    var directionColor: Color {
        switch direction {
        case .sent: AppColor.methodWS
        case .received: AppColor.success
        case .system: AppColor.tertiaryText
        }
    }

    /// The expanded row's detail text: the payload as text (binary frames
    /// shown as Base64, which is what can be copied back into the editor).
    var detailText: String {
        if let text { return text }
        if let data {
            return WebSocketMessageFormat.binaryBase64.editorText(fromWireData: data)
        }
        return preview
    }

    var detailLabel: String {
        switch kind {
        case .text:
            "Text · \(payloadSize ?? 0) bytes"
        case .binary:
            isTextPayload ? "Binary (UTF-8 text) · \(payloadSize ?? 0) bytes" : "Binary · Base64 · \(payloadSize ?? 0) bytes"
        case .ping, .pong, .connected, .disconnected, .error:
            ""
        }
    }

    var copyText: String {
        if let text { return text }
        if let data { return WebSocketMessageFormat.binaryBase64.editorText(fromWireData: data) }
        return preview
    }
}

extension Date {
    /// Log-row timestamp: local time with milliseconds ("14:03:22.481").
    /// One cached formatter - building one per row per render would churn.
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

/// The shared copy acknowledgement language (see Components): the glyph
/// flips to a checkmark for a beat, like every other copy control.
private struct CopyActionButton: View {
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
