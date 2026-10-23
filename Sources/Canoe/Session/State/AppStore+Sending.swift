import AppKit
import Foundation
import Synchronization

/// AppStore request sending: per-request responses and history (persisted),
/// global history, and the console (network log).
@MainActor
extension AppStore {

    /// The response displayed for the request's tab: the latest one, or an
    /// older entry picked from the response panel's History menu. The single
    /// source of truth is `responseHistoryByRequest` - "latest" IS the first
    /// entry (index nil), so there is no second copy of the current response
    /// to keep in sync. A freshly opened tab (`resetResponseTabs`) starts
    /// empty until the request is sent again.
    var displayedResponse: ResponseModel? {
        guard let tab = selectedTab, case .request = tab,
            !resetResponseTabs.contains(tab),
            let requestID = tab.requestID
        else { return nil }
        let index = viewingHistoryIndexByRequest[requestID]
        let history = responseHistoryByRequest[requestID] ?? []
        if let index, history.indices.contains(index) {
            return history[index]
        }
        return history.first
    }

    var responseHistoryForSelectedTab: [ResponseModel] {
        guard let requestID = selectedTab?.requestID else { return [] }
        return responseHistoryByRequest[requestID] ?? []
    }

    var isViewingLatestResponse: Bool {
        guard let requestID = selectedTab?.requestID else { return true }
        return viewingHistoryIndexByRequest[requestID] == nil
    }

    /// Shows the latest response (nil index) or a historical entry.
    func selectResponseHistoryEntry(at index: Int?) {
        guard let requestID = selectedTab?.requestID else { return }
        viewingHistoryIndexByRequest[requestID] = index
    }

    var sendError: String? {
        get { selectedTab.flatMap { errorsByTab[$0] } }
        set { if let tab = selectedTab { errorsByTab[tab] = newValue } }
    }

    var isSending: Bool { selectedTab.map { sendingTabs.contains($0) } ?? false }

    /// Shows/hides the docked console panel.
    func toggleConsole() {
        showConsole.toggle()
    }

    // MARK: - Send

    /// Sends a request, attributing the in-flight state and the result to the
    /// given tab so other tabs keep their own spinners and responses.
    /// Send, then save the response body straight to a file (Postman's
    /// "Send and Download"): the response still lands in the tab's viewer,
    /// and a save panel picks the destination once the body is in.
    func sendAndDownload(_ request: Request) {
        send(request, downloadResponse: true)
    }

