import Foundation
import Synchronization

/// AppStore request sending: per-tab responses and history, global history,
/// and the console (network log).
@MainActor
extension AppStore {

    var currentResponse: ResponseModel? {
        get { selectedTab.flatMap { responsesByTab[$0] } }
        set { if let tab = selectedTab { responsesByTab[tab] = newValue } }
    }

    /// The response displayed for the selected tab: the latest one, or an
    /// older entry picked from the response panel's History menu.
    var displayedResponse: ResponseModel? {
        guard let tab = selectedTab else { return nil }
        let index = viewingHistoryIndexByTab[tab]
        let history = responseHistoryByTab[tab]
        if let index, let history, history.indices.contains(index) {
            return history[index]
        }
        return responsesByTab[tab]
    }

    var responseHistoryForSelectedTab: [ResponseModel] {
        selectedTab.flatMap { responseHistoryByTab[$0] } ?? []
    }

    var isViewingLatestResponse: Bool {
        guard let tab = selectedTab else { return true }
        return viewingHistoryIndexByTab[tab] == nil
    }

    /// Shows the latest response (nil index) or a historical entry.
    func selectResponseHistoryEntry(at index: Int?) {
        guard let tab = selectedTab else { return }
        viewingHistoryIndexByTab[tab] = index
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
    func send(_ request: Request) {
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
        viewingHistoryIndexByTab[tab] = nil
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
            let variables = variablesForRequest(request)
            let authorization = authorizationForRequest(request)
            let sendStart = Date()
            // The HTTP client runs off the main actor; the callback hands the
            // assembled request back through this mutex-guarded slot. It is
            // written once before the network call and read after the await
            // returns, so the two sides never race.
            let sentRequest = Mutex<URLRequest?>(nil)
            do {
                let response = try await HTTPClient.send(
                    request: request,
                    variables: variables,
                    authorization: authorization,
                    onRequest: { urlRequest in sentRequest.withLock { $0 = urlRequest } }
                )
                guard sendTokens[tab] == token else { return }
                guard !Task.isCancelled else { return }
                responsesByTab[tab] = response
                recordResponseHistory(response, for: tab)
                recordHistory(request: request, response: response)
                recordConsoleEntry(
                    ConsoleEntry(
                        date: response.timestamp,
                        requestName: request.name,
                        method: request.httpMethod.rawValue,
                        url: sentRequest.withLock { $0 }?.url?.absoluteString ?? request.urlString,
                        requestHeaders: sentRequest.withLock { $0 }.map(ConsoleEntry.maskedRequestHeaders(from:)) ?? [],
                        requestBody: ConsoleEntry.capped(sentRequest.withLock { $0 }?.httpBody).data,
                        requestBodyTruncated: ConsoleEntry.capped(sentRequest.withLock { $0 }?.httpBody).truncated,
                        statusCode: response.statusCode,
                        responseHeaders: response.headers,
                        responseBody: ConsoleEntry.capped(response.body).data,
                        responseBodyTruncated: ConsoleEntry.capped(response.body).truncated,
                        duration: response.duration,
                        error: nil
                    )
                )
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
                responsesByTab[tab] = nil
                viewingHistoryIndexByTab[tab] = nil
                recordHistory(request: request, error: true)
                recordConsoleEntry(
                    ConsoleEntry(
                        date: Date(),
                        requestName: request.name,
                        method: request.httpMethod.rawValue,
                        url: sentRequest.withLock { $0 }?.url?.absoluteString ?? request.urlString,
                        requestHeaders: sentRequest.withLock { $0 }.map(ConsoleEntry.maskedRequestHeaders(from:)) ?? [],
                        requestBody: ConsoleEntry.capped(sentRequest.withLock { $0 }?.httpBody).data,
                        requestBodyTruncated: ConsoleEntry.capped(sentRequest.withLock { $0 }?.httpBody).truncated,
                        statusCode: nil,
                        responseHeaders: [],
                        responseBody: nil,
                        responseBodyTruncated: false,
                        duration: Date().timeIntervalSince(sendStart),
                        error: error.localizedDescription
                    )
                )
            }
        }
    }

    func recordResponseHistory(_ response: ResponseModel, for tab: OpenTab) {
        var history = responseHistoryByTab[tab] ?? []
        history.insert(response, at: 0)
        if history.count > Self.responseHistoryLimit {
            history.removeLast(history.count - Self.responseHistoryLimit)
        }
        responseHistoryByTab[tab] = history
    }

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
    }

    func recordHistory(request: Request, error: Bool) {
        let entry = HistoryEntry(
            requestID: request.id,
            name: request.name,
            method: request.httpMethod,
            urlString: request.urlString,
            statusCode: 0,
            duration: 0,
            timestamp: Date()
        )
        history.insert(entry, at: 0)
        if history.count > historyLimit { history.removeLast() }
    }

    /// Appends a network activity entry to the console log, trimming the
    /// oldest entries past the cap.
    func recordConsoleEntry(_ entry: ConsoleEntry) {
        consoleEntries.append(entry)
        if consoleEntries.count > Self.consoleEntryLimit {
            consoleEntries.removeFirst(consoleEntries.count - Self.consoleEntryLimit)
        }
    }

    /// Clears the console log (the Clear button in the Console window).
    func clearConsole() {
        consoleEntries.removeAll()
    }

    func clearHistory() {
        history.removeAll()
    }

}
