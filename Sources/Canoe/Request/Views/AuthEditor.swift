import SwiftUI

/// Postman-style authorization editor: a narrow left column with the auth
/// type picker and helper text, and a wide right column whose form rows read
/// label-left / field-right. Values support `{{variables}}` and are resolved
/// on send; a manually set Authorization header always wins over this helper.
struct AuthEditor: View {
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
        HStack(alignment: .top, spacing: 0) {
            typeColumn
                .frame(width: 250, alignment: .topLeading)
                .padding(AppSpacing.medium)
            Divider()
            formColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(AppSpacing.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    // MARK: - Left column (type picker + helper)

    private var typeColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Auth Type")
                .font(AppFont.sectionTitle)
            Picker("Auth Type", selection: authBinding) {
                ForEach(RequestAuthType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Text("The authorization header will be automatically generated when you send the request.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Fields support {{variables}} from the active environment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Right column (form)

    @ViewBuilder
    private var formColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text(request.requestAuthType.label)
                .font(AppFont.panelTitle)
            switch request.requestAuthType {
            case .none:
                Text("This request will not send an Authorization header.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .basic:
                fieldRow("Username") {
                    VariableHighlightEditor(
                        text: $request.authUsername,
                        variables: resolvedVariables,
                        suggestions: requestSuggestions,
                        placeholder: "Username"
                    )
                    .variableFieldBordered()
                }
                fieldRow("Password") {
                    SecureField("Password", text: $request.authPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(AppFont.monoSubheadline)
                }
            case .bearer:
                fieldRow("Token") {
                    VariableHighlightEditor(
                        text: $request.authToken,
                        variables: resolvedVariables,
                        suggestions: requestSuggestions,
                        placeholder: "Token"
                    )
                    .variableFieldBordered()
                }
            }
            Spacer(minLength: 0)
        }
        // Postman caps the form width instead of stretching fields across a
        // wide window.
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// Postman-style form row: fixed label on the left, field on the right.
    private func fieldRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(label)
                .font(.subheadline)
                .frame(width: 90, alignment: .leading)
            field()
        }
    }

    private var authBinding: Binding<RequestAuthType> {
        Binding(
            get: { request.requestAuthType },
            set: { request.requestAuthType = $0 }
        )
    }
}