    func send(_ request: Request, downloadResponse: Bool = false) {
        let tab = selectedTab ?? .request(request.id)
        // Drop misfires: a Send within the quiescence window after a cancel
        // is the morphing button swapping under the click, not intent.
        if let at = lastCancelAt[tab], Date().timeIntervalSince(at) < Self.sendAfterCancelQuiescence {
            return
        }
        let token = UUID()
        sendTokens[tab] = token
        sendTasks[tab]?.cancel()
        // Mark sending synchronously with the click: the Task below may not
        // start for a while (busy main thread), and nothing after this point
        // may re-mark it - so Cancel can never be followed by a stale insert
        // flipping the button back.
        sendingTabs.insert(tab)
        errorsByTab[tab] = nil
        if let requestID = tab.requestID { viewingHistoryIndexByRequest[requestID] = nil }
        sendTasks[tab] = Task {
            // A task cancelled before it first ran still executes its body;
            // without this guard it would write state for a send that no
            // longer owns the tab.
            guard !Task.isCancelled else { return }
            // Only the latest send for this tab may write state - a cancelled
            // predecessor must not touch its successor's spinner or response.
            defer {
                if sendTokens[tab] == token {
                    sendingTabs.remove(tab)
                }
            }

            // Full scope chain (workspace > collection > environment),
            // matching what the "Variables in Request" inspector displays.
            let baseVariables = variablesForRequest(request)
            var scriptVariables = scriptVariables(for: request)
            // The cookie jar for the request's URL, snapshotted before the
            // scripts run (pm.cookies reads it; the response's Set-Cookie
            // updates land in the jar after the send, so test scripts see
            // the fresh cookies through the same snapshot).
            if let url = URL(
                string: VariableResolver.resolve(request.urlString, variables: baseVariables)
            ).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.url }) {
                scriptVariables.cookies = await CookieStore.shared.cookies(for: url)
            }
            // Secret variable values, redacted from everything the console
            // records below (the resolved URL, both bodies, the error text).
            let secretValues = secretVariableValues(for: request, variables: baseVariables)
            // Pre-request scripts (Postman's inheritance chain): the
            // collection's Pre-request runs first, then the request's own.
            // All phases of one send share the carried variable state, so a
            // token the collection script mints reaches the request script
            // and then authorization. A script throwing - or an engine
            // failure - ends the send with an error banner and nothing
            // recorded: no request went out.
            var variables = baseVariables
            var preRequestLogs: [ScriptLog] = []
            var preResults: [ScriptTestResult] = []
            var preHeaderChanges: [ScriptHeaderChange] = []
            var prePhaseRan = false
            do {
                // The collection's Pre-request script (inherited chain top).
                let collection = collectionForRequest(request)
                if let collection, !collection.preRequestScript.isEmpty {
                    let outcome = try await runScript(
                        .preRequest, script: collection.preRequestScript, of: request,
                        variables: scriptVariables, resetsCarriedState: true)
                    preRequestLogs += outcome.logs
                    preResults += outcome.results
                    if let error = outcome.error {
                        errorsByTab[tab] =
                            "Collection pre-request script error: \(error)"
                        return
                    }
                    if let final = outcome.finalVariables {
                        variables = final
                        scriptVariables.base = final
                    }
                    preHeaderChanges += outcome.headerChanges
                    prePhaseRan = true
                }
                // Folder Pre-request scripts, outermost folder first.
                for folder in (collection?.folderChain(forRequest: request.id) ?? []).reversed()
                where !folder.preRequestScript.isEmpty {
                    let outcome = try await runScript(
                        .preRequest, script: folder.preRequestScript, of: request,
                        variables: scriptVariables, resetsCarriedState: false)
                    preRequestLogs += outcome.logs
                    preResults += outcome.results
                    if let error = outcome.error {
                        errorsByTab[tab] =
                            "Folder pre-request script error (\(folder.name)): \(error)"
                        return
                    }
                    if let final = outcome.finalVariables {
                        variables = final
                        scriptVariables.base = final
                    }
                    preHeaderChanges += outcome.headerChanges
                    prePhaseRan = true
                }
                // The request's own Pre-request script.
                let outcome = try await runScript(
                    .preRequest, script: request.preRequestScript, of: request,
                    variables: scriptVariables, resetsCarriedState: !prePhaseRan)
                preRequestLogs += outcome.logs
                preResults += outcome.results
                if let error = outcome.error {
                    errorsByTab[tab] = "Pre-request script error: \(error)"
                    return
                }
                // The engine already applied script writes and tier
                // fallback - adopt its variable map for the outgoing
                // request's placeholder resolution.
                if let final = outcome.finalVariables {
                    variables = final
                }
                preHeaderChanges += outcome.headerChanges
                prePhaseRan = prePhaseRan || !request.preRequestScript.isEmpty
            } catch {
                errorsByTab[tab] = "Pre-request script failed: \(scriptFailureText(error))"
                return
            }
            // Script-minted headers (`pm.request.headers.add` / `.upsert`)
            // apply to the request that goes out: adds append, upserts
            // replace the enabled same-name rows (case-insensitive). The
            // tab's rows stay the user's template, and the values still go
            // through `{{placeholder}}` resolution with the same map.
            var outbound = request
            if !preHeaderChanges.isEmpty {
                outbound.headers = Self.applyScriptHeaderChanges(
                    preHeaderChanges, to: request.headers)
            }
            // A stale OAuth 2.0 token is refreshed (or re-fetched, for the
            // silent grants) before the request goes out: the sent request
            // carries whatever the renewal produced, and the owner's token
            // entry lands back in the store either way.
            let authorization = await authorizationForSend(
                of: outbound, variables: variables)
            let sendStart = Date()
            // The HTTP client runs off the main actor; the callback hands the
            // assembled request back through this mutex-guarded slot. It is
            // written once before the network call and read after the await
            // returns, so the two sides never race.
            let sentRequest = Mutex<URLRequest?>(nil)
            // Apply any proxy-settings change before this send, so a toggle in
            // the Settings window takes effect on the next request.
            HTTPClient.applyProxySettings()
            do {
                let response = try await HTTPClient.send(
                    request: outbound,
                    variables: variables,
                    authorization: authorization,
                    onRequest: { urlRequest in sentRequest.withLock { $0 = urlRequest } }
                )
                guard sendTokens[tab] == token else { return }
                guard !Task.isCancelled else { return }
                // Post-response scripts (Postman's Tests tab): the
                // request's own first, then the collection's - assertions
                // and console lines land on the response snapshot, merged
                // with the pre-request phase's console lines. Engine and
                // script failures surface as a failed row - the send itself
                // is never discarded at this point.
                var responseWithScripts = response
                let collection = collectionForRequest(request)
                let collectionHasPost = !(collection?.postResponseScript.isEmpty ?? true)
                if !request.postResponseScript.isEmpty || collectionHasPost {
                    var results = preResults
                    var logs = preRequestLogs
                    // The request's own Tests script. Carries this send's
                    // pre-request writes (resets only when no pre phase ran).
                    let requestPost: ScriptPhaseOutcome
                    do {
                        requestPost = try await runScript(
                            .postResponse, script: request.postResponseScript, of: request,
                            variables: scriptVariables, resetsCarriedState: !prePhaseRan,
                            response: response)
                    } catch {
                        // Engine-level failure: a failed row, the response
                        // survives (scriptFailureText keeps the JS message).
                        requestPost = ScriptPhaseOutcome(
                            results: [
                                ScriptTestResult(
                                    name: "Script engine", status: .failed,
                                    message: scriptFailureText(error))
                            ])
                    }
                    results += requestPost.results
                    logs += requestPost.logs
                    if let error = requestPost.error {
                        results.append(
                            ScriptTestResult(
                                name: "Script error", status: .failed, message: error))
                    }
                    // Folder Tests scripts, innermost folder first.
                    for folder in (collection?.folderChain(forRequest: request.id) ?? [])
                    where !folder.postResponseScript.isEmpty {
                        let folderPost: ScriptPhaseOutcome
                        do {
                            folderPost = try await runScript(
                                .postResponse, script: folder.postResponseScript,
                                of: request, variables: scriptVariables,
                                resetsCarriedState: false, response: response)
                        } catch {
                            folderPost = ScriptPhaseOutcome(
                                results: [
                                    ScriptTestResult(
                                        name: "Script engine", status: .failed,
                                        message: scriptFailureText(error))
                                ])
                        }
                        results += folderPost.results
                        logs += folderPost.logs
                        if let error = folderPost.error {
                            results.append(
                                ScriptTestResult(
                                    name: "Folder script error (\(folder.name))",
                                    status: .failed, message: error))
                        }
                    }
                    // The collection's Tests script, reading the same
                    // carried state.
                    if let collection, !collection.postResponseScript.isEmpty {
                        let collectionPost: ScriptPhaseOutcome
                        do {
                            collectionPost = try await runScript(
                                .postResponse, script: collection.postResponseScript,
                                of: request, variables: scriptVariables,
                                resetsCarriedState: false, response: response)
                        } catch {
                            collectionPost = ScriptPhaseOutcome(
                                results: [
                                    ScriptTestResult(
                                        name: "Script engine", status: .failed,
                                        message: scriptFailureText(error))
                                ])
                        }
                        results += collectionPost.results
                        logs += collectionPost.logs
                        if let error = collectionPost.error {
                            results.append(
                                ScriptTestResult(
                                    name: "Collection script error", status: .failed,
                                    message: error))
                        }
                    }
                    responseWithScripts = response.withScripts(
                        results: results, logs: logs)
                }
                // The response becomes history's newest entry, which IS what
                // the tab displays (latest = index nil = history[0]). No
                // separate current-response copy exists to keep in sync.
                recordResponseHistory(responseWithScripts, for: request)
                // The console logs the address actually requested:
                // variables resolved (and query params merged) by the HTTP
                // client, with a resolved fallback so it never shows
                // {{placeholders}}. History keeps the raw template.
                let sentURLString =
                    sentRequest.withLock { $0 }?.url?.absoluteString
                    ?? VariableResolver.resolve(request.urlString, variables: variables)
                recordHistory(request: request, response: response)
                let sentBody = ConsoleEntry.capped(sentRequest.withLock { $0 }?.httpBody)
                let responseBody = ConsoleEntry.capped(response.body)
                recordConsoleEntry(
                    ConsoleEntry(
                        date: response.timestamp,
                        requestName: request.name,
                        method: request.httpMethod.rawValue,
                        url: ConsoleEntry.redactingSecrets(sentURLString, secrets: secretValues),
                        requestHeaders: sentRequest.withLock { $0 }.map(ConsoleEntry.maskedRequestHeaders(from:)) ?? [],
                        requestBody: sentBody.data.map { ConsoleEntry.redactingSecrets($0, secrets: secretValues) },
                        requestBodyTruncated: sentBody.truncated,
                        statusCode: response.statusCode,
                        // The response side carries credentials too: a
                        // `Set-Cookie` header, or a body that echoes the token
                        // back (`GET /me`).
                        responseHeaders: ConsoleEntry.maskedHeaders(response.headers),
                        responseBody: responseBody.data.map { ConsoleEntry.redactingSecrets($0, secrets: secretValues) },
                        responseBodyTruncated: responseBody.truncated,
                        duration: response.duration,
                        error: nil,
                        httpVersion: response.network?.httpVersion
                    )
                )
                // Last, after every send-side record is in: the modal panel
                // parks this task until the user picks a destination, and
                // nothing downstream needs to wait for it.
                if downloadResponse {
                    presentDownloadPanel(response)
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                // What URLSession actually throws when the Swift task is
                // cancelled (verified: NSURLError -999, not
                // CancellationError). A cancelled send records nothing.
                return
            } catch {
                guard sendTokens[tab] == token else { return }
                guard !Task.isCancelled else { return }
                errorsByTab[tab] = error.localizedDescription
                // The failed send replaces nothing: the previous response
                // (and its history) stays in place, so after dismissing the
                // error banner the last good response is what is shown -
                // like an old response kept in Postman.
                if let requestID = tab.requestID { viewingHistoryIndexByRequest[requestID] = nil }
                recordHistory(request: request, error: error, duration: Date().timeIntervalSince(sendStart))
                // Failures before onRequest (invalid URL, body build) never
                // capture the assembled URLRequest - resolve the URL so the
                // console does not show raw {{placeholders}}.
                let fallbackURL =
                    sentRequest.withLock { $0 }?.url?.absoluteString
                    ?? VariableResolver.resolve(request.urlString, variables: variables)
                let sentBody = ConsoleEntry.capped(sentRequest.withLock { $0 }?.httpBody)
                recordConsoleEntry(
                    ConsoleEntry(
                        date: Date(),
                        requestName: request.name,
                        method: request.httpMethod.rawValue,
                        url: ConsoleEntry.redactingSecrets(fallbackURL, secrets: secretValues),
                        requestHeaders: sentRequest.withLock { $0 }.map(ConsoleEntry.maskedRequestHeaders(from:)) ?? [],
                        requestBody: sentBody.data.map { ConsoleEntry.redactingSecrets($0, secrets: secretValues) },
                        requestBodyTruncated: sentBody.truncated,
                        statusCode: nil,
                        responseHeaders: [],
                        responseBody: nil,
                        responseBodyTruncated: false,
                        duration: Date().timeIntervalSince(sendStart),
                        // Can quote the resolved URL
                        // (`HTTPClientError.invalidURL`), so it is redacted
                        // like everything else the console keeps.
                        error: ConsoleEntry.redactingSecrets(
                            error.localizedDescription, secrets: secretValues),
                        // No response means no metrics - the version is
                        // unknowable here.
                        httpVersion: nil
                    )
                )
            }
        }
    }

    func recordResponseHistory(_ response: ResponseModel, for request: Request) {
        var history = responseHistoryByRequest[request.id] ?? []
        history.insert(response, at: 0)
        // A History entry picked while the send was in flight names the
        // previously-latest response: shift the selection so it keeps
        // pointing at the same entry (the drop reset below guards overflow).
        if let index = viewingHistoryIndexByRequest[request.id] {
            viewingHistoryIndexByRequest[request.id] = index + 1
        }
        var dropped = false
        if history.count > Self.responseHistoryLimit {
            history.removeLast(history.count - Self.responseHistoryLimit)
            // The count cap drops the OLDEST entries too - without this flag
            // a selection shifted onto an evicted index would stick out of
            // bounds (isViewingLatestResponse then disagrees with what is
            // shown until the next pick).
            dropped = true
        }
        // Keep the newest entry whatever its size - it is the response the
        // tab is showing - and drop whole older entries oldest-first until
        // the retained bodies fit the budget.
        var retained = history.reduce(0) { $0 + $1.bodySize }
        while history.count > 1, retained > Self.responseHistoryByteLimit {
            retained -= history[history.count - 1].bodySize
            history.removeLast()
            dropped = true
        }
        responseHistoryByRequest[request.id] = history
        // A fresh tab that started empty now has a response to show - any
        // view of the request (Duplicate Tab views share the history), so
        // every one of its markers clears, not just the primary form.
        resetResponseTabs = resetResponseTabs.filter { $0.requestID != request.id }
        // An index picked against the longer array no longer names the entry
        // it was chosen for; fall back to the latest instead of quietly
        // showing a different response.
        if dropped, viewingHistoryIndexByRequest[request.id] != nil {
            viewingHistoryIndexByRequest[request.id] = nil
        }
        trimResponseHistoryGlobalBudget()
        scheduleResponseHistoryPersistence()
    }

    /// Evicts the globally oldest response-history entry until the retained
    /// bodies across all requests fit `responseHistoryGlobalByteLimit`. The
    /// per-request cap cannot see cross-request accumulation: histories
    /// survive tab closes and relaunches now, so without this bound N
    /// requests pin N x 16 MB forever. Each request always keeps at least
    /// its newest entry - the one its tab displays.
    private func trimResponseHistoryGlobalBudget() {
        var total = responseHistoryByRequest.values.reduce(0) { total, history in
            total + history.reduce(0) { $0 + $1.bodySize }
        }
        guard total > Self.responseHistoryGlobalByteLimit else { return }
        while total > Self.responseHistoryGlobalByteLimit {
            // The next entry to lose is the LAST (oldest) one of the request
            // holding the globally oldest entry; only requests with a spare
            // entry participate, so every request keeps its displayed newest.
            guard
                let target =
                    responseHistoryByRequest
                    .filter({ $0.value.count > 1 })
                    .min(by: {
                        ($0.value.last?.timestamp ?? .distantPast)
                            < ($1.value.last?.timestamp ?? .distantPast)
                    })
            else { break }
            var history = target.value
            guard let oldest = history.last else { break }
            total -= oldest.bodySize
            history.removeLast()
            responseHistoryByRequest[target.key] = history
        }
    }

    /// Drops one request's stored responses (on request deletion): the
    /// deletion, not a tab close, is what ends a history's life now.
    func purgeResponseHistory(for requestID: UUID) {
        guard
            responseHistoryByRequest[requestID] != nil
                || viewingHistoryIndexByRequest[requestID] != nil
        else { return }
        responseHistoryByRequest[requestID] = nil
        viewingHistoryIndexByRequest[requestID] = nil
        scheduleResponseHistoryPersistence()
    }

    /// Mirrors the per-request response history to response-history.json
    /// (debounced, like the drafts and history mirrors) so it survives
    /// relaunches.
    func scheduleResponseHistoryPersistence() {
        responseHistorySaveTask?.cancel()
        responseHistorySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.vault.saveResponseHistory(self.responseHistoryByRequest)
        }
    }

    /// Save panel for Send and Download. The response still renders in the
    /// viewer; this writes the body to the chosen file. The suggested name
    /// comes from the sent URL and the response's Content-Type
    /// (`users.json`), like a browser download.
    private func presentDownloadPanel(_ response: ResponseModel) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = response.downloadFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url)
        } catch {
            AppLogger.error("Failed to save downloaded response body: \(error)", category: "Send")
        }
    }

    /// Records a completed send in the history. The URL is the request's
    /// raw template exactly as entered (Postman-style) - the resolved
    /// address is only for the console.
    func recordHistory(request: Request, response: ResponseModel) {
        let entry = HistoryEntry(
            requestID: request.id,
            name: request.name,
            method: request.httpMethod,
            urlString: request.urlString,
            statusCode: response.statusCode,
            duration: response.duration,
            timestamp: Date()
        )
        history.insert(entry, at: 0)
        if history.count > historyLimit { history.removeLast() }
        scheduleHistoryPersistence()
    }

    /// Records a failed send. Keeps the real elapsed time (so a timeout and
    /// a DNS failure are not both "0 ms") and a machine-stable error kind
    /// (`timedOut`, `cannotConnectToHost`, …) so failures are distinguishable
    /// instead of collapsing into statusCode 0 / 0 ms.
    func recordHistory(request: Request, error: Error, duration: TimeInterval) {
        let entry = HistoryEntry(
            requestID: request.id,
            name: request.name,
            method: request.httpMethod,
            urlString: request.urlString,
            statusCode: 0,
            duration: duration,
            timestamp: Date(),
            errorKind: Self.errorKind(of: error)
        )
        history.insert(entry, at: 0)
        if history.count > historyLimit { history.removeLast() }
        scheduleHistoryPersistence()
    }

    /// Machine-stable name of what went wrong - nil for successes. `URLError`
    /// codes surface as their case name (`timedOut`, `cannotConnectToHost`,
    /// …); everything else lands as `error`.
    /// Applies script header mutations (`pm.request.headers.add` /
    /// `.upsert` / `.remove`) to the outgoing header list, in call order:
    /// adds append a new row, upserts replace every enabled row of the same
    /// name (case-insensitive), removes drop the enabled rows of the same
    /// name. Disabled rows and the stored request stay untouched; the
    /// returned list feeds `{{placeholder}}` resolution like tab-authored
    /// headers.
    private static func applyScriptHeaderChanges(
        _ changes: [ScriptHeaderChange], to headers: [HTTPHeader]
    ) -> [HTTPHeader] {
        var result = headers
        for change in changes {
            let name = change.name.lowercased()
            switch change.kind {
            case .add:
                result.append(HTTPHeader(key: change.name, value: change.value))
            case .upsert:
                result.removeAll { $0.isEnabled && $0.key.lowercased() == name }
                result.append(HTTPHeader(key: change.name, value: change.value))
            case .remove:
                result.removeAll { $0.isEnabled && $0.key.lowercased() == name }
            }
        }
        return result
    }

    private static func errorKind(of error: Error) -> String? {
        (error as? URLError).map { String(describing: $0.code) } ?? "error"
    }

    /// Appends a network activity entry to the console log, trimming the
    /// oldest entries past the cap - by entry count and by retained body
    /// bytes, so a session of large payloads cannot pin hundreds of
    /// megabytes of triage log.
    func recordConsoleEntry(_ entry: ConsoleEntry) {
        consoleEntries.append(entry)
        if consoleEntries.count > Self.consoleEntryLimit {
            consoleEntries.removeFirst(consoleEntries.count - Self.consoleEntryLimit)
        }
        var retained = consoleEntries.reduce(0) { $0 + $1.retainedBodyBytes }
        while consoleEntries.count > 1, retained > Self.consoleBodyByteLimit {
            retained -= consoleEntries[0].retainedBodyBytes
            consoleEntries.removeFirst()
        }
        scheduleConsolePersistence()
    }

    /// Clears the console log (the Clear button in the Console window).
    func clearConsole() {
        consoleEntries.removeAll()
        scheduleConsolePersistence()
    }

    /// Mirrors the console log to console.json (debounced like the history
    /// mirror) so a burst of sends rewrites the file once.
    func scheduleConsolePersistence() {
        consoleSaveTask?.cancel()
        consoleSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.vault.saveConsole(self.consoleEntries)
        }
    }

    /// Removes a single entry (the history row's hover delete) and mirrors
    /// the change to disk.
    func removeHistoryEntry(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        scheduleHistoryPersistence()
    }

    func clearHistory() {
        history.removeAll()
        scheduleHistoryPersistence()
    }

    /// Mirrors the in-memory history to history.json (debounced, like the
    /// drafts mirror) so it survives relaunches.
    func scheduleHistoryPersistence() {
        historySaveTask?.cancel()
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.vault.saveHistory(self.history)
        }
    }

}
