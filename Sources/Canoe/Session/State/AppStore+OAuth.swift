import Foundation

/// AppStore OAuth 2.0 token supply at send time: a stale token is renewed
/// silently before the request goes out, and the owner's Available Tokens
/// entry is updated through the same draft pipeline every auth edit uses -
/// refreshed in place when the token carries a refresh token, or re-fetched
/// when the grant needs no user interaction (client credentials,
/// resource-owner password). Browser-flow grants keep the token they hold:
/// opening a browser unprompted from a send is a side effect Canoe does not
/// take, so an expired interactive token is sent as-is and the server's 401
/// answers it (a console note explains why).
@MainActor
extension AppStore {

    /// Where the effective Authorization for a request actually lives: its
    /// own fields, or the folder/collection it inherits from (a scratch
    /// request only ever owns its fields).
    private enum OAuthOwner {
        case request(UUID)
        case folder(UUID)
        case collection(UUID)

        /// The id the editors' adoption observers watch.
        var id: UUID {
            switch self {
            case .request(let id), .folder(let id), .collection(let id): id
            }
        }
    }

    /// The Authorization to actually send `request` with. OAuth 2.0 sends
    /// check the token's freshness and renew it first:
    ///
    /// - a selected managed token past its `expires_in` (with a 30-second
    ///   network-skew margin) is refreshed through its refresh token when
    ///   it carries one - the entry updates in place, rotations included;
    /// - with no usable refresh token the token is re-fetched, but only for
    ///   grants the send can complete silently (client credentials,
    ///   resource-owner password) - browser-flow grants never open a
    ///   browser unprompted;
    /// - a selected token without an expiry never counts as stale, and a
    ///   filled manual Access Token field never does either (its value may
    ///   be a `{{variable}}` still to resolve on the wire).
    ///
    /// Renewal failures degrade gracefully: the send proceeds with the
    /// token it had, and one console entry names what failed. Cancellation
    /// (the tab's Cancel button) leaves every store untouched.
    func authorizationForSend(
        of request: Request, variables: [String: String]
    ) async -> Authorization {
        var authorization = authorizationForRequest(request)
        guard authorization.type == .oauth2 else { return authorization }
        guard isOAuthTokenStale(authorization) else { return authorization }

        if let selected = authorization.selectedOAuthToken, !selected.refreshToken.isEmpty {
            do {
                let fresh = try await OAuth2Service.refresh(
                    authorization: authorization, variables: variables,
                    refreshToken: selected.refreshToken)
                guard !Task.isCancelled else { return authorization }
                var renewed = selected
                renewed.accessToken = fresh.accessToken
                renewed.refreshToken = fresh.refreshToken
                renewed.tokenType = fresh.tokenType
                renewed.scope = fresh.scope
                renewed.expiresAt = fresh.expiresAt
                renewed.fetchedAt = fresh.fetchedAt
                let index = authorization.oauthTokens
                    .firstIndex(where: { $0.id == selected.id })
                if let index {
                    authorization.oauthTokens[index] = renewed
                }
                writeOAuth(authorization, to: oauthOwner(of: request))
                return authorization
            } catch {
                guard !Task.isCancelled else { return authorization }
                recordTokenRenewalFailure(
                    "Automatic token refresh failed: \(error.localizedDescription)"
                        + " The send used the existing token.",
                    request: request, variables: variables)
                return authorization
            }
        }

        if !authorization.oauthGrant.usesBrowserFlow {
            do {
                let fresh = try await OAuth2Service.fetchToken(
                    authorization: authorization, variables: variables)
                guard !Task.isCancelled else { return authorization }
                authorization.oauthTokens.append(fresh)
                authorization.oauthSelectedTokenID = fresh.id
                writeOAuth(authorization, to: oauthOwner(of: request))
                return authorization
            } catch {
                guard !Task.isCancelled else { return authorization }
                recordTokenRenewalFailure(
                    "Automatic token fetch failed: \(error.localizedDescription)"
                        + " The send went out without Authorization.",
                    request: request, variables: variables)
                return authorization
            }
        }

        // Interactive grant, nothing to renew with: the hint rides the
        // console next to the (about to be unauthorized) send.
        recordTokenRenewalFailure(
            "The access token is expired and this grant needs a browser"
                + " authorization; use Get New Access Token in the"
                + " Authorization tab.",
            request: request, variables: variables)
        return authorization
    }

    /// Whether the send would carry an already-used-up token: the selected
    /// managed one inside the skew margin past its `expires_in` (or empty),
    /// or - with no managed token picked - nothing in the manual field.
    private func isOAuthTokenStale(_ authorization: Authorization) -> Bool {
        guard authorization.type == .oauth2 else { return false }
        if let selected = authorization.selectedOAuthToken {
            if let expiresAt = selected.expiresAt {
                return expiresAt.timeIntervalSinceNow <= Self.tokenExpirySkew
            }
            return selected.accessToken.isEmpty
        }
        return authorization.oauthAccessToken.isEmpty
    }

    /// Refreshes start inside this margin of `expires_in` too: a token that
    /// expires mid-flight would authenticate a request to nowhere.
    static let tokenExpirySkew: TimeInterval = 30

    /// Where the effective Authorization lives for `request` - its own
    /// fields, or the ancestor it inherits from. nil only for a resolution
    /// that reached the top of the chain (no owner to write to, and no
    /// `.oauth2` type to write either).
    private func oauthOwner(of request: Request) -> OAuthOwner? {
        guard request.requestAuthType == .inherit else { return .request(request.id) }
        guard let source = authorizationSource(for: request) else { return nil }
        switch source.kind {
        case .folder: return .folder(source.ownerID)
        case .collection: return .collection(source.ownerID)
        }
    }

