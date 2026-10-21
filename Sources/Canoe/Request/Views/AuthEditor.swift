import SwiftUI

/// Postman-style authorization editor: a narrow left column with the type
/// picker and helper text, and a wide right column whose form rows read
/// label-left / field-right. Values support `{{variables}}` and are resolved
/// on send; a manually set Authorization header always wins over this helper.
struct AuthEditor: View {
    @Binding var request: Request
    @Environment(AppStore.self) private var store

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

    /// "Edit in Parent": the parent folder's page, or the collection's.
    private func editInParent() {
        guard let source = inheritanceSource else { return }
        switch source.kind {
        case .folder:
            store.openTab(.folder(source.ownerID))
        case .collection:
            store.openTab(.collection(source.ownerID))
        }
    }

    var body: some View {
        AuthorizationForm(
            type: $request.requestAuthType,
            username: $request.authUsername,
            password: $request.authPassword,
            token: $request.authToken,
            apiKey: $request.authApiKey,
            apiKeyValue: $request.authApiValue,
            apiKeyLocation: $request.authApiKeyLocation,
            oauth: oauthBinding,
            variables: resolvedVariables,
            suggestions: requestSuggestions,
            inheritedSource: inheritanceSource,
            onEditInParent: editInParent,
            onTokenListChanged: { store.updateRequest(request) },
            currentRequestID: { request.id },
            landLateToken: { token, refreshedTokenID, ownerRequestID in
                store.landOAuthToken(token, refreshedTokenID: refreshedTokenID, forRequestID: ownerRequestID)
            }
        )
    }

