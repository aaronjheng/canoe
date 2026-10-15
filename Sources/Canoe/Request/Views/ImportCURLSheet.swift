import SwiftUI

/// Postman-style Import > Raw text sheet: paste a cURL command, see the
/// parsed preview (method, URL, what the flags mapped to), pick the
/// destination collection, and land it in the vault as a request. Same
/// sheet chrome as the Save Request sheet.
struct ImportCURLSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var pastedText = ""
    @State private var parsed: Request?
    @State private var parseError: String?
    /// Destination collection root; nil = the unfiled scratch flow.
    @State private var targetCollectionID: UUID?
    /// Debounces the parse so pasting a multi-line command doesn't parse
    /// per keystroke.
    @State private var parseTask: Task<Void, Never>?

    /// Collections of the active workspace, in sidebar order.
    private var collections: [Collection] {
        store.vault.activeWorkspaceCollections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text("Import cURL")
                .font(AppFont.panelTitle)

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text("cURL command")
                    .font(AppFont.microHeader)
                    .foregroundStyle(AppColor.textSecondary)
                pasteField
            }

            HStack(spacing: AppSpacing.small) {
                resultStrip
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text("Import into")
                    .font(AppFont.microHeader)
                    .foregroundStyle(AppColor.textSecondary)
                destinationPicker
            }

            HStack {
                Text("The request opens in a tab; nothing else is changed.")
                    .font(AppFont.emptyStateBody)
                    .foregroundStyle(AppColor.textSecondary)
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: importIfReady)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(parsed == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.vertical, AppSpacing.large)
        .frame(width: 560)
        .sheetSurface()
        // The sheet is its own root: suppress SwiftUI focus chrome here too
        // (see the focus-ring checklist in AGENTS.md).
        .focusEffectDisabled()
        .onAppear { seedDestination() }
        .onDisappear { parseTask?.cancel() }
    }

    // MARK: - Paste field

    /// The paste surface: a bordered multi-line editor (the shared
    /// variable editor with no scope - nothing highlights, nothing
    /// completes, it is just a well-behaved AppKit text view).
    private var pasteField: some View {
        // Explicit specialization: no programmatic focus wiring.
        VariableHighlightEditor<Bool>(
            text: $pastedText,
            isSingleLine: false,
            fillsContainer: false,
            font: .monoBody,
            placeholder: "curl -X POST https://api.example.com/users -H \"Content-Type: application/json\" -d '{\"name\": \"Ada\"}'"
        )
        .frame(height: 150, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                .strokeBorder(AppColor.border, lineWidth: AppLine.field)
        )
        .background(AppColor.codeBackground)
        .onChange(of: pastedText) { _, newValue in
            scheduleParse(newValue)
        }
    }

    private func scheduleParse(_ text: String) {
        parseTask?.cancel()
        parseTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            parse(text)
        }
    }

    private func parse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parsed = nil
            parseError = nil
            return
        }
        do {
            parsed = try CURLImporter.parse(trimmed)
            parseError = nil
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    // MARK: - Result strip

    /// Parse feedback: the error, or a one-row preview of what the flags
    /// mapped to (Postman shows a request card; one dense row keeps the
    /// sheet compact).
    @ViewBuilder
    private var resultStrip: some View {
        if let parseError {
            Label(parseError, systemImage: "exclamationmark.triangle")
                .font(AppFont.small)
                .foregroundStyle(AppColor.error)
        } else if let parsed {
            HStack(spacing: AppSpacing.small) {
                MethodTag(method: parsed.httpMethod)
                Text(parsed.urlString)
                    .font(AppFont.monoSubheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary(for: parsed))
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.textSecondary)
            }
            .transition(.opacity)
        }
    }

    private func summary(for request: Request) -> String {
        var parts: [String] = []
        let headerCount = request.headers.count
        if headerCount > 0 {
            parts.append("\(headerCount) header\(headerCount == 1 ? "" : "s")")
        }
        let paramCount = request.params.count
        if paramCount > 0 {
            parts.append("\(paramCount) param\(paramCount == 1 ? "" : "s")")
        }
        switch request.requestBodyType {
        case .none:
            break
        case .formData:
            parts.append("\(request.formFields.count) form field\(request.formFields.count == 1 ? "" : "s")")
        case .urlEncoded:
            parts.append("\(request.urlEncodedFields.count) urlencoded field\(request.urlEncodedFields.count == 1 ? "" : "s")")
        case .binary:
            parts.append("binary body")
        case .raw:
            parts.append("\(request.rawBodyKind.rawValue) body")
        }
        if request.requestAuthType == .basic {
            parts.append("basic auth")
        }
        return parts.isEmpty ? "no extras" : parts.joined(separator: " · ")
    }

    // MARK: - Destination

    private var destinationPicker: some View {
        DropdownFieldButton(
            id: "import.curl.destination",
            label: destinationLabel,
            width: 320
        ) {
            var rows: [DropdownRow] = [
                .action("No Collection (scratch)", isSelected: targetCollectionID == nil) {
                    targetCollectionID = nil
                }
            ]
            rows += collections.map { collection in
                DropdownRow.action(collection.name, isSelected: targetCollectionID == collection.id) {
                    targetCollectionID = collection.id
                }
            }
            return rows
        }
    }

    private var destinationLabel: String {
        guard let targetCollectionID,
            let collection = collections.first(where: { $0.id == targetCollectionID })
        else {
            return "No Collection (scratch)"
        }
        return collection.name
    }

    /// Defaults to the selected request's collection, else the first
    /// collection - the same request's-home heuristic the save flow uses.
    private func seedDestination() {
        guard targetCollectionID == nil else { return }
        let selectedHome = store.selectedRequest.flatMap { selected in
            collections.first(where: { $0.requests.contains(where: { $0.id == selected.id }) })
        }
        if let home = selectedHome {
            targetCollectionID = home.id
        } else {
            targetCollectionID = collections.first?.id
        }
    }

    // MARK: - Actions

    private func importIfReady() {
        // If a debounced parse is still pending, the preview may lag the
        // text: cancel it and parse the current text synchronously so the
        // imported request always matches what is on screen.
        parseTask?.cancel()
        if !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parse(pastedText)
        }
        guard let parsed else { return }
        store.importCURLRequest(parsed, into: targetCollectionID)
        close()
    }

    private func close() {
        dismiss()
    }
}
