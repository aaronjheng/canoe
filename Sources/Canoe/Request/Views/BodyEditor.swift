import AppKit
import SwiftUI

/// Postman-style body editor: a type selector (none / form-data /
/// x-www-form-urlencoded / raw / binary) over the matching editor.
struct BodyEditor: View {
    @Binding var request: RequestItem
    @Environment(AppStore.self) private var store

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
            Divider()
            content
        }
    }

    // MARK: - Type selector

    private var typeSelector: some View {
        HStack(spacing: AppSpacing.large) {
            ForEach(RequestBodyType.allCases) { type in
                Button {
                    request.requestBodyType = type
                } label: {
                    HStack(spacing: AppSpacing.xSmall) {
                        Image(systemName: request.requestBodyType == type ? "largecircle.fill.circle" : "circle")
                            .font(.subheadline)
                            .foregroundStyle(request.requestBodyType == type ? AppColor.accent : .secondary)
                        Text(type.label)
                            .font(.subheadline)
                            .foregroundStyle(request.requestBodyType == type ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send body as \(type.label)")
                .accessibilityAddTraits(request.requestBodyType == type ? .isSelected : [])
                .help("Send body as \(type.label)")
            }
            Spacer(minLength: 0)
            if request.requestBodyType == .raw {
                Picker("Format", selection: rawKindBinding) {
                    ForEach(RawBodyKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: AppSize.methodPickerWidth)
                .help("Raw body format (sets the Content-Type)")
            }
        }
        // The Raw format picker is taller than the radio labels: without a
        // floor the whole row grows when switching to Raw.
        .frame(minHeight: AppSize.tabHeight)
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
            VStack {
                Text("This request does not have a body.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.large)
                Spacer(minLength: 0)
            }
        case .formData:
            FormDataEditor(fields: $request.formFields, variables: resolvedVariables, suggestions: requestSuggestions)
        case .urlEncoded:
            KeyValueEditor(
                items: $request.urlEncodedFields,
                makeNew: { FormField() },
                variables: resolvedVariables,
                suggestions: requestSuggestions,
                keyPlaceholder: "key",
                valuePlaceholder: "value"
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
                syntax: rawSyntax
            )
            .background(AppColor.codeBackground)
            .padding(.horizontal, AppSpacing.small)
            .padding(.bottom, AppSpacing.small)
        }
    }
}

// MARK: - Form-data editor

/// Key/value rows where each row is either text or a file (Postman-style).
private struct FormDataEditor: View {
    @Binding var fields: [FormField]
    let variables: [String: String]
    let suggestions: [VariableSuggestion]

    var body: some View {
        List {
            ForEach($fields) { $field in
                HStack(spacing: AppSpacing.small) {
                    Toggle("", isOn: $field.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .frame(width: 32)
                        .help(field.isEnabled ? "Disable row" : "Enable row")
                    VariableHighlightEditor(
                        text: $field.key,
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "key"
                    )
                    .variableFieldBordered()
                    Picker("Kind", selection: $field.fieldKind) {
                        ForEach(FormFieldKind.allCases, id: \.self) { kind in
                            Text(kind == .text ? "Text" : "File").tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 76)
                    if field.fieldKind == .file {
                        fileCell(field)
                    } else {
                        VariableHighlightEditor(
                            text: $field.value,
                            variables: variables,
                            suggestions: suggestions,
                            placeholder: "value"
                        )
                        .variableFieldBordered()
                    }
                    Button(role: .destructive) {
                        fields.removeAll { $0.id == field.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconButtonStyle())
                    .foregroundStyle(.secondary)
                    .help("Remove row")
                }
            }
            Button {
                fields.append(FormField())
            } label: {
                Label("Add Row", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(IconButtonStyle())
        }
    }

    private func fileCell(_ field: FormField) -> some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text(field.value.isEmpty ? "No file selected" : URL(fileURLWithPath: field.value).lastPathComponent)
                .font(AppFont.monoSubheadline)
                .foregroundStyle(field.value.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .helpIf(!field.value.isEmpty, field.value)
            LinkButton("Browse…") {
                if let url = openFilePanel() {
                    if let index = fields.firstIndex(where: { $0.id == field.id }) {
                        fields[index].value = url.path
                    }
                }
            }
            .help("Choose a file to upload")
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xSmall)
        .background(AppColor.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
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
                    .foregroundStyle(.secondary)
                if path.isEmpty {
                    Text("No file selected. The raw file bytes are sent as the body.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(AppFont.monoSubheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        if let fileSize {
                            Text(fileSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button("Select File…") {
                    if let url = openFilePanel() { path = url.path }
                }
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

// MARK: - Shared file panel

@MainActor
private func openFilePanel() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}