    /// Bridges the request's flat auth fields onto the shared Authorization
    /// value object, so the OAuth 2.0 pane (which binds the struct) reads
    /// and writes the same storage the send path resolves.
    private var oauthBinding: Binding<Authorization> {
        Binding(
            get: { Authorization(from: request) },
            set: { auth in
                request.requestAuthType = auth.type
                request.authUsername = auth.username
                request.authPassword = auth.password
                request.authToken = auth.token
                request.authApiKey = auth.apiKey
                request.authApiValue = auth.apiKeyValue
                request.authApiKeyIn = auth.apiKeyIn
                request.authOAuthGrantType = auth.oauthGrantType
                request.authOAuthAuthURL = auth.oauthAuthURL
                request.authOAuthTokenURL = auth.oauthTokenURL
                request.authOAuthUsername = auth.oauthUsername
                request.authOAuthPassword = auth.oauthPassword
                request.authOAuthClientID = auth.oauthClientID
                request.authOAuthClientSecret = auth.oauthClientSecret
                request.authOAuthScope = auth.oauthScope
                request.authOAuthCallbackURL = auth.oauthCallbackURL
                request.authOAuthState = auth.oauthState
                request.authOAuthClientAuth = auth.oauthClientAuth
                request.authOAuthHeaderPrefix = auth.oauthHeaderPrefix
                request.authOAuthAccessToken = auth.oauthAccessToken
                request.authOAuthTokens = auth.oauthTokens
                request.authOAuthSelectedTokenID = auth.oauthSelectedTokenID
            }
        )
    }
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
    /// API Key helper: key name, value, and injection target. Digest
    /// reuses username/password.
    @Binding var apiKey: String
    @Binding var apiKeyValue: String
    @Binding var apiKeyLocation: ApiKeyLocation
    /// OAuth 2.0 helper: the whole Authorization value object (the grant
    /// has many fields, so the pane binds the struct instead of each
    /// field). Callers bridge the request's flat auth fields onto it.
    @Binding var oauth: Authorization
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
    /// Fired after the token list changes (fetch / refresh / delete) so the
    /// owner can push the request through the draft pipeline right away.
    var onTokenListChanged: (() -> Void)?
    /// The id of the request whose auth this form edits, read LIVE: the
    /// fetch/refresh Tasks outlive request switches, and comparing a
    /// captured id against the current one needs the live read (a value
    /// `let` here would be the Task-creation snapshot and always match).
    var currentRequestID: (() -> UUID)?
    /// Lands a token whose network call outlived a request switch on the
    /// ORIGINAL request's owner through the store, keyed by id (see
    /// `AppStore.landOAuthToken`). Parameters: token, refreshed entry id
    /// (nil = append fresh), the captured owner id.
    var landLateToken: ((OAuth2Token, UUID?, UUID) -> Void)?
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
    @State private var isAPIKeyFocused = false
    @State private var isAPIKeyHovered = false
    @State private var isAPIValueFocused = false
    @State private var isAPIValueHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            typeColumn
                .frame(width: AppSize.authTypeColumnWidth, alignment: .topLeading)
                .padding(AppSpacing.medium)
            Divider()
            formColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(AppSpacing.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColor.controlBackground)
    }

    // MARK: - Left column (type picker + helper)

    private var typeColumn: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Authorization Type")
                .font(AppFont.sectionTitle)
            DropdownFieldButton(id: "auth.type", label: type.label, width: 200) {
                availableTypes.map { pickedType in
                    DropdownRow.action(
                        pickedType.label,
                        isSelected: pickedType == type
                    ) {
                        type = pickedType
                    }
                }
            }
            Text(helperText)
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.textSecondary)
            Text("Fields support {{variables}} from the active environment.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.textSecondary)
            Spacer(minLength: 0)
        }
    }

    /// Per-type helper copy (Postman): the generic Authorization-header
    /// sentence does not hold for the API Key query injection or the
    /// challenge-driven Digest handshake.
    private var helperText: String {
        switch type {
        case .inherit, .none, .basic, .bearer:
            "The Authorization header will be automatically generated when you send the request."
        case .digest:
            "Canoe sends the request once to collect the server's 401 challenge, then resends it with the computed Digest response."
        case .apiKey:
            "The key/value pair is added to the selected header or the query string when you send the request."
        case .oauth2:
            "Fetch an access token with Get New Access Token, then requests send the selected token from"
                + " Available Tokens in the Authorization header with your header prefix."
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
                        .foregroundStyle(AppColor.textSecondary)
                case .basic, .digest:
                    fieldRow("Username") {
                        VariableHighlightEditor(
                            text: $username,
                            variables: variables,
                            suggestions: suggestions,
                            font: .systemSubheadline,
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
                            .font(AppFont.small)
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
                            font: .systemSubheadline,
                            placeholder: "Token",
                            onFocusChange: { isTokenFocused = $0 },
                            onHoverChanged: { isTokenHovered = $0 }
                        )
                        .variableFieldBordered(
                            isFocused: isTokenFocused,
                            isHovered: isTokenHovered
                        )
                    }
                case .apiKey:
                    fieldRow("Key") {
                        VariableHighlightEditor(
                            text: $apiKey,
                            variables: variables,
                            suggestions: suggestions,
                            font: .systemSubheadline,
                            placeholder: "Key",
                            onFocusChange: { isAPIKeyFocused = $0 },
                            onHoverChanged: { isAPIKeyHovered = $0 }
                        )
                        .variableFieldBordered(
                            isFocused: isAPIKeyFocused,
                            isHovered: isAPIKeyHovered
                        )
                    }
                    fieldRow("Value") {
                        VariableHighlightEditor(
                            text: $apiKeyValue,
                            variables: variables,
                            suggestions: suggestions,
                            font: .systemSubheadline,
                            placeholder: "Value",
                            onFocusChange: { isAPIValueFocused = $0 },
                            onHoverChanged: { isAPIValueHovered = $0 }
                        )
                        .variableFieldBordered(
                            isFocused: isAPIValueFocused,
                            isHovered: isAPIValueHovered
                        )
                    }
                    fieldRow("Add to") {
                        DropdownFieldButton(
                            id: "auth.apiKey.location",
                            label: apiKeyLocation.label,
                            width: 160
                        ) {
                            ApiKeyLocation.allCases.map { location in
                                DropdownRow.action(
                                    location.label,
                                    isSelected: location == apiKeyLocation
                                ) {
                                    apiKeyLocation = location
                                }
                            }
                        }
                        .help("Where the key/value pair is added when the request is sent")
                    }
                case .oauth2:
                    oauth2Pane
                }
            }
            Spacer(minLength: 0)
        }
        // Postman caps the form width instead of stretching fields across a
        // wide window.
        .frame(maxWidth: AppSize.formFieldMaxWidth, alignment: .leading)
    }

    // MARK: - OAuth 2.0 pane

    /// Postman's Configure New Token section: the grant type selector, the
    /// endpoint/credential fields that grant needs, client authentication,
    /// header prefix, the Get New Access Token button, and the Available
    /// Tokens list (the selected fetched token is what sends use; with no
    /// selection the manual Access Token field below applies).
    @State private var isFetchingToken = false
    @State private var tokenFetchError: String?

    @ViewBuilder
    private var oauth2Pane: some View {
        let grant = oauth.oauthGrant
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            fieldRow("Grant Type") {
                DropdownFieldButton(
                    id: "auth.oauth2.grant",
                    label: grant.label,
                    width: 240
                ) {
                    OAuth2Grant.allCases.map { pickedGrant in
                        DropdownRow.action(pickedGrant.label, isSelected: pickedGrant == grant) {
                            oauth.oauthGrant = pickedGrant
                        }
                    }
                }
            }
            if grant.usesBrowserFlow {
                fieldRow("Callback URL") {
                    OAuthField(
                        text: oauthCallbackBinding,
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "Optional · loopback only, e.g. http://127.0.0.1:8080/callback"
                    )
                }
                fieldRow("Auth URL") {
                    OAuthField(
                        text: oauthAuthURLBinding,
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "https://provider.com/authorize"
                    )
                }
                fieldRow("State") {
                    OAuthField(
                        text: oauthStateBinding,
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "Empty generates a random state"
                    )
                }
            }
            if grant.usesResourceOwnerCredentials {
                fieldRow("Username") {
                    OAuthField(
                        text: oauthUsernameBinding,
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "Username"
                    )
                }
                fieldRow("Password") {
                    OAuthSecretField(text: oauthPasswordBinding)
                }
            }
            if grant.usesTokenExchange {
                fieldRow("Access Token URL") {
                    OAuthField(
                        text: oauthTokenURLBinding,
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "https://provider.com/token"
                    )
                }
            }
            fieldRow("Client ID") {
                OAuthField(
                    text: oauthClientIDBinding,
                    variables: variables,
                    suggestions: suggestions,
                    placeholder: "Client ID"
                )
            }
            if grant.usesTokenExchange {
                fieldRow("Client Secret") {
                    OAuthSecretField(text: oauthClientSecretBinding)
                }
            }
            fieldRow("Scope") {
                OAuthField(
                    text: oauthScopeBinding,
                    variables: variables,
                    suggestions: suggestions,
                    placeholder: "Space-separated scopes"
                )
            }
            if grant.usesTokenExchange {
                fieldRow("Client Authentication") {
                    DropdownFieldButton(
                        id: "auth.oauth2.clientAuth",
                        label: oauth.oauthSendsBasicAuth ? "Send as Basic Auth header" : "Send client credentials in body",
                        width: 260
                    ) {
                        [
                            DropdownRow.action(
                                "Send client credentials in body",
                                isSelected: !oauth.oauthSendsBasicAuth
                            ) {
                                oauth.oauthSendsBasicAuth = false
                            },
                            DropdownRow.action(
                                "Send as Basic Auth header",
                                isSelected: oauth.oauthSendsBasicAuth
                            ) {
                                oauth.oauthSendsBasicAuth = true
                            },
                        ]
                    }
                    .help("Where the client credentials ride on the token request")
                }
            }
            fieldRow("Header Prefix") {
                OAuthField(
                    text: oauthHeaderPrefixBinding,
                    variables: variables,
                    suggestions: suggestions,
                    placeholder: "Bearer"
                )
            }
            oauthActionsRow
            availableTokensSection
        }
    }

    /// Fetch/refresh controls plus the last error, shared by the two
    /// actions (the spinner rides whichever is running).
    @ViewBuilder
    private var oauthActionsRow: some View {
        HStack(spacing: AppSpacing.medium) {
            Button(action: fetchAccessToken) {
                HStack(spacing: AppSpacing.xSmall) {
                    if isFetchingToken {
                        ProgressView().controlSize(.small)
                    }
                    Text(isFetchingToken ? "Fetching…" : "Get New Access Token")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isFetchingToken)
            .help("Runs the configured grant and adds the token to Available Tokens")
            if oauth.selectedOAuthToken?.refreshToken.isEmpty == false {
                Button(action: refreshAccessToken) {
                    HStack(spacing: AppSpacing.xSmall) {
                        if isFetchingToken {
                            ProgressView().controlSize(.small)
                        }
                        Text("Refresh")
                    }
                }
                .buttonStyle(SecondaryButtonStyle(minHeight: AppSize.controlHeight))
                .disabled(isFetchingToken)
                .help("Exchanges the selected token's refresh token for a new access token")
            }
            if let tokenFetchError {
                Text(tokenFetchError)
                    .font(AppFont.small)
                    .foregroundStyle(AppColor.error)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(tokenFetchError)
            }
        }
    }

    /// Postman's Available Tokens: every token fetched through Get New
    /// Access Token, with the selected one marked as what sends use. No
    /// selection means the manual Access Token field below applies.
    @ViewBuilder
    private var availableTokensSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("Available Tokens")
                .font(AppFont.sectionTitle)
            fieldRow("Token") {
                HStack(spacing: AppSpacing.xSmall) {
                    DropdownFieldButton(
                        id: "auth.oauth2.tokens",
                        label: tokenDropdownLabel,
                        width: 260
                    ) {
                        tokenDropdownRows
                    }
                    if oauth.oauthSelectedTokenID != nil {
                        Button {
                            deleteSelectedToken()
                        } label: {
                            Image(systemName: "trash")
                                .font(AppFont.iconRow)
                                .foregroundStyle(AppColor.textSecondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(IconButtonStyle(inset: 0))
                        .accessibilityLabel("Delete token")
                        .help("Delete token")
                    }
                }
            }
            if let selected = oauth.selectedOAuthToken {
                fieldRow("Access Token") {
                    OAuthField(
                        text: .constant(selected.accessToken),
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "",
                        isEditable: false
                    )
                }
                HStack(spacing: AppSpacing.small) {
                    if selected.isExpired {
                        Badge(text: "Expired")
                    } else if let expiresAt = selected.expiresAt {
                        Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(AppFont.small)
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                fieldRow("Access Token") {
                    OAuthField(
                        text: oauthAccessTokenBinding,
                        variables: variables,
                        suggestions: suggestions,
                        placeholder: "Fetched here, or paste one"
                    )
                }
            }
        }
    }

    /// The Token dropdown's label: the selected token's name, or the
    /// manual-entry fallback.
    private var tokenDropdownLabel: String {
        oauth.selectedOAuthToken?.displayName ?? "Manually Enter"
    }

    /// Rows for the Token dropdown: the manual fallback first, then every
    /// fetched token (expired ones marked inline, like the badge below).
    private var tokenDropdownRows: [DropdownRow] {
        var rows: [DropdownRow] = [
            DropdownRow.action(
                "Manually Enter",
                isSelected: oauth.oauthSelectedTokenID == nil
            ) {
                oauth.oauthSelectedTokenID = nil
                onTokenListChanged?()
            }
        ]
        for token in oauth.oauthTokens {
            let label = token.isExpired ? "\(token.displayName) (expired)" : token.displayName
            rows.append(
                DropdownRow.action(
                    label,
                    isSelected: token.id == oauth.oauthSelectedTokenID
                ) {
                    oauth.oauthSelectedTokenID = token.id
                }
            )
        }
        return rows
    }

    /// Runs the configured grant; the fetched token joins the Available
    /// Tokens list and is selected, so sends use it immediately (Postman
    /// behavior). The list persists with ⌘S like every other auth field.
    private func fetchAccessToken() {
        guard !isFetchingToken else { return }
        isFetchingToken = true
        tokenFetchError = nil
        let fields = oauth
        let variables = self.variables
        // The network call can outlive a tab switch: after the await, the
        // `oauth` binding writes into whatever request the editor shows
        // THEN. Capture the owner id; a late result lands through the
        // store (keyed by id) instead of the wrong request.
        let ownerRequestID = currentRequestID?()
        Task {
            defer { isFetchingToken = false }
            do {
                let token = try await OAuth2Service.fetchToken(authorization: fields, variables: variables)
                // Same request still on screen (or no id wiring - the shared
                // form's folder/collection uses): write through the live
                // binding like before. A switched-away request gets its
                // token through the store, keyed by the captured id.
                if ownerRequestID == nil || currentRequestID?() == ownerRequestID {
                    oauth.oauthTokens.append(token)
                    oauth.oauthSelectedTokenID = token.id
                    onTokenListChanged?()
                } else if let ownerRequestID {
                    landLateToken?(token, nil, ownerRequestID)
                }
            } catch {
                tokenFetchError = error.localizedDescription
            }
        }
    }

    /// Exchanges the selected token's refresh token for a fresh access
    /// token, updating the entry in place (a rotated refresh token lands
    /// too). Only offered when the selected token carries one.
    private func refreshAccessToken() {
        guard !isFetchingToken, let selected = oauth.selectedOAuthToken, !selected.refreshToken.isEmpty
        else { return }
        isFetchingToken = true
        tokenFetchError = nil
        let fields = oauth
        let variables = self.variables
        let refreshToken = selected.refreshToken
        let tokenID = selected.id
        // Same owner guard as fetchAccessToken: a late refresh must not
        // land on the request the editor switched to mid-flight.
        let ownerRequestID = currentRequestID?()
        Task {
            defer { isFetchingToken = false }
            do {
                let fresh = try await OAuth2Service.refresh(
                    authorization: fields, variables: variables, refreshToken: refreshToken)
                if ownerRequestID == nil || currentRequestID?() == ownerRequestID {
                    if let index = oauth.oauthTokens.firstIndex(where: { $0.id == tokenID }) {
                        var updated = oauth.oauthTokens[index]
                        updated.accessToken = fresh.accessToken
                        // RFC 6749 §6: the refresh token is replaced only when
                        // the server issued one - an absent field decodes as
                        // "" (see OAuth2Service), and writing that through
                        // would discard the still-valid token and strand the
                        // entry without a Refresh action.
                        updated.refreshToken = fresh.refreshToken.isEmpty ? refreshToken : fresh.refreshToken
                        updated.tokenType = fresh.tokenType.isEmpty ? updated.tokenType : fresh.tokenType
                        updated.scope = fresh.scope.isEmpty ? updated.scope : fresh.scope
                        updated.expiresAt = fresh.expiresAt
                        updated.fetchedAt = fresh.fetchedAt
                        oauth.oauthTokens[index] = updated
                    }
                    onTokenListChanged?()
                } else if let ownerRequestID {
                    landLateToken?(fresh, tokenID, ownerRequestID)
                }
            } catch {
                tokenFetchError = error.localizedDescription
            }
        }
    }

    /// Deletes the selected managed token; the manual Access Token field
    /// takes over as the send source.
    private func deleteSelectedToken() {
        guard let selectedID = oauth.oauthSelectedTokenID else { return }
        oauth.oauthTokens.removeAll { $0.id == selectedID }
        oauth.oauthSelectedTokenID = nil
        onTokenListChanged?()
    }

    // Per-field bindings over the oauth struct.
    private var oauthAuthURLBinding: Binding<String> {
        Binding(get: { oauth.oauthAuthURL }, set: { oauth.oauthAuthURL = $0 })
    }
    private var oauthTokenURLBinding: Binding<String> {
        Binding(get: { oauth.oauthTokenURL }, set: { oauth.oauthTokenURL = $0 })
    }
    private var oauthUsernameBinding: Binding<String> {
        Binding(get: { oauth.oauthUsername }, set: { oauth.oauthUsername = $0 })
    }
    private var oauthPasswordBinding: Binding<String> {
        Binding(get: { oauth.oauthPassword }, set: { oauth.oauthPassword = $0 })
    }
    private var oauthClientIDBinding: Binding<String> {
        Binding(get: { oauth.oauthClientID }, set: { oauth.oauthClientID = $0 })
    }
    private var oauthClientSecretBinding: Binding<String> {
        Binding(get: { oauth.oauthClientSecret }, set: { oauth.oauthClientSecret = $0 })
    }
    private var oauthScopeBinding: Binding<String> {
        Binding(get: { oauth.oauthScope }, set: { oauth.oauthScope = $0 })
    }
    private var oauthCallbackBinding: Binding<String> {
        Binding(get: { oauth.oauthCallbackURL }, set: { oauth.oauthCallbackURL = $0 })
    }
    private var oauthStateBinding: Binding<String> {
        Binding(get: { oauth.oauthState }, set: { oauth.oauthState = $0 })
    }
    private var oauthHeaderPrefixBinding: Binding<String> {
        Binding(get: { oauth.oauthHeaderPrefix }, set: { oauth.oauthHeaderPrefix = $0 })
    }
    private var oauthAccessTokenBinding: Binding<String> {
        Binding(get: { oauth.oauthAccessToken }, set: { oauth.oauthAccessToken = $0 })
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
                case .basic, .digest:
                    echoRow("Auth type") { echoField { Text(source.authorization.type.label) } }
                    echoRow("Username") {
                        echoField {
                            VariableHighlightEditor(
                                text: .constant(source.authorization.username),
                                variables: variables,
                                font: .systemSubheadline,
                                placeholder: "Username",
                                isEditable: false
                            )
                        }
                    }
                    echoRow("Password") {
                        maskedEchoField {
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
                                font: .systemSubheadline,
                                placeholder: "Token",
                                isEditable: false
                            )
                        }
                    }
                case .apiKey:
                    echoRow("Auth type") { echoField { Text(AuthType.apiKey.label) } }
                    echoRow("Key") {
                        echoField {
                            VariableHighlightEditor(
                                text: .constant(source.authorization.apiKey),
                                variables: variables,
                                font: .systemSubheadline,
                                placeholder: "Key",
                                isEditable: false
                            )
                        }
                    }
                    echoRow("Value") {
                        maskedEchoField {
                            SecureField("Value", text: .constant(source.authorization.apiKeyValue))
                                .textFieldStyle(.plain)
                        }
                    }
                    echoRow("Add to") { echoField { Text(source.authorization.apiKeyLocation.label) } }
                case .oauth2:
                    echoRow("Auth type") { echoField { Text(source.authorization.type.label) } }
                    echoRow("Access token") {
                        maskedEchoField {
                            SecureField(
                                "Access token",
                                text: .constant(source.authorization.oauthAccessToken.isEmpty ? "—" : "••••••••")
                            )
                            .textFieldStyle(.plain)
                        }
                    }
                case .none, .inherit:
                    echoRow("Auth type") { echoField { Text(AuthType.none.label) } }
                    Text("\"\(source.ownerName)\" has no Authorization configured; requests under it send without one.")
                        .font(AppFont.emptyStateBody)
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        } else {
            Text("This level takes its Authorization from its parent.")
                .font(AppFont.emptyStateBody)
                .foregroundStyle(AppColor.textSecondary)
        }
    }

    /// Postman-style form row: fixed label on the left, field on the right.
    private func fieldRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(label)
                .font(AppFont.small)
                .frame(width: AppSize.authLabelColumnWidth, alignment: .leading)
            field()
        }
    }

    /// Echo row: same geometry as `fieldRow`, with the label muted to mark
    /// the value beside it as inherited rather than editable here.
    private func echoRow(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(label)
                .font(AppFont.small)
                .foregroundStyle(AppColor.textSecondary)
                .frame(width: AppSize.authLabelColumnWidth, alignment: .leading)
            field()
        }
    }

    /// Read-only echo of one parent field: dashed border marks the value as
    /// inherited (not editable here). The chrome is inert (a background and
    /// an overlay), but the value itself stays hit-testable on purpose:
    /// `VariableHighlightEditor(isEditable: false)` is built selectable
    /// precisely so an inherited username or token can be selected and
    /// copied - disabling hit testing here made that unreachable and left
    /// the user with no way to read the credential out to somewhere else.
    private func echoField(@ViewBuilder field: () -> some View) -> some View {
        field()
            // Proportional, like every other value field in the app (the
            // Authorization tab used to be the one monospaced form).
            .font(AppFont.small)
            .foregroundStyle(AppColor.textSecondary)
            .padding(.horizontal, AppSpacing.small)
            .frame(maxWidth: .infinity, minHeight: AppSize.controlHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(AppColor.subtleBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(AppColor.borderStrong, style: StrokeStyle(lineWidth: AppLine.field, dash: [4, 3]))
            )
    }

    /// The one echo row that must NOT be interactive: the inherited password.
    /// A `SecureField` bound to a constant offers neither editing nor a
    /// selection to make, so leaving it hit-testable would only let a click
    /// park the caret in a permanently masked field. It stays a pure visual
    /// confirmation that a password is configured.
    private func maskedEchoField(@ViewBuilder field: () -> some View) -> some View {
        echoField { field() }
            .allowsHitTesting(false)
    }
}

