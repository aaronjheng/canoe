import Foundation
import Synchronization

/// Errors surfaced by the WebSocket transport. `LocalizedError` so the
/// message pane can show them as-is.
enum WebSocketClientError: Error, LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case openTimedOut
    /// The server answered the upgrade with a non-101 response (404, 401,
    /// …). `status` is the response's status code when one was captured.
    case handshakeRejected(status: Int?)
    /// An operation (send/ping/close) on a connection that is not open.
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid WebSocket URL: \(url)"
        case .unsupportedScheme(let scheme):
            return "Unsupported scheme \(scheme) - use ws:// or wss://"
        case .openTimedOut: return "The connection timed out before the server completed the handshake."
        case .handshakeRejected(let status):
            if let status {
                return "The server rejected the WebSocket handshake (\(status))."
            }
            return "The server rejected the WebSocket handshake."
        case .notConnected: return "The connection is not open."
        }
    }
}

/// One live WebSocket connection (a raw ws/wss session): owns its
/// URLSession and URLSessionWebSocketTask, runs the receive loop, and
/// forwards open / message / close events to a single handler.
///
/// Threading: the delegate callbacks arrive on the session's private
/// serial queue, sends on the caller's actor - all shared state is
/// mutex-guarded, and the class is `@unchecked Sendable` for the same
/// reason `HTTPClient`'s `SessionBox` is. Events hop to the consumer's
/// actor through the handler (`AppStore` wraps it in `Task { @MainActor }`).
final class WebSocketConnection: NSObject, @unchecked Sendable {
    /// Everything the message pane reacts to. One connection delivers at
    /// most one `open` and one `closed`.
    enum Event: Sendable {
        case open(subprotocol: String?, handshake: HandshakeResponse)
        case text(String)
        case binary(Data)
        /// The reply to an explicit `ping()` (URLSession answers server
        /// pings itself - those never surface here).
        case pong
        case closed(code: Int?, reason: String?, errorText: String?)
    }

    /// The upgrade response (101 - or the rejection, on a failed
    /// handshake), shown in the connection badge's details.
    struct HandshakeResponse: Sendable {
        let statusCode: Int?
        let headers: [HTTPHeader]
    }

    private struct State {
        var eventHandler: (@Sendable (Event) -> Void)?
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var openContinuation: CheckedContinuation<HandshakeResponse?, Error>?
        /// Whether the open path settled (succeeded or failed): guards the
        /// continuation's single resume and keeps `open` a one-time event.
        var opened = false
        /// Whether a `closed` event already went out: `didCloseWith` and
        /// `didCompleteWithError` both fire for one close - only the first
        /// becomes an event.
        var closedEmitted = false
        var handshake: HandshakeResponse?
        var openWatchdog: Task<Void, Never>?
        var verifySSLCertificate = true
    }

    private let state = Mutex(State())
    /// Liveness flag of the receive loop: it hops between executors, so a
    /// plain mutex boolean keeps it single-flight.
    private let receiveLoopLock = Mutex(false)

    /// Set once before `connect`; every subsequent event routes here.
    func setEventHandler(_ handler: (@Sendable (Event) -> Void)?) {
        state.withLock { $0.eventHandler = handler }
    }

    /// Whether the TLS server certificate is validated. Off accepts any
    /// chain - the same language as the HTTP request Settings tab. Set
    /// once before `connect`.
    func setVerifySSLCertificate(_ verify: Bool) {
        state.withLock { $0.verifySSLCertificate = verify }
    }

