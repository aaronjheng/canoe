import AppKit
import SwiftUI

/// The WebSocket request editor's "Message" tab (Postman's WebSocket message
/// editor): the composed message on top, the format / action bar along the
/// bottom. The message LIST lives in the pane under the request editor (see
/// `WebSocketWorkspaceView`); the connection itself is driven from the URL bar.
///
/// Layout note: this view deliberately mirrors `BodyEditor`'s raw editor -
/// a plain `VStack` around a `fillsContainer` `VariableHighlightEditor`, with
/// no `GeometryReader`, `Color.clear` anchor, `layoutPriority`, or `fixedSize`
/// anywhere. Those each broke the request editor's chrome rows (name bar, URL
/// bar, section tabs) when tried; the body editor's shape is the one the
/// layout system already handles.
struct WebSocketMessageEditorView: View {
    @Environment(AppStore.self) private var store
    let request: Request

    /// The request's freshest definition (the editor's pending edits
    /// included): the send path resolves variables against it.
    private var liveRequest: Request {
        store.request(withID: request.id) ?? request
    }

    private var connectionState: WebSocketConnectionState {
        store.webSocketState(for: request.id)
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

    /// The saved message the editor is bound to: Save updates that entry
    /// instead of appending a duplicate (Postman's editor binding).
    private var linkedSavedMessage: WebSocketSavedMessage? {
        guard let id = draft.linkedSavedID else { return nil }
        return liveRequest.wsSavedMessages.first { $0.id == id }
    }

    /// The saved-messages drawer's open state.
    @State private var isSavedPanelOpen = false
    /// The message formatter's diagnostic, shown over the editor for a beat.
    @State private var invalidMessageNote: String?

    var body: some View {
        VStack(spacing: 0) {
            editorArea
            Divider()
            bottomBar
        }
    }

    // MARK: - Editor

    private var editorArea: some View {
        VariableHighlightEditor<Bool>(
            text: messageTextBinding,
            variables: resolvedVariables,
            suggestions: requestSuggestions,
            isSingleLine: false,
            fillsContainer: true,
            font: .monoBody,
            placeholder: "Compose a message…",
            syntax: draft.format.syntax,
            formatHandler: beautifyHandler,
            formatActionName: "Beautify Message",
            onFormatError: showInvalidMessageNote
        )
        .background(AppColor.codeBackground)
        // Even inset on all four sides: the multi-line editor draws its text
        // with a zero container inset, so without this the message hugs the
        // pane's edges (and the tab row above it).
        .padding(AppSpacing.medium)
        .overlay(alignment: .bottom) {
            if let invalidMessageNote {
                Text(invalidMessageNote)
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.error)
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.vertical, AppSpacing.xSmall)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AppColor.error.opacity(AppOpacity.errorBackground))
                    )
                    .padding(.bottom, AppSpacing.comfortable)
            }
        }
    }

    /// The editor's text, bound through the store's session draft.
    private var messageTextBinding: Binding<String> {
        Binding(
            get: { store.webSocketDraft(for: request.id).text },
            set: { store.updateWebSocketMessageDraft(request.id, text: $0) }
        )
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: AppSpacing.small) {
            DropdownFieldButton(
                id: "ws.messageFormat.\(request.id)",
                label: draft.format.isBinary ? "Binary · \(draft.format.label)" : draft.format.label,
                width: 148
            ) {
                formatRows
            }
            .help("Message format (decides the wire encoding)")

            if let beautify = beautifyHandler {
                Button {
                    runFormat(beautify)
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(AppFont.small)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Beautify (⌥⇧F)")
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
            .help("Ping the server")

            Button {
                store.saveWebSocketMessage(request.id, text: draft.text, format: draft.format)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .buttonStyle(.plain)
            .clickCursor()
            .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(saveHelp)

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
            .help("Saved messages")
            .popover(isPresented: $isSavedPanelOpen, arrowEdge: .top) {
                savedMessagesPanel
            }

            Spacer(minLength: 0)

            // ⌘↩ is claimed only while a connection is up: disconnected it
            // belongs to the URL bar's Connect, so exactly one control owns
            // the shortcut at any moment.
            if connectionState.isConnected {
                sendButton.keyboardShortcut(.return, modifiers: [.command])
            } else {
                sendButton
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    private var saveHelp: String {
        if let linked = linkedSavedMessage {
            return "Update '\(linked.displayName)'"
        }
        return "Save this message with the request"
    }

    /// Whether Send is live: a connection on the wire and something to send.
    private var isSendEnabled: Bool {
        connectionState.isConnected && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        Button {
            guard isSendEnabled else { return }
            store.sendWebSocketMessage(liveRequest, text: draft.text, format: draft.format)
        } label: {
            Text("Send")
                .frame(minHeight: 22)
        }
        .buttonStyle(SendButtonStyle())
        .disabled(!isSendEnabled)
        .help(isSendEnabled ? "Send Message (⌘↩)" : "Connect first, then send")
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

    /// The format's beautifier (nil for text/HTML/binary, which have no
    /// format step): the same native token rebuilders the body editor uses.
    private var beautifyHandler: ((String) throws -> String?)? {
        switch draft.format {
        case .json: { try BodyFormatter.format($0, kind: .json) }
        case .xml: { try BodyFormatter.format($0, kind: .xml) }
        case .text, .html, .binaryBase64, .binaryHex: nil
        }
    }

    private func runFormat(_ handler: (String) throws -> String?) {
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

    /// Surfaces the beautifier's diagnostic and retires it after a beat (the
    /// same device as the raw body editor's note).
    private func showInvalidMessageNote(_ message: String) {
        invalidMessageNote = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if invalidMessageNote == message { invalidMessageNote = nil }
        }
    }

    // MARK: - Saved messages

    /// Saved messages pane (Postman's Saved messages): Add message creates a
    /// blank entry bound to the editor, picking a row loads it (Save then
    /// updates it), hover deletes.
    private var savedMessagesPanel: some View {
        let saved = liveRequest.wsSavedMessages
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved messages")
                    .font(AppFont.small.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    store.addWebSocketSavedMessage(request.id)
                } label: {
                    Label("Add message", systemImage: "plus")
                        .font(AppFont.small)
                }
                .buttonStyle(.plain)
                .clickCursor()
                .help("Add a blank saved message")
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xSmall)

            Divider()

            if saved.isEmpty {
                Text("Compose a message, then save it here to load and resend later.")
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(AppSpacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(saved) { message in
                    savedMessageRow(message)
                    Divider()
                }
            }
        }
        .frame(width: 300)
    }

    private func savedMessageRow(_ message: WebSocketSavedMessage) -> some View {
        let isLinked = draft.linkedSavedID == message.id
        return HStack(spacing: AppSpacing.small) {
            Button {
                store.selectWebSocketSavedMessage(request.id, id: message.id)
                isSavedPanelOpen = false
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(message.displayName)
                        .font(AppFont.small)
                        .foregroundStyle(isLinked ? AppColor.textPrimary : AppColor.textSecondary)
                        .lineLimit(1)
                    if isLinked {
                        Text("editing")
                            .font(AppFont.countBadge)
                            .foregroundStyle(AppColor.accent)
                    }
                    Spacer(minLength: 0)
                    Text(message.formatKind.isBinary ? "Binary" : message.formatKind.label)
                        .font(AppFont.countBadge)
                        .foregroundStyle(AppColor.tertiaryText)
                }
                .padding(.horizontal, AppSpacing.xSmall)
                .padding(.vertical, AppSpacing.xxSmall)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                        .fill(isLinked ? AppColor.subtleBackground : Color.clear)
                )
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
