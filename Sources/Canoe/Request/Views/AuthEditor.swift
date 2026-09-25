import SwiftUI

/// Postman-style authorization editor: a narrow left column with the type
/// picker and helper text, and a wide right column whose form rows read
/// label-left / field-right. Values support `{{variables}}` and are resolved
/// on send; a manually set Authorization header always wins over this helper.
struct AuthEditor: View {
    @Binding var request: Request
    @Environment(AppStore.self) private var store
    @State private var folderEditTarget: FolderEditTarget?

    /// Merged variable scope for `{{placeholder}}` highlighting.
    private var resolvedVariables: [String: String] {
        store.variablesForRequest(request)
    }

    /// Completion candidates with scope metadata for `{{` auto-completion.
    private var requestSuggestions: [VariableSuggestion] {
        VariableSuggestion.suggestions(from: store.variableScopesForRequest(request))
    }

    /// The nearest ancestor (Request → Folder → Collection) whose settings
    /// the request inherits, when its type is inherit.
    private var inheritanceSource: AuthorizationSource? {
        store.authorizationSource(for: request)
    }

    /// "Edit in Parent": the folder's sheet, or the collection editor tab.
    private func editInParent() {
        guard let source = inheritanceSource else { return }
        if source.kind == .folder {
            guard let collection = store.collectionForRequest(request),
                let folder = collection.folders.first(where: { $0.id == source.ownerID })
            else { return }
            folderEditTarget = FolderEditTarget(collection: collection, folder: folder)
        } else {
            store.openTab(.collection(source.ownerID))
        }
    }

    var body: some View {
        AuthorizationForm(
            type: $request.requestAuthType,
            username: $request.authUsername,
            password: $request.authPassword,
            token: $request.authToken,
            variables: resolvedVariables,
            suggestions: requestSuggestions,
            inheritedSource: inheritanceSource,
            onEditInParent: editInParent
        )
        .sheet(item: $folderEditTarget) { target in
            FolderEditSheet(collection: target.collection, folder: target.folder)
        }
    }
}

/// Sheet-navigation wrapper: presents a folder's editor from a request.
struct FolderEditTarget: Identifiable {
    let collection: Collection
    let folder: Folder

    var id: UUID { folder.id }
}