    /// Performs the HTTP upgrade handshake. Returns the captured 101
    /// response (status + headers); throws on failure - timeout, rejected
    /// handshake, refused connection. `proxyDictionary` is the app's
    /// current proxy setting (the caller reads it from `SettingsStore`,
    /// keeping this layer settings-agnostic); `openTimeout` bounds the
    /// handshake.
    func connect(
        _ urlRequest: URLRequest,
        proxyDictionary: [String: Any]?,
        openTimeout: TimeInterval
    ) async throws -> HandshakeResponse? {
        let config = URLSessionConfiguration.default
        // The request timeout bounds the handshake only - a WebSocket
        // session stays open while idle, so the resource timeout must not
        // end it. A week is "effectively never" while keeping the type's
        // finite contract.
        config.timeoutIntervalForRequest = max(openTimeout, 5)
        config.timeoutIntervalForResource = 604_800
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = proxyDictionary
        let session = URLSession(
            configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: urlRequest)
        // A session message larger than this fails the receive with an
        // error and the connection with it - 64 MiB is far above any
        // realistic frame, while an unbounded receive could pin memory.
        task.maximumMessageSize = 64 * 1_048_576
        state.withLock {
            $0.session = session
            $0.task = task
        }
        let handshake: HandshakeResponse? = try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.openContinuation = continuation }
            task.resume()
            let timeout = max(openTimeout, 5)
            let watchdog = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    // Cancelled - the open path settled and cancelled this
                    // watchdog. A cancelled sleep must NOT fire it: `try?`
                    // would swallow the cancellation error and fall through
                    // to failOpen, aborting a connection that just opened.
                    return
                }
                self?.failOpen(WebSocketClientError.openTimedOut)
            }
            state.withLock { $0.openWatchdog = watchdog }
        }
        return handshake
    }

    /// Sends a text frame. Only valid once the handshake completed.
    func send(text: String) async throws {
        try await currentTask().send(.string(text))
    }

    /// Sends a binary frame. Only valid once the handshake completed.
    func send(data: Data) async throws {
        try await currentTask().send(.data(data))
    }

    /// Sends a ping; the ping resolves once the pong comes back
    /// (URLSession matches them internally).
    func ping() async throws {
        let task = try currentTask()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Client-initiated close: sends a close frame with the normal-closure
    /// code and lets the server answer. The connection reports `closed`
    /// when the handshake settles (or the transport fails trying).
    func close() {
        let task = try? currentTask()
        task?.cancel(with: .normalClosure, reason: nil)
    }

    /// Tears the connection down immediately (timeout, user abort during
    /// the handshake): cancels everything in flight and invalidates the
    /// session so its delegate queue and sockets are released.
    func abort() {
        AppLogger.info("WS transport abort() called", category: "WebSocket")
        let (session, task) = state.withLock { state in
            (state.session, state.task)
        }
        state.withLock { $0.openWatchdog?.cancel() }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Internals

    private func currentTask() throws -> URLSessionWebSocketTask {
        let task = state.withLock { $0.task }
        guard let task else { throw WebSocketClientError.notConnected }
        return task
    }

    /// Resolves the open continuation with a failure (once) and tears the
    /// session down. Used by the watchdog and by any failure before `open`.
    /// A stale firing after the open path settled (the watchdog waking from
    /// its own cancellation) does nothing: the connection stays up.
    private func failOpen(_ error: Error) {
        let resumed: CheckedContinuation<HandshakeResponse?, Error>? = state.withLock { state in
            guard !state.opened else { return nil }
            state.opened = true
            let continuation = state.openContinuation
            state.openContinuation = nil
            return continuation
        }
        guard let resumed else { return }
        resumed.resume(throwing: error)
        abort()
    }

    /// Completes the open path (once): resolves the continuation, captures
    /// the handshake, emits `open`, and starts the receive loop.
    private func succeedOpen(subprotocol: String?) {
        let (opened, handshake) = state.withLock { state -> (Bool, HandshakeResponse?) in
            guard !state.opened else { return (false, nil) }
            state.opened = true
            if let task = state.task {
                state.handshake = Self.handshakeResponse(of: task)
            }
            state.openWatchdog?.cancel()
            let continuation = state.openContinuation
            state.openContinuation = nil
            continuation?.resume(returning: state.handshake)
            return (true, state.handshake)
        }
        guard opened, let handshake else { return }
        startReceiveLoop()
        emit(.open(subprotocol: subprotocol, handshake: handshake))
    }

    /// Reads `task.response` - URLSession surfaces the upgrade's 101 (or
    /// the rejection's status) there once the handshake has an answer.
    private static func handshakeResponse(of task: URLSessionWebSocketTask) -> HandshakeResponse? {
        guard let response = task.response as? HTTPURLResponse else { return nil }
        let headers = response.allHeaderFields.compactMap { (key, value) -> HTTPHeader? in
            guard let key = key as? String, let value = value as? String else { return nil }
            return HTTPHeader(key: key, value: value)
        }
        return HandshakeResponse(statusCode: response.statusCode, headers: headers)
    }

    private func startReceiveLoop() {
        receiveLoopLock.withLock { running in
            guard !running else { return }
            running = true
        }
        Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    /// Delivers frames until the transport ends. Errors are NOT events:
    /// every failure path also fires `didCompleteWithError` (or the close
    /// was already reported), which owns the single `closed` event.
    private func runReceiveLoop() async {
        while true {
            guard let task = state.withLock({ $0.task }) else { break }
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): emit(.text(text))
                case .data(let data): emit(.binary(data))
                @unknown default: break
                }
            } catch {
                break
            }
        }
        receiveLoopLock.withLock { running in
            running = false
        }
    }

    private func emit(_ event: Event) {
        let handler = state.withLock { $0.eventHandler }
        handler?(event)
    }

    /// Emits the single `closed` event of the connection's lifetime,
    /// whichever of the two close callbacks wins the race.
    private func emitClosed(code: Int?, reason: String?, errorText: String?) {
        let shouldEmit = state.withLock { state -> Bool in
            guard !state.closedEmitted else { return false }
            state.closedEmitted = true
            return true
        }
        guard shouldEmit else { return }
        emit(.closed(code: code, reason: reason, errorText: errorText))
    }

    /// Map a close frame to its code/reason text (URLSession reports the
    /// reason as bytes; it is advisory text, best-effort decoded).
    private static func closeReasonText(_ reason: Data?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        return String(data: reason, encoding: .utf8) ?? "\(reason.count) bytes"
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketConnection: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        AppLogger.info("WS transport open", category: "WebSocket", fields: ["protocol": `protocol` ?? "-"])
        succeedOpen(subprotocol: `protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // The close frame only counts after the connection was open: a
        // pre-open failure owns its report through the failed handshake.
        AppLogger.info(
            "WS transport didCloseWith", category: "WebSocket",
            fields: ["code": String(closeCode.rawValue), "reason": Self.closeReasonText(reason) ?? "-"])
        let wasOpen = state.withLock { $0.opened }
        guard wasOpen else { return }
        emitClosed(
            code: closeCode.rawValue,
            reason: Self.closeReasonText(reason),
            errorText: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        AppLogger.info(
            "WS transport didComplete", category: "WebSocket",
            fields: ["error": error.map(String.init(describing:)) ?? "nil"])
        let wasOpen = state.withLock { $0.opened }
        if !wasOpen {
            // The handshake never completed: the open continuation owns the
            // failure (enriched with the rejection status when the server
            // answered with a regular response).
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let clientError: Error =
                (status != nil && status != 101)
                ? WebSocketClientError.handshakeRejected(status: status)
                : (error ?? WebSocketClientError.openTimedOut)
            failOpen(clientError)
            state.withLock { $0.session?.invalidateAndCancel() }
            return
        }
        if let error {
            // Cancellation of the whole session (abort) lands here too -
            // an aborted close is not an error worth quoting.
            let cancelled =
                (error as? URLError)?.code == .cancelled || error is CancellationError
            emitClosed(code: nil, reason: nil, errorText: cancelled ? nil : error.localizedDescription)
        } else {
            // Clean completion (our own close handshake finished).
            emitClosed(code: nil, reason: nil, errorText: nil)
        }
        state.withLock { $0.session?.invalidateAndCancel() }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // `verifySSLCertificate` off accepts any server certificate
        // (self-signed, expired, hostname mismatch).
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let verify = state.withLock { $0.verifySSLCertificate }
        if verify {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}