/// One OAuth 2.0 form field: the shared variable-aware editor with its own
/// focus/hover mirrors (the panel's many fields would otherwise need a
/// matching pair of `@State` each). Owns the bordered chrome, so callers
/// only pass the binding and placeholders; `isEditable: false` renders the
/// read-only selected-token echo (selectable, so the value can be copied).
private struct OAuthField: View {
    @Binding var text: String
    let variables: [String: String]
    let suggestions: [VariableSuggestion]
    let placeholder: String
    var isEditable: Bool = true
    @State private var isFocused = false
    @State private var isHovered = false

    var body: some View {
        VariableHighlightEditor(
            text: $text,
            variables: variables,
            suggestions: suggestions,
            font: .systemSubheadline,
            placeholder: placeholder,
            isEditable: isEditable,
            onFocusChange: { isFocused = $0 },
            onHoverChanged: { isHovered = $0 }
        )
        .variableFieldBordered(isFocused: isFocused, isHovered: isHovered)
    }
}

/// The client-secret field: masked like the basic-auth password.
private struct OAuthSecretField: View {
    @Binding var text: String
    @State private var isFocused = false
    @State private var isHovered = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        SecureField("Client Secret", text: $text)
            .font(AppFont.small)
            .variableFieldBordered(isFocused: isFocused, isHovered: isHovered)
            .focused($fieldFocused)
            .onHover { isHovered = $0 }
            .onChange(of: fieldFocused) { _, focused in
                isFocused = focused
            }
    }
}