/// The shared authorization editing surface, used by the request editor (own
/// settings), the folder editor, and the collection editor. One column picks
/// the helper type; the other renders its fields - or, for the inherit type,
/// a read-only echo of the settings the chain resolves to (Postman-style).
struct AuthorizationForm: View {
    @Binding var type: AuthType
    @Binding var username: String
    @Binding var password: String
    @Binding var token: String
    /// Merged variable scope for `{{placeholder}}` highlighting.
    let variables: [String: String]
    /// Completion candidates with scope metadata for `{{` auto-completion.
    let suggestions: [VariableSuggestion]
    /// When the type is inherit: the nearest ancestor's settings, echoed
    /// read-only with an "Inherited" badge (nil shows a generic note).
    var inheritedSource: AuthorizationSource?
    /// Action for the echo's "Edit in Parent" shortcut.
    var onEditInParent: (() -> Void)?
    /// Types offered in the picker. The collection is the top of the
    /// inheritance chain, so (Postman-style) it is not offered inherit there.
    var availableTypes: [AuthType] = AuthType.allCases
    /// Focus/hover mirrors for the bordered fields below: the AppKit-backed
    /// editors report via `onFocusChange`/`onHoverChanged`, the SecureField
    /// via `@FocusState`/`.onHover`. Without these the shared border language
    /// never lights up here.
    @State private var isUsernameFocused = false
    @State private var isUsernameHovered = false
    @FocusState private var isPasswordFocused: Bool
    @State private var isPasswordHovered = false
    @State private var isTokenFocused = false
    @State private var isTokenHovered = false

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
            Text("Authorization Type")
                .font(AppFont.sectionTitle)
            Picker("Authorization Type", selection: $type) {
                ForEach(availableTypes) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            Text("The Authorization header will be automatically generated when you send the request.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(.secondary)
            Text("Fields support {{variables}} from the active environment.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Right column (form)

    @ViewBuilder
    private var formColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            if type == .inherit {
                inheritedEcho
            } else {
                Text(type.label)
                    .font(AppFont.panelTitle)
                switch type {
                case .inherit:
                    EmptyView()
                case .none:
                    Text("No Authorization header will be sent.")
                        .font(AppFont.emptyStateBody)
                        .foregroundStyle(.secondary)
                case .basic:
                    fieldRow("Username") {
                        VariableHighlightEditor(
                            text: $username,
                            variables: variables,
                            suggestions: suggestions,
                            placeholder: "Username",
                            onFocusChange: { isUsernameFocused = $0 },
                            onHoverChanged: { isUsernameHovered = $0 }
                        )
                        .variableFieldBordered(
                            isFocused: isUsernameFocused,
                            isHovered: isUsernameHovered
                        )
                    }
                    fieldRow("Password") {
                        SecureField("Password", text: $password)
                            .font(AppFont.monoSubheadline)
                            .variableFieldBordered(
                                isFocused: isPasswordFocused,
                                isHovered: isPasswordHovered
                            )
                            .focused($isPasswordFocused)
                            .onHover { isPasswordHovered = $0 }
                    }
                case .bearer:
                    fieldRow("Token") {
                        VariableHighlightEditor(
                            text: $token,
                            variables: variables,
                            suggestions: suggestions,
                            placeholder: "Token",
                            onFocusChange: { isTokenFocused = $0 },
                            onHoverChanged: { isTokenHovered = $0 }
                        )
                        .variableFieldBordered(
                            isFocused: isTokenFocused,
                            isHovered: isTokenHovered
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        // Postman caps the form width instead of stretching fields across a
        // wide window.
        .frame(maxWidth: 520, alignment: .leading)
    }

    // MARK: - Inherited echo (Postman-style read-only parent view)

    /// The effective type's title with an "Inherited" badge, an "Edit in
    /// Parent" shortcut, and the parent's fields rendered disabled with
    /// dashed borders - mirroring the form the parent configures.
    @ViewBuilder
    private var inheritedEcho: some View {
        if let source = inheritedSource {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                HStack(spacing: AppSpacing.small) {
                    Text(source.authorization.type.label)
                        .font(AppFont.panelTitle)
                    Badge(text: "Inherited")
                    Spacer(minLength: 0)
                    if onEditInParent != nil {
                        Button(
                            action: { onEditInParent?() },
                            label: {
                                Label("Edit in Parent", systemImage: "pencil")
                                    .labelStyle(.titleAndIcon)
                                    .font(AppFont.small)
                            }
                        )
                        .buttonStyle(IconButtonStyle(iconSquare: false))
                        .foregroundStyle(AppColor.accent)
                        .help(source.kind == .folder ? "Open this folder's settings" : "Open the collection editor")
                    }
                }
                switch source.authorization.type {
                case .basic:
                    echoRow("Auth type") { echoField { Text(AuthType.basic.label) } }
                    echoRow("Username") {
                        echoField {
                            VariableHighlightEditor(
                                text: .constant(source.authorization.username),
                                variables: variables,
                                placeholder: "Username",
                                isEditable: false
                            )
                        }
                    }
                    echoRow("Password") {
                        echoField {
                            SecureField("Password", text: .constant(source.authorization.password))
                                .textFieldStyle(.plain)
                        }
                    }
                case .bearer:
                    echoRow("Auth type") { echoField { Text(AuthType.bearer.label) } }
                    echoRow("Token") {
                        echoField {
                            VariableHighlightEditor(
                                text: .constant(source.authorization.token),
                                variables: variables,
                                placeholder: "Token",
                                isEditable: false
                            )
                        }
                    }
                case .none, .inherit:
                    echoRow("Auth type") { echoField { Text(AuthType.none.label) } }
                    Text("\"\(source.ownerName)\" has no Authorization configured; requests under it send without one.")
                        .font(AppFont.emptyStateBody)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("This level takes its Authorization from its parent.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(.secondary)
        }
    }

    /// Postman-style form row: fixed label on the left, field on the right.
    private func fieldRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(label)
                .font(AppFont.small)
                .frame(width: 90, alignment: .leading)
            field()
        }
    }

    /// Read-only echo of one parent field: dashed border marks the value as
    /// inherited (not editable here).
    private func echoRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(label)
                .font(AppFont.small)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            field()
        }
    }

    private func echoField(@ViewBuilder field: () -> some View) -> some View {
        field()
            .font(AppFont.monoSubheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.small)
            .frame(maxWidth: .infinity, minHeight: AppSize.controlHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(AppColor.subtleBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(AppColor.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .allowsHitTesting(false)
    }
}
