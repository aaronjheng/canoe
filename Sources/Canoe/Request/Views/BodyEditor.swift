import AppKit
import SwiftUI

/// Postman-style body editor: a type selector (none / form-data /
/// x-www-form-urlencoded / raw / binary) over the matching editor.
struct BodyEditor: View {
    @Binding var request: Request
    @Environment(AppStore.self) private var store
    /// The raw body formatter's diagnostic, shown in the editor's bottom
    /// capsule (see `showBodyFormatNote`).
    @State private var invalidBodyNote: String?

    /// Merged variable scope for `{{placeholder}}` highlighting.
    private var resolvedVariables: [String: String] {
        store.variablesForRequest(request)
    }

    /// Completion candidates with scope metadata for `{{` auto-completion.
    private var requestSuggestions: [VariableSuggestion] {
        VariableSuggestion.suggestions(from: store.variableScopesForRequest(request))
    }

    var body: some View {
        VStack(spacing: 0) {
            typeSelector
            content
        }
    }

    // MARK: - Type selector

    private var typeSelector: some View {
        HStack(spacing: AppSpacing.large) {
            ForEach(RequestBodyType.allCases) { type in
                BodyTypeRadio(
                    type: type,
                    isSelected: request.requestBodyType == type,
                    action: { request.requestBodyType = type }
                )
            }
            Spacer(minLength: 0)
            if request.requestBodyType == .raw {
                DropdownFieldButton(
                    id: "body.rawKind",
                    label: rawKindBinding.wrappedValue.label,
                    width: AppSize.methodPickerWidth
                ) {
                    RawBodyKind.allCases.map { kind in
                        DropdownRow.action(
                            kind.label,
                            isSelected: kind == rawKindBinding.wrappedValue
                        ) {
                            rawKindBinding.wrappedValue = kind
                        }
                    }
                }
                .help("Raw body format (sets the Content-Type)")
            }
        }
        // The Raw format picker is taller than the radio labels: without a
        // floor the whole row grows when switching to Raw.
        .frame(minHeight: AppSize.controlHeight)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    /// Changing the raw format also updates the Content-Type, like Postman.
    private var rawKindBinding: Binding<RawBodyKind> {
        Binding(
            get: { request.rawBodyKind },
            set: {
                request.rawBodyKind = $0
                request.bodyContentType = $0.contentType
            }
        )
    }

    /// Syntax colors for the raw editor, following the format picker.
    private var rawSyntax: BodySyntax {
        switch request.rawBodyKind {
        case .json: .json
        case .xml: .xml
        case .text: .plain
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch request.requestBodyType {
        case .none:
            ContentUnavailableView(
                "No Body",
                systemImage: "doc",
                description: Text("This request does not have a body.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .formData:
            KeyValueEditor(
                items: $request.formFields,
                makeNew: { FormField() },
                variables: resolvedVariables,
                suggestions: requestSuggestions,
                keyPlaceholder: "Key",
                valuePlaceholder: "Value",
                // Request tables skip the header wash.
                headerBackground: nil,
                kindKeyPath: \.fieldKind
            )
            .id(request.id)
        case .urlEncoded:
            KeyValueEditor(
                items: $request.urlEncodedFields,
                makeNew: { FormField() },
                variables: resolvedVariables,
                suggestions: requestSuggestions,
                keyPlaceholder: "Key",
                valuePlaceholder: "Value",
                // Request tables skip the header wash.
                headerBackground: nil,
                allowsBulkEdit: true
            )
            .id(request.id)
        case .raw:
            rawEditor
        case .binary:
            BinaryFileEditor(path: $request.binaryFilePath)
        }
    }

    private var rawEditor: some View {
        VStack(spacing: 0) {
            // Explicit specialization: this editor never wires programmatic
            // focus, so FocusValue would otherwise be uninferable.
            VariableHighlightEditor<Bool>(
                text: $request.bodyText,
                variables: resolvedVariables,
                suggestions: requestSuggestions,
                isSingleLine: false,
                fillsContainer: true,
                font: .monoBody,
                syntax: rawSyntax,
                formatHandler: { source in
                    try BodyFormatter.format(source, kind: self.request.rawBodyKind)
                },
                formatActionName: "Format Body",
                onFormatError: { showBodyFormatNote($0) }
            )
            .background(AppColor.codeBackground)
            // Same gutter as the key/value body types (see KeyValueEditor):
            // switching Body type must not shift the content's left edge.
            .padding(.horizontal, AppSpacing.medium)
            .padding(.bottom, AppSpacing.medium)
            .overlay(alignment: .bottom) {
                if let invalidBodyNote {
                    Text(invalidBodyNote)
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
    }

    /// Surfaces the body formatter's diagnostic and retires it after a
    /// beat; a newer note (another ⌥⇧F meanwhile) outlives this timer.
    private func showBodyFormatNote(_ message: String) {
        invalidBodyNote = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if invalidBodyNote == message {
                invalidBodyNote = nil
            }
        }
    }
}

// MARK: - Binary file editor

/// Single file picker for binary bodies.
private struct BinaryFileEditor: View {
    @Binding var path: String

    private var fileSize: String? {
        guard !path.isEmpty,
            let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "doc.fill")
                    .foregroundStyle(AppColor.textSecondary)
                if path.isEmpty {
                    Text("No file selected. The raw file bytes are sent as the body.")
                        .font(AppFont.emptyStateBody)
                        .foregroundStyle(AppColor.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(AppFont.monoSubheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        if let fileSize {
                            Text(fileSize)
                                .font(AppFont.small)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                    }
                }
                Spacer()
                Button("Select File…") {
                    if let url = openFilePanel() { path = url.path }
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
                .help("Choose a file to send as the body")
                if !path.isEmpty {
                    LinkButton("Clear", isDestructive: true) { path = "" }
                        .help("Remove the selected file")
                }
            }
            .padding(AppSpacing.medium)
            Spacer(minLength: 0)
        }
    }
}

/// One body-type radio with the shared row hover language: unselected
/// options wash on hover so the selector reads as interactive, selected
/// keeps the accent circle + primary label.
private struct BodyTypeRadio: View {
    let type: RequestBodyType
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(AppFont.small)
                    .foregroundStyle(isSelected ? AppColor.accent : AppColor.textSecondary)
                Text(type.label)
                    .font(AppFont.small)
                    .foregroundStyle(isSelected ? AppColor.textPrimary : AppColor.textSecondary)
            }
            .padding(.horizontal, AppSpacing.xxSmall)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                    .fill(
                        isSelected
                            ? .clear
                            : (isHovering ? AppColor.subtleBackground : .clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .clickCursor()
        .animation(AppMotion.quick, value: isHovering)
        .accessibilityLabel("Send body as \(type.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Send body as \(type.label)")
    }
}