    /// Lands the renewed token back on the owner (Postman's Available
    /// Tokens list lives with the request/folder/collection): the entity's
    /// current pending copy, else its persisted copy, with only the managed
    /// token fields replaced, pushed through the standard update path -
    /// dirty tracking, drafts mirror and all. An actual change bumps
    /// `oauthTokenRevisions`; an idempotent renewal (the token endpoint
    /// returned the same token) does not.
    private func writeOAuth(_ authorization: Authorization, to owner: OAuthOwner?) {
        guard let owner else { return }
        switch owner {
        case .request(let requestID):
            guard
                var merged =
                    pendingRequestSnapshots[requestID]
                    ?? vault.collections.flatMap(\.requests).first(where: { $0.id == requestID })
                    ?? unfiledRequests[requestID]
            else { return }
            let tokensBefore = merged.authOAuthTokens
            let selectionBefore = merged.authOAuthSelectedTokenID
            merged.authOAuthTokens = authorization.oauthTokens
            merged.authOAuthSelectedTokenID = authorization.oauthSelectedTokenID
            merged.updatedAt = Date()
            updateRequest(merged)
            bumpOAuthRevision(
                for: owner, tokens: tokensBefore, selection: selectionBefore,
                changedTo: (merged.authOAuthTokens, merged.authOAuthSelectedTokenID))
        case .folder(let folderID):
            guard
                let folderIndex = folderIndexes(folderID)
            else { return }
            let collectionID = vault.collections[folderIndex.collection].id
            let persisted =
                vault.collections[folderIndex.collection].folders[folderIndex.folder]
                .authorization
            var merged = pendingFolderAuthorizations[folderID] ?? persisted
            merged.oauthTokens = authorization.oauthTokens
            merged.oauthSelectedTokenID = authorization.oauthSelectedTokenID
            updateFolderAuthorization(folderID, in: collectionID, authorization: merged)
            bumpOAuthRevision(
                for: owner, tokens: persisted.oauthTokens,
                selection: persisted.oauthSelectedTokenID,
                changedTo: (merged.oauthTokens, merged.oauthSelectedTokenID))
        case .collection(let collectionID):
            guard let persisted = vault.collections.first(where: { $0.id == collectionID })?.authorization
            else { return }
            var merged = pendingCollectionAuthorizations[collectionID] ?? persisted
            merged.oauthTokens = authorization.oauthTokens
            merged.oauthSelectedTokenID = authorization.oauthSelectedTokenID
            updateCollectionAuthorization(collectionID, authorization: merged)
            bumpOAuthRevision(
                for: owner, tokens: persisted.oauthTokens,
                selection: persisted.oauthSelectedTokenID,
                changedTo: (merged.oauthTokens, merged.oauthSelectedTokenID))
        }
    }

    /// Marks the token revision when the write actually changed the managed
    /// fields - the editor-side adoption compares this same pair, so a
    /// stale push (its next keystroke) cannot revert a rotated refresh
    /// token.
    private func bumpOAuthRevision(
        for owner: OAuthOwner, tokens: [OAuth2Token], selection: UUID?,
        changedTo new: (tokens: [OAuth2Token], selection: UUID?)
    ) {
        guard tokens != new.tokens || selection != new.selection else { return }
        oauthTokenRevisions[owner.id] = UUID()
    }

    /// The revision send-path renewals last bumped for this owner id - what
    /// the request/collection/folder editors' adoption observers watch. A
    /// nil means that owner never carried an automatic renewal.
    func oauthTokenRevision(forOwner ownerID: UUID) -> UUID? {
        oauthTokenRevisions[ownerID]
    }

    /// The owner's CURRENT managed OAuth 2.0 fields (request by id,
    /// folder by id, collection by id) - what an editor's revision observer
    /// adopts into its local draft. Read from the store after the write, so
    /// adoption and store never disagree.
    func liveOAuthTokenFields(forOwner ownerID: UUID) -> (tokens: [OAuth2Token], selectedID: UUID?)? {
        let request =
            vault.collections.flatMap(\.requests).first(where: { $0.id == ownerID })
            ?? unfiledRequests[ownerID]
        if let request {
            return (request.authOAuthTokens, request.authOAuthSelectedTokenID)
        }
        if let at = folderIndexes(ownerID) {
            let folder = vault.collections[at.collection].folders[at.folder]
            return (folder.authorization.oauthTokens, folder.authorization.oauthSelectedTokenID)
        }
        if let collection = vault.collections.first(where: { $0.id == ownerID }) {
            return (collection.authorization.oauthTokens, collection.authorization.oauthSelectedTokenID)
        }
        return nil
    }

    /// One console entry naming why a send went out unrenewed: a failed
    /// refresh/fetch (the send proceeds with the old token) or an expired
    /// interactive-grant token that only the Authorization tab can fix.
    /// Headers and bodies stay out - this entry is about the token, and the
    /// real send logs its own.
    private func recordTokenRenewalFailure(
        _ message: String, request: Request, variables: [String: String]
    ) {
        let secrets = secretVariableValues(for: request, variables: variables)
        recordConsoleEntry(
            ConsoleEntry(
                date: Date(),
                requestName: request.name,
                method: request.httpMethod.rawValue,
                url: ConsoleEntry.redactingSecrets(
                    VariableResolver.resolve(request.urlString, variables: variables),
                    secrets: secrets),
                requestHeaders: [],
                requestBody: nil,
                requestBodyTruncated: false,
                statusCode: nil,
                responseHeaders: [],
                responseBody: nil,
                responseBodyTruncated: false,
                duration: 0,
                error: ConsoleEntry.redactingSecrets(message, secrets: secrets),
                httpVersion: nil))
    }
}
