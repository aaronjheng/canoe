import Foundation
import Synchronization

/// AppStore WebSocket sessions: opening the handshake per request, sending
/// frames, and the in-memory message log (Postman's WebSocket request
/// experience - Connect, message editor, message list). State and logs are
/// keyed by REQUEST id, so Duplicate Tab views share one session.
@MainActor
extension AppStore {

    // MARK: - Read model

    /// The connection state for a request (idle when nothing is tracked).
    func webSocketState(for requestID: UUID) -> WebSocketConnectionState {
        webSocketStates[requestID] ?? .idle
    }

    /// The message log for a request (empty when none).
    func webSocketLog(for requestID: UUID) -> [WebSocketLogEntry] {
        webSocketMessages[requestID] ?? []
    }

    // MARK: - Connect / disconnect

    /// Opens the WebSocket connection for the request: resolves variables,
    /// merges query params, injects auth + cookie headers, then runs the
    /// HTTP upgrade handshake.
    func connectWebSocket(_ request: Request) {
        AppLogger.info(
            "WS connect requested", category: "WebSocket",
            fields: [
                "request": request.name,
                "state": String(describing: webSocketState(for: request.id)),
            ])
        guard webSocketState(for: request.id).canConnect else {
            AppLogger.info("WS connect ignored (not connectable)", category: "WebSocket")
            return
        }
        // In idle/disconnected states the connection slot is always empty
        // (every teardown path clears it) - drop any stale object defensively.
        if let previous = webSocketConnections[request.id] {
            previous.setEventHandler(nil)
            previous.abort()
            webSocketConnections[request.id] = nil
        }
        webSocketConnectTasks[request.id]?.cancel()

        setWebSocketState(.connecting, for: request.id)
        appendWebSocketLog(
            WebSocketLogEntry(
                direction: .system, kind: .connected,
                text: "Connecting to \(request.urlString)…"),
            for: request.id)

        let requestID = request.id
        webSocketConnectTasks[request.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let urlRequest = try await self.buildWebSocketRequest(request)
                // The connection object exists only once the wire request
                // assembled; failures before that never touch it.
                let connection = WebSocketConnection()
                // The cookie-jar context rides the event handler: the `.open`
                // event carries the handshake response, whose Set-Cookie
                // headers land in the jar when the request opted in (the
                // Settings tab's "Use cookie jar", send and store sides).
                let jarContext = (enabled: request.useCookieJar, url: urlRequest.url)
                connection.setEventHandler { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleWebSocketEvent(event, requestID: requestID, jar: jarContext)
                    }
                }
                connection.setVerifySSLCertificate(request.verifySSLCertificate)
                self.webSocketConnections[requestID] = connection

                // Proxy settings apply at connect time, the same rule as the
                // HTTP send path's `applyProxySettings()`.
                let proxy = SettingsStore.shared.settings.proxy.connectionProxyDictionary
                let openTimeout = request.timeoutSeconds > 0 ? request.timeoutSeconds : 30
                _ = try await connection.connect(
                    urlRequest,
                    proxyDictionary: proxy,
                    openTimeout: openTimeout)
                // The `.open` event settles the state; if the user aborted
                // during the handshake the connection record is already gone
                // and its late events are ignored.
                guard self.webSocketConnections[requestID] === connection else { return }
            } catch is CancellationError {
                self.connectWebSocketDidFail(requestID, reason: nil, isAbort: true)
            } catch let error as URLError where error.code == .cancelled {
                self.connectWebSocketDidFail(requestID, reason: nil, isAbort: true)
            } catch {
                self.connectWebSocketDidFail(requestID, reason: error.localizedDescription, isAbort: false)
            }
        }
    }

    /// Closes the connection for the request (the Disconnect button). A
    /// handshake still in flight is aborted instead of waited on. The
    /// misfire guard only binds user-initiated disconnects - a tab close
    /// right after connecting is still honored.
    func disconnectWebSocket(_ request: Request) {
        disconnectWebSocket(request.id, isUserInitiated: true)
    }

    /// A Disconnect landing within this window after the handshake
    /// completed is the Connect button swapping under a double-click (or a
    /// stray second ⌘↩), not intent - dropped, the same rule as the HTTP
    /// send-after-cancel guard.
    static let disconnectAfterConnectQuiescence: TimeInterval = 0.6

    func disconnectWebSocket(_ requestID: UUID, isUserInitiated: Bool = true) {
        let state = webSocketState(for: requestID)
        guard state.isConnected || state.isConnecting || state == .disconnecting else { return }
        let isMisfire =
            isUserInitiated
            && webSocketConnectAt[requestID].map {
                Date().timeIntervalSince($0) < Self.disconnectAfterConnectQuiescence
            } == true
        if isMisfire { return }
        if state.isConnecting {
            // Abort the handshake immediately: drop the connection record so
            // its late events are ignored, and settle the state right here.
            // The connect task's failure path is idempotent (it only cleans
            // up when the record still exists).
            AppLogger.info("WS disconnect during handshake (abort)", category: "WebSocket", fields: ["user": String(isUserInitiated)])
            if let connection = webSocketConnections[requestID] {
                connection.setEventHandler(nil)
                connection.abort()
            }
            webSocketConnections[requestID] = nil
            webSocketConnectTasks[requestID]?.cancel()
            setWebSocketState(.disconnected(reason: nil), for: requestID)
            appendWebSocketLog(
                WebSocketLogEntry(direction: .system, kind: .disconnected, text: "Disconnected"),
                for: requestID)
            return
        }
        setWebSocketState(.disconnecting, for: requestID)
        AppLogger.info("WS disconnect requested", category: "WebSocket", fields: ["user": String(isUserInitiated)])
        webSocketConnections[requestID]?.close()
        // A server that never answers the close frame would strand the
        // button on "Disconnecting…": force the abort after a grace period.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            if self.webSocketState(for: requestID) == .disconnecting {
                self.webSocketConnections[requestID]?.abort()
            }
        }
    }

    /// The connect task settled with a failure. Cleans up; the message is
    /// recorded only when this path is the one that ends the session (an
    /// aborted handshake was already settled by the disconnect).
    private func connectWebSocketDidFail(_ requestID: UUID, reason: String?, isAbort: Bool) {
        AppLogger.info(
            "WS connect task settled with failure", category: "WebSocket",
            fields: ["reason": reason ?? "-", "abort": String(isAbort)])
        webSocketConnectTasks[requestID] = nil
        guard webSocketConnections[requestID] != nil else {
            // No connection object existed: the failure happened before the
            // wire request assembled (bad URL, refused scheme). The
            // disconnect path may have settled this session already - only
            // a still-connecting session is ours to settle.
            if webSocketState(for: requestID) == .connecting {
                setWebSocketState(.disconnected(reason: reason), for: requestID)
                appendWebSocketLog(
                    WebSocketLogEntry(
                        direction: .system, kind: .error,
                        text: reason ?? "Connection failed"),
                    for: requestID)
            }
            return
        }
        webSocketConnections[requestID]?.setEventHandler(nil)
        webSocketConnections[requestID] = nil
        if isAbort {
            setWebSocketState(.disconnected(reason: nil), for: requestID)
            appendWebSocketLog(
                WebSocketLogEntry(direction: .system, kind: .disconnected, text: "Disconnected"),
                for: requestID)
        } else {
            setWebSocketState(.disconnected(reason: reason), for: requestID)
            appendWebSocketLog(
                WebSocketLogEntry(direction: .system, kind: .error, text: reason ?? "Connection failed"),
                for: requestID)
        }
    }

    // MARK: - Event handling

    /// The single sink of connection events for one session. A connection
    /// removes its record when it tears down, so a stale connection's late
    /// events (after a reconnect) find no record and are dropped. `jar`
    /// carries the connecting request's cookie-jar opt-in and the wire URL
    /// for the handshake's Set-Cookie store-back.
    private func handleWebSocketEvent(
        _ event: WebSocketConnection.Event, requestID: UUID,
        jar: (enabled: Bool, url: URL?)
    ) {
        guard webSocketConnections[requestID] != nil else {
            AppLogger.info("WS event dropped (no live connection record)", category: "WebSocket")
            return
        }
        switch event {
        case .open(let subprotocol, let handshake):
            webSocketConnectAt[requestID] = Date()
            setWebSocketState(.connected(since: Date(), subprotocol: subprotocol), for: requestID)
            let status = handshake.statusCode.map(String.init) ?? "101"
            appendWebSocketLog(
                WebSocketLogEntry(
                    direction: .system, kind: .connected,
                    text: "Connected (\(status))", subprotocol: subprotocol),
                for: requestID)
            // The upgrade response's Set-Cookie headers join the jar (the
            // send side already sent cookies from it), Postman's cookie-jar
            // behavior across the handshake.
            if jar.enabled, let url = jar.url {
                let setCookies = handshake.headers
                    .filter { $0.key.caseInsensitiveCompare("set-cookie") == .orderedSame }
                    .map(\.value)
                if !setCookies.isEmpty {
                    Task {
                        await CookieStore.shared.store(setCookieHeaders: setCookies, for: url)
                    }
                }
            }
        case .text(let text):
            appendWebSocketLog(
                WebSocketLogEntry(direction: .received, kind: .text, text: text),
                for: requestID)
        case .binary(let data):
            appendWebSocketLog(
                WebSocketLogEntry(direction: .received, kind: .binary, data: data),
                for: requestID)
        case .pong:
            appendWebSocketLog(
                WebSocketLogEntry(direction: .received, kind: .pong),
                for: requestID)
        case .closed(let code, let reason, let errorText):
            finishWebSocketClose(requestID: requestID, code: code, reason: reason, errorText: errorText)
        }
    }

    /// One connection reached the end of its life. The state flips to
    /// disconnected and the log records the outcome once.
    private func finishWebSocketClose(requestID: UUID, code: Int?, reason: String?, errorText: String?) {
        AppLogger.info(
            "WS session ended", category: "WebSocket",
            fields: ["code": code.map(String.init) ?? "-", "reason": reason ?? "-", "error": errorText ?? "-"])
        webSocketConnectTasks[requestID] = nil
        webSocketConnectAt[requestID] = nil
        guard webSocketConnections[requestID] != nil else { return }
        webSocketConnections[requestID]?.setEventHandler(nil)
        webSocketConnections[requestID] = nil
        if let errorText {
            setWebSocketState(.disconnected(reason: errorText), for: requestID)
            appendWebSocketLog(
                WebSocketLogEntry(direction: .system, kind: .error, text: errorText),
                for: requestID)
        } else if let code {
            let summary =
                "Disconnected (\(code)" + (reason.map { " \($0)" } ?? "") + ")"
            setWebSocketState(.disconnected(reason: summary), for: requestID)
            appendWebSocketLog(
                WebSocketLogEntry(direction: .system, kind: .disconnected, text: summary, closeCode: code),
                for: requestID)
        } else {
            setWebSocketState(.disconnected(reason: nil), for: requestID)
            appendWebSocketLog(
                WebSocketLogEntry(direction: .system, kind: .disconnected, text: "Disconnected"),
                for: requestID)
        }
    }

    // MARK: - Sending

    /// Composes and sends one message: the editor text resolves through the
    /// variable scopes (Postman resolves WS message placeholders too), the
    /// format turns it into wire bytes, and the resolved payload is what
    /// the log shows (the tab keeps the user's template).
    func sendWebSocketMessage(_ request: Request, text: String, format: WebSocketMessageFormat) {
        guard webSocketState(for: request.id).isConnected, let connection = webSocketConnections[request.id]
        else { return }
        let requestID = request.id
        let variables = variablesForRequest(request)
        let resolved = VariableResolver.resolve(text, variables: variables)
        guard let wireData = format.wireData(fromEditorText: resolved) else {
            appendWebSocketLog(
                WebSocketLogEntry(
                    direction: .system, kind: .error,
                    text: "The message is not valid \(format.isBinary ? format.label : format.label). It was not sent."),
                for: requestID)
            return
        }
        Task { [weak self] in
            do {
                switch format {
                case .binaryBase64, .binaryHex:
                    try await connection.send(data: wireData)
                case .text, .json, .xml, .html:
                    guard let wireText = String(data: wireData, encoding: .utf8) else { return }
                    try await connection.send(text: wireText)
                }
                guard let self else { return }
                self.appendWebSocketLog(
                    WebSocketLogEntry(
                        direction: .sent,
                        kind: format.isBinary ? .binary : .text,
                        text: format.isBinary ? nil : resolved,
                        data: format.isBinary ? wireData : nil),
                    for: requestID)
            } catch {
                // A failed send usually means the transport is going down;
                // the close path reports the terminal state. Record the
                // failure only while the connection still exists.
                guard let self, self.webSocketConnections[requestID] === connection else { return }
                self.appendWebSocketLog(
                    WebSocketLogEntry(
                        direction: .system, kind: .error,
                        text: "Send failed: \(error.localizedDescription)"),
                    for: requestID)
            }
        }
    }

    /// Sends a ping; the pong lands in the log as a received row.
    func pingWebSocket(_ request: Request) {
        guard webSocketState(for: request.id).isConnected, let connection = webSocketConnections[request.id]
        else { return }
        let requestID = request.id
        appendWebSocketLog(
            WebSocketLogEntry(direction: .sent, kind: .ping),
            for: requestID)
        Task { [weak self] in
            do {
                try await connection.ping()
            } catch {
                // A ping failure accompanies the close path; record it only
                // while the connection survives.
                guard let self, self.webSocketConnections[requestID] === connection else { return }
                self.appendWebSocketLog(
                    WebSocketLogEntry(
                        direction: .system, kind: .error,
                        text: "Ping failed: \(error.localizedDescription)"),
                    for: requestID)
            }
        }
    }

    // MARK: - Message draft & saved messages

    /// The composed message draft for a request (the editor's text and
    /// format; empty text default).
    func webSocketDraft(for requestID: UUID) -> WebSocketMessageDraft {
        webSocketDrafts[requestID] ?? WebSocketMessageDraft()
    }

    /// Updates the composed message draft (either field). Nothing is
    /// persisted - this is session state, unlike the request's own fields.
    func updateWebSocketMessageDraft(_ requestID: UUID, text: String? = nil, format: WebSocketMessageFormat? = nil) {
        var draft = webSocketDrafts[requestID] ?? WebSocketMessageDraft()
        var changed = false
        if let text, draft.text != text {
            draft.text = text
            changed = true
        }
        if let format, draft.format != format {
            draft.format = format
            changed = true
        }
        if changed {
            webSocketDrafts[requestID] = draft
        }
    }

    /// The revision of the saved-messages list (OAuth-revision pattern):
    /// the request editor watches it to adopt the pane's changes.
    func webSocketRevision(forOwner requestID: UUID) -> UUID {
        webSocketRevisions[requestID] ?? UUID()
    }

    /// The saved-messages list as the store holds it (what the editor
    /// should carry in its next whole-draft push).
    func liveWebSocketSavedMessages(forOwner requestID: UUID) -> [WebSocketSavedMessage]? {
        guard let request = request(withID: requestID) else { return nil }
        return request.wsSavedMessages
    }

    /// Saves the composed message with the request (Postman's Save in the
    /// message editor): appends a named entry and bumps the revision so
    /// open editors adopt the new list.
    func saveWebSocketMessage(_ requestID: UUID, text: String, format: WebSocketMessageFormat) {
        applyWebSocketSavedMessagesEdit(requestID) { list in
            let entry = WebSocketSavedMessage(
                name: "Message \(list.count + 1)",
                format: format.rawValue,
                text: text)
            list.append(entry)
        }
    }

    /// Saves a received/sent frame from the message log into the saved
    /// messages (Postman's per-message Save action).
    func saveWebSocketLogEntry(_ requestID: UUID, entry: WebSocketLogEntry) {
        guard entry.isExpandable else { return }
        let text: String
        let format: WebSocketMessageFormat
        if let data = entry.data {
            text = WebSocketMessageFormat.binaryBase64.editorText(fromWireData: data)
            format = .binaryBase64
        } else if let entryText = entry.text {
            text = entryText
            format = entry.detailSyntax == .json ? .json : .text
        } else {
            return
        }
        saveWebSocketMessage(requestID, text: text, format: format)
    }

    /// Deletes one saved message (the saved-messages pane's hover delete).
    func deleteWebSocketSavedMessage(_ requestID: UUID, id: UUID) {
        applyWebSocketSavedMessagesEdit(requestID) { list in
            list.removeAll { $0.id == id }
        }
    }

    /// Applies one saved-messages edit onto the request's LATEST state and
    /// bumps the revision. Reading the latest copy first means the pane's
    /// edit never reverts the editor's other pending fields.
    private func applyWebSocketSavedMessagesEdit(
        _ requestID: UUID, modify: (inout [WebSocketSavedMessage]) -> Void
    ) {
        guard var latest = request(withID: requestID) else { return }
        var list = latest.wsSavedMessages
        let before = list
        modify(&list)
        guard list != before else { return }
        latest.wsSavedMessages = list
        updateRequest(latest)
        webSocketRevisions[requestID] = UUID()
    }

    // MARK: - Log management

    /// Clears one request's message log (the pane's Clear button).
    func clearWebSocketMessages(_ requestID: UUID) {
        guard webSocketMessages[requestID]?.isEmpty == false else { return }
        webSocketMessages[requestID] = []
    }

    /// Ends the request's WebSocket session entirely: request deletion (or
    /// any other purge point). Disconnects and drops the in-memory log and
    /// the composed message draft.
    func purgeWebSocketSession(for requestID: UUID) {
        webSocketConnectTasks[requestID]?.cancel()
        webSocketConnectTasks[requestID] = nil
        webSocketConnectAt[requestID] = nil
        if let connection = webSocketConnections[requestID] {
            connection.setEventHandler(nil)
            connection.abort()
        }
        webSocketConnections[requestID] = nil
        webSocketStates[requestID] = nil
        webSocketMessages[requestID] = nil
        webSocketDrafts[requestID] = nil
    }

    /// Disconnects when the request's LAST tab closes (Postman closes the
    /// socket with the tab) while keeping the in-memory log, so reopening
    /// the request still shows what happened.
    func webSocketTabDidClose(requestID: UUID) {
        let state = webSocketState(for: requestID)
        guard state.isConnected || state.isConnecting else { return }
        let siblingOpen = openTabs.contains { $0.requestID == requestID }
        guard !siblingOpen else { return }
        // A tab close is intent, never a misfire: skip the quiescence guard.
        AppLogger.info("WS disconnect via tab close", category: "WebSocket")
        disconnectWebSocket(requestID, isUserInitiated: false)
    }

    // MARK: - Internals

    private func setWebSocketState(_ state: WebSocketConnectionState, for requestID: UUID) {
        webSocketStates[requestID] = state
    }

    private func appendWebSocketLog(_ entry: WebSocketLogEntry, for requestID: UUID) {
        var log = webSocketMessages[requestID] ?? []
        log.append(entry)
        // Same bound-in-memory discipline as the console log: a chatty
        // server cannot grow the log without end. The caps sit far above a
        // debugging session's realistic traffic.
        let entryLimit = 2_000
        let byteLimit = 32 * 1_048_576
        if log.count > entryLimit {
            log.removeFirst(log.count - entryLimit)
        }
        var retained = log.reduce(0) { $0 + ($1.data?.count ?? 0) + ($1.text?.utf8.count ?? 0) }
        while log.count > 1, retained > byteLimit {
            retained -= log[0].data?.count ?? 0
            retained -= log[0].text?.utf8.count ?? 0
            log.removeFirst()
        }
        webSocketMessages[requestID] = log
    }

    // MARK: - Wire request assembly

    /// Builds the HTTP upgrade request from the request definition: the
    /// URL (variables + path variables + query params, scheme mapped to
    /// ws/wss), headers, cookie jar, and the Authorization helper. Mirrors
    /// `HTTPClient.send`'s assembly without the body - the upgrade carries
    /// none. Throws when nothing sensible remains to connect to.
    private func buildWebSocketRequest(_ request: Request) async throws -> URLRequest {
        let variables = variablesForRequest(request)
        let resolvedURLString = VariableResolver.resolve(request.urlString, variables: variables)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedURLString.isEmpty else {
            throw WebSocketClientError.invalidURL("(empty URL)")
        }
        // Path variables (colon syntax), like the HTTP path.
        let urlString = HTTPClient.replacingPathVariables(
            in: resolvedURLString, rows: request.pathVariables, variables: variables)
        guard var components = URLComponents(string: urlString) else {
            throw WebSocketClientError.invalidURL(resolvedURLString)
        }
        // Merge enabled query params, mirroring HTTPClient (empty keys
        // skipped, values resolved).
        let enabledParams = request.params.filter {
            $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !enabledParams.isEmpty {
            var queryItems = components.queryItems ?? []
            for param in enabledParams {
                let name = VariableResolver.resolve(param.key, variables: variables)
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                queryItems.append(
                    URLQueryItem(
                        name: name,
                        value: VariableResolver.resolve(param.value, variables: variables)))
            }
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw WebSocketClientError.invalidURL(resolvedURLString)
        }
        guard let wireURL = URL(string: Self.wireURLString(from: url.absoluteString)) else {
            throw WebSocketClientError.invalidURL(resolvedURLString)
        }

        var urlRequest = URLRequest(url: wireURL)
        urlRequest.httpMethod = "GET"

        // Cookie jar, unless the user set a Cookie header manually or opted
        // out - the same rule as HTTPClient.
        let hasUserCookie = request.headers.contains {
            $0.isEnabled
                && $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cookie"
        }
        if !hasUserCookie, request.useCookieJar {
            if let cookieValue = await CookieStore.shared.cookieHeader(for: wireURL) {
                urlRequest.setValue(cookieValue, forHTTPHeaderField: "Cookie")
            }
        }

        // User-Agent (the same generated header the HTTP path sets, with
        // the same unchecked-rows opt-out).
        let disabledGenerated = Set(request.disabledGeneratedHeaders.map { $0.lowercased() })
        if disabledGenerated.contains("user-agent") {
            urlRequest.setValue("", forHTTPHeaderField: "User-Agent")
        } else {
            urlRequest.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        }

        // User headers, duplicate names joined (RFC 9110 list semantics).
        var userHeaderValues: [String: String] = [:]
        var hasAuthorization = false
        for header in request.headers where header.isEnabled {
            let key = VariableResolver.resolve(header.key, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = VariableResolver.resolve(header.value, variables: variables)
            let normalized = key.lowercased()
            if let existing = userHeaderValues[normalized] {
                let separator = normalized == "cookie" ? "; " : ", "
                let combined = existing + separator + value
                urlRequest.setValue(combined, forHTTPHeaderField: key)
                userHeaderValues[normalized] = combined
            } else {
                urlRequest.setValue(value, forHTTPHeaderField: key)
                userHeaderValues[normalized] = value
            }
            if normalized == "authorization" { hasAuthorization = true }
        }

        // Authorization helper (a manual Authorization header always wins),
        // through the same async resolution as the HTTP send path - an
        // OAuth token refresh applies here too.
        if !hasAuthorization {
            let authorization = await authorizationForSend(of: request, variables: variables)
            switch authorization.type {
            case .none, .inherit, .digest:
                break
            case .basic:
                let username = VariableResolver.resolve(authorization.username, variables: variables)
                let password = VariableResolver.resolve(authorization.password, variables: variables)
                if !username.isEmpty || !password.isEmpty {
                    let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
                    urlRequest.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
                }
            case .bearer:
                let token = VariableResolver.resolve(authorization.token, variables: variables)
                if !token.isEmpty {
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
            case .apiKey:
                let key = VariableResolver.resolve(authorization.apiKey, variables: variables)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let value = VariableResolver.resolve(authorization.apiKeyValue, variables: variables)
                guard !key.isEmpty, !value.isEmpty else { break }
                switch authorization.apiKeyLocation {
                case .header:
                    if userHeaderValues[key.lowercased()] == nil {
                        urlRequest.setValue(value, forHTTPHeaderField: key)
                    }
                case .query:
                    var comps = URLComponents(url: wireURL, resolvingAgainstBaseURL: false)
                    let existingQuery = comps?.queryItems ?? []
                    comps?.queryItems = existingQuery + [URLQueryItem(name: key, value: value)]
                    if let newURL = comps?.url {
                        urlRequest.url = newURL
                    }
                }
            case .oauth2:
                let token = VariableResolver.resolve(authorization.effectiveOAuthAccessToken, variables: variables)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    let prefix = authorization.oauthHeaderPrefix
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    urlRequest.setValue(
                        prefix.isEmpty ? token : "\(prefix) \(token)",
                        forHTTPHeaderField: "Authorization")
                }
            }
        }
        return urlRequest
    }

    /// Maps the user-facing scheme onto the wire scheme: ws/wss pass
    /// through, http/https upgrade to ws/wss (Postman's lenient URL bar),
    /// a schemeless host gets ws.
    static func wireURLString(from urlString: String) -> String {
        let lowered = urlString.lowercased()
        if lowered.hasPrefix("ws://") || lowered.hasPrefix("wss://") {
            return urlString
        }
        if lowered.hasPrefix("https://") {
            return "wss://" + urlString.dropFirst("https://".count)
        }
        if lowered.hasPrefix("http://") {
            return "ws://" + urlString.dropFirst("http://".count)
        }
        return "ws://" + urlString
    }
}
