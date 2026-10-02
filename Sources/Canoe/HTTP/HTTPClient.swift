import Foundation
import Security
import Synchronization

enum HTTPClientError: Error, LocalizedError {
    case invalidURL(String)
    case fileNotFound(String)
    case fileTooLarge(String)
    case noResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .fileTooLarge(let path): return "File is too large to send (>100 MB): \(path)"
        case .noResponse: return "No response received from the server."
        }
    }
}

/// Executes a `Request` (with variables resolved) using URLSession async
/// and returns a transient `ResponseModel`.
enum HTTPClient {
    static let userAgent = "Canoe/1.0.0"

    /// Cap on the buffered response body. The body is held in memory for the
    /// viewer and again in every response-history entry (20 per tab), so an
    /// uncapped multi-hundred-megabyte download could pin tens of gigabytes.
    /// Mirrors the request-body cap's intent: refuse to grow without bound,
    /// while staying far above any real API payload. This bounds ONE
    /// response; the history multiplies it, which is why the response panel
    /// says plainly that the body was cut.
    static let maxResponseBytes = 50 * 1024 * 1024

    /// Leaf-certificate fields pulled during the server-trust challenge.
    private struct CertificateSnapshot: Sendable {
        let subjectCN: String?
        let issuerCN: String?
        let notAfter: Date?
    }

    private struct Outcome {
        let data: Data
        /// The body hit `maxResponseBytes` and was cut short.
        let truncated: Bool
        let response: HTTPURLResponse
        let metrics: URLSessionTaskMetrics?
        let certificate: CertificateSnapshot?
    }

    /// Joins the data-task completion with `didFinishCollecting` (metrics
    /// often land just after the body handler) and the server-trust
    /// challenge. Successful bodies wait briefly for metrics; errors resume
    /// immediately so a failed send never hangs on telemetry.
    private final class RequestTelemetry: @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Outcome, Error>?
            var data = Data()
            /// Tail of a chunk that ended mid-UTF-8 character (URLSession
            /// splits wherever it likes), held back until the next chunk
            /// completes it - otherwise the retained body can decode as nil.
            var pendingTail = Data()
            var truncated = false
            var response: HTTPURLResponse?
            var error: Error?
            var metrics: URLSessionTaskMetrics?
            var certificate: CertificateSnapshot?
            var bodySettled = false
            var metricsSettled = false
            var allowMissingMetrics = false
            var resumed = false
            var metricsTimeout: Task<Void, Never>?
        }

        private enum Completion {
            case none
            case success(CheckedContinuation<Outcome, Error>, Outcome)
            case failure(CheckedContinuation<Outcome, Error>, Error)
        }

        private let state = Mutex(State())
        private let taskID: Int
        private let unregister: @Sendable (Int) -> Void

        init(taskID: Int, unregister: @escaping @Sendable (Int) -> Void) {
            self.taskID = taskID
            self.unregister = unregister
        }

        func setCertificate(_ snapshot: CertificateSnapshot) {
            state.withLock { $0.certificate = snapshot }
        }

        func setMetrics(_ metrics: URLSessionTaskMetrics) {
            state.withLock {
                $0.metrics = metrics
                $0.metricsSettled = true
                $0.metricsTimeout?.cancel()
                $0.metricsTimeout = nil
            }
            pump()
        }

        /// Accumulates one body chunk, stopping at `maxResponseBytes`. The
        /// rest of the response still downloads (and still shows up in the
        /// Size panel, which reads the true byte counts from the task
        /// metrics) but is never retained.
        func append(_ chunk: Data) {
            state.withLock { current in
                guard !chunk.isEmpty else { return }
                let incoming = current.pendingTail.isEmpty ? chunk : current.pendingTail + chunk
                current.pendingTail = Data()
                let room = HTTPClient.maxResponseBytes - current.data.count
                guard room > 0 else {
                    current.truncated = true
                    return
                }
                if incoming.count <= room {
                    // Hold back a character the chunk boundary split: at most
                    // three bytes of a UTF-8 sequence can be leading over.
                    // `count - 1`: a one-byte chunk is a complete character by
                    // definition, so never hold the whole buffer back.
                    let hold = max(0, min(Self.incompleteUTF8TailLength(incoming), incoming.count - 1))
                    current.data.append(incoming.prefix(incoming.count - hold))
                    current.pendingTail = Data(incoming.suffix(hold))
                } else {
                    // The cap can land mid-character; `utf8Prefix` drops the
                    // continuation bytes, and a trailing lead byte whose
                    // character never arrived has to go too - otherwise the
                    // retained body no longer decodes as UTF-8 at all.
                    var cut = Self.utf8Prefix(incoming, bytes: room)
                    let dangling = Self.incompleteUTF8TailLength(cut)
                    if dangling > 0 { cut = cut.prefix(cut.count - dangling) }
                    current.data.append(cut)
                    current.truncated = true
                }
            }
        }

        /// Bytes at the end of `chunk` that begin a UTF-8 character the chunk
        /// did not finish (0 when it ends on a character boundary).
        ///
        /// Scans back over at most one character's worth of bytes to the lead
        /// byte and compares what is present against what that lead byte
        /// promises: 0xF0-0xF7 need four bytes, 0xE0-0xEF three, 0xC0-0xDF
        /// two, anything else is ASCII and always complete.
        static func incompleteUTF8TailLength(_ chunk: Data) -> Int {
            let boundary = chunk.startIndex + chunk.count
            let earliest = chunk.index(boundary, offsetBy: -min(4, chunk.count))
            var cursor = boundary
            while cursor > earliest {
                cursor -= 1
                let byte = chunk[cursor]
                guard byte & 0b1100_0000 == 0b1000_0000 else {
                    let expected =
                        byte & 0b1111_1000 == 0b1111_0000
                        ? 4
                        : byte & 0b1111_0000 == 0b1110_0000
                            ? 3
                            : byte & 0b1110_0000 == 0b1100_0000
                                ? 2
                                : 1
                    let available = boundary - cursor
                    return available < expected ? available : 0
                }
            }
            // A window of nothing but continuation bytes is not valid UTF-8 to
            // begin with: holding it back would only delay the same decode
            // failure by one chunk.
            return 0
        }

        /// The first `bytes` of a chunk (`bytes < chunk.count`), cut at a UTF-8
        /// character boundary:
        /// slicing mid-sequence would make the whole retained body decode as
        /// nil, turning a text response into "<binary data>" in the viewer.
        private static func utf8Prefix(_ chunk: Data, bytes: Int) -> Data {
            var end = bytes
            // Continuation bytes match 0b10xxxxxx; a lead byte starts a new
            // character. Dropping trailing continuation bytes lands on the
            // last complete character. At most three steps for UTF-8.
            while end > 0, chunk[chunk.startIndex + end] & 0b1100_0000 == 0b1000_0000 {
                end -= 1
            }
            return Data(chunk.prefix(end))
        }

        func finishBody(response: URLResponse?, error: Error?) {
            state.withLock {
                $0.bodySettled = true
                $0.error = error
                if let http = response as? HTTPURLResponse {
                    $0.response = http
                }
                if error == nil, !$0.metricsSettled {
                    $0.metricsTimeout = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        self?.metricsWaitTimedOut()
                    }
                }
            }
            pump()
        }

        func attach(_ continuation: CheckedContinuation<Outcome, Error>) {
            state.withLock { $0.continuation = continuation }
            pump()
        }

        private func metricsWaitTimedOut() {
            state.withLock {
                $0.allowMissingMetrics = true
                $0.metricsTimeout = nil
            }
            pump()
        }

        private func pump() {
            let completion: Completion = state.withLock { current in
                guard !current.resumed, let cont = current.continuation else { return .none }

                if current.bodySettled, let error = current.error {
                    current.resumed = true
                    current.continuation = nil
                    current.metricsTimeout?.cancel()
                    current.metricsTimeout = nil
                    return .failure(cont, error)
                }

                guard current.bodySettled else { return .none }
                if !current.metricsSettled && !current.allowMissingMetrics { return .none }

                guard let response = current.response else {
                    current.resumed = true
                    current.continuation = nil
                    current.metricsTimeout?.cancel()
                    current.metricsTimeout = nil
                    return .failure(cont, HTTPClientError.noResponse)
                }

                current.resumed = true
                current.continuation = nil
                current.metricsTimeout?.cancel()
                current.metricsTimeout = nil
                return .success(
                    cont,
                    Outcome(
                        data: current.data,
                        truncated: current.truncated,
                        response: response,
                        metrics: current.metrics,
                        certificate: current.certificate
                    )
                )
            }

            switch completion {
            case .none:
                break
            case .success(let cont, let outcome):
                unregister(taskID)
                cont.resume(returning: outcome)
            case .failure(let cont, let error):
                unregister(taskID)
                cont.resume(throwing: error)
            }
        }
    }

    /// Strips credentials when a redirect leaves the original host (or
    /// downgrades https to http), so an Authorization helper value is never
    /// leaked to a third party through a redirect. Same-host redirects pass
    /// through untouched. Stateless, so sharing it across sends is safe.
    /// Also collects per-send task metrics and server-trust certificates.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
        private let telemetryByID = Mutex<[Int: RequestTelemetry]>([:])

        func makeTelemetry(taskID: Int) -> RequestTelemetry {
            RequestTelemetry(taskID: taskID) { [weak self] id in
                self?.telemetryByID.withLock { $0[id] = nil }
            }
        }

        func register(_ telemetry: RequestTelemetry, taskID: Int) {
            telemetryByID.withLock { $0[taskID] = telemetry }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var redirected = request
            let from = task.originalRequest?.url
            let to = request.url
            let crossHost = from?.host?.lowercased() != to?.host?.lowercased()
            let downgraded = from?.scheme?.lowercased() == "https" && to?.scheme?.lowercased() == "http"
            if crossHost || downgraded {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(redirected)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            telemetryByID.withLock { $0[task.taskIdentifier]?.setMetrics(metrics) }
        }

        /// Body chunks stream in here rather than through the task's
        /// completion handler (which yields nil as soon as a delegate claims
        /// the data), so `RequestTelemetry` can cap what it retains.
        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            telemetryByID.withLock { $0[dataTask.taskIdentifier]?.append(data) }
        }

        /// The task's end: with a data delegate in place this - not the
        /// completion handler - is what settles the body.
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            telemetryByID.withLock { $0[task.taskIdentifier]?.finishBody(response: task.response, error: error) }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if let snapshot = Self.serverTrustSnapshot(from: challenge) {
                telemetryByID.withLock { $0[task.taskIdentifier]?.setCertificate(snapshot) }
            }
            completionHandler(.performDefaultHandling, nil)
        }

        /// Leaf certificate from a server-trust challenge, if this is one.
        private static func serverTrustSnapshot(
            from challenge: URLAuthenticationChallenge
        ) -> CertificateSnapshot? {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                let trust = challenge.protectionSpace.serverTrust
            else { return nil }
            return certificateSnapshot(from: trust)
        }

        /// Subject CN, issuer CN, and not-after from the leaf certificate.
        /// Default TLS validation still runs (performDefaultHandling) - this
        /// only reads the chain for the Network panel.
        private static func certificateSnapshot(from trust: SecTrust) -> CertificateSnapshot? {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                let leaf = chain.first
            else { return nil }

            let subjectCN = SecCertificateCopySubjectSummary(leaf) as String?
            var error: Unmanaged<CFError>?
            let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray
            guard let values = SecCertificateCopyValues(leaf, keys, &error) as? [String: Any] else {
                return CertificateSnapshot(subjectCN: subjectCN, issuerCN: nil, notAfter: nil)
            }

            var issuerCN: String?
            if let value = propertyValue(in: values, key: kSecOIDX509V1IssuerName) {
                issuerCN = commonName(inNameValue: value)
            }

            let notAfter = propertyValue(in: values, key: kSecOIDX509V1ValidityNotAfter) as? Date

            return CertificateSnapshot(subjectCN: subjectCN, issuerCN: issuerCN, notAfter: notAfter)
        }

        /// `SecCertificateCopyValues` entry: OID dict → its value payload.
        private static func propertyValue(in values: [String: Any], key: CFString) -> Any? {
            (values[key as String] as? [String: Any])?[kSecPropertyKeyValue as String]
        }

        /// Distinguished-name value: either a bare string or an array of
        /// `{label, value}` RDN components - pick the common name.
        private static func commonName(inNameValue value: Any) -> String? {
            if let components = value as? [[String: Any]] {
                for component in components {
                    let label = component[kSecPropertyKeyLabel as String] as? String ?? ""
                    if label.lowercased().contains("common name") || label == kSecOIDCommonName as String {
                        if let text = component[kSecPropertyKeyValue as String] as? String {
                            return text
                        }
                    }
                }
            }
            return value as? String
        }
    }

    private static let redirectPolicy = RedirectPolicy()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // An API client must never serve a cached response as a fresh send.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
    }()

    /// Sends the request. `authorization` is the already-resolved effective
    /// settings (the request's own, or the parent collection's when it
    /// inherits - see `AppStore.authorizationForRequest`); a manually set
    /// Authorization header always wins over the helper.
    static func send(
        request: Request,
        variables: [String: String],
        authorization: Authorization,
        onRequest: (@Sendable (URLRequest) -> Void)? = nil
    ) async throws -> ResponseModel {
        let resolvedURLString = VariableResolver.resolve(request.urlString, variables: variables)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedURLString.isEmpty else {
            throw HTTPClientError.invalidURL("(empty URL)")
        }
        // Postman-style convenience: bare "api.example.com/users" becomes
        // "https://api.example.com/users" instead of an error.
        let withScheme =
            resolvedURLString.contains("://") ? resolvedURLString : "https://\(resolvedURLString)"
        guard var components = URLComponents(string: withScheme) else {
            throw HTTPClientError.invalidURL(resolvedURLString)
        }

        // Merge enabled query params into the URL (skip empty keys, which
        // would otherwise produce junk like "?=value").
        let enabledParams = request.params.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !enabledParams.isEmpty {
            var queryItems = components.queryItems ?? []
            for param in enabledParams {
                let name = VariableResolver.resolve(param.key, variables: variables)
                // A key that resolves to empty (e.g. key="{{empty}}" with
                // empty="") must be skipped like headers are - otherwise the
                // wire carries junk like "?=1".
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                queryItems.append(
                    URLQueryItem(
                        name: name,
                        value: VariableResolver.resolve(param.value, variables: variables)
                    ))
            }
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw HTTPClientError.invalidURL(resolvedURLString)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Headers (skip rows with an empty name - URLRequest ignores them and
        // they only add noise).
        var hasContentType = false
        var hasAuthorization = false
        for header in request.headers where header.isEnabled {
            let key = VariableResolver.resolve(header.key, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let value = VariableResolver.resolve(header.value, variables: variables)
            urlRequest.setValue(value, forHTTPHeaderField: key)
            if key.lowercased() == "content-type" { hasContentType = true }
            if key.lowercased() == "authorization" { hasAuthorization = true }
        }

        // Authorization helper (a manually set Authorization header always
        // wins over it).
        if !hasAuthorization {
            switch authorization.type {
            case .none, .inherit:
                // inherit is resolved by the caller; treat it defensively
                // as none here.
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
            }
        }

        // Body (every method may carry one, including GET/HEAD; the encoding
        // is decided by the body's type selector).
        let built = try buildBody(for: request, variables: variables)
        if let built, !built.data.isEmpty {
            urlRequest.httpBody = built.data
            if !hasContentType, let contentType = built.contentType {
                urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        // Hand the assembled request to the caller (the console log) before
        // it goes out - this is the exact bytes-on-the-wire shape.
        onRequest?(urlRequest)

        let start = Date()
        let outcome = try await dataWithTelemetry(for: urlRequest)
        let duration = Date().timeIntervalSince(start)

        // `allHeaderFields` is a dictionary: iterate sorted so the stored
        // header order is deterministic across runs instead of hash order.
        let headers = outcome.response.allHeaderFields.compactMap { (key, value) -> HTTPHeader? in
            guard let key = key as? String, let value = value as? String else { return nil }
            return HTTPHeader(key: key, value: value)
        }
        .sorted {
            let order = $0.key.localizedCaseInsensitiveCompare($1.key)
            return order == .orderedSame
                ? $0.value.localizedStandardCompare($1.value) == .orderedAscending
                : order == .orderedAscending
        }

        return ResponseModel(
            statusCode: outcome.response.statusCode,
            headers: headers,
            body: outcome.data,
            bodyTruncated: outcome.truncated,
            duration: duration,
            timestamp: Date(),
            mimeType: outcome.response.mimeType,
            network: Self.makeNetworkInfo(
                metrics: outcome.metrics,
                certificate: outcome.certificate
            ),
            size: Self.makeSizeInfo(
                request: urlRequest,
                response: outcome.response,
                body: outcome.data,
                metrics: outcome.metrics
            ),
            timing: Self.makeTimingInfo(metrics: outcome.metrics)
        )
    }

    // MARK: - Send + telemetry

    /// Runs the data task while the session delegate fills in task metrics
    /// and the leaf certificate. Uses an explicit task so telemetry can be
    /// keyed by `taskIdentifier`.
    ///
    /// Wrapped in a cancellation handler: without it, cancelling the calling
    /// `Task` (Stop button, closing the tab) only abandoned the continuation -
    /// the upload/download kept running to completion server-side and the
    /// socket stayed open until the resource timeout.
    private static func dataWithTelemetry(
        for urlRequest: URLRequest
    ) async throws -> Outcome {
        let box = DataTaskBox()
        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // No completion handler: the body arrives through the
                // session's data delegate, which is what lets it be capped.
                let task = session.dataTask(with: urlRequest)
                // Before `resume`, and before the handler can see it: a
                // cancellation that already arrived cancels it right here.
                box.attach(task)
                let telemetry = redirectPolicy.makeTelemetry(taskID: task.taskIdentifier)
                redirectPolicy.register(telemetry, taskID: task.taskIdentifier)
                telemetry.attach(continuation)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
        // The task can already be finished when the cancellation lands (the
        // body is in, the 500ms metrics wait is still running), and
        // `URLSessionTask.cancel()` on a completed task is a no-op - so the
        // wait would still resume with a success. Checked here instead of
        // leaving it to every caller to re-test cancellation.
        try Task.checkCancellation()
        return outcome
    }

    /// Hand-off slot between the cancellation handler and the task creation
    /// inside the continuation: cancellation can be delivered before the
    /// `URLSessionTask` exists, so the flag has to be sticky.
    private final class DataTaskBox: @unchecked Sendable {
        private let state = Mutex<(task: URLSessionDataTask?, cancelled: Bool)>((nil, false))

        func attach(_ task: URLSessionDataTask) {
            let cancelNow = state.withLock { current -> Bool in
                guard !current.cancelled else { return true }
                current.task = task
                return false
            }
            if cancelNow { task.cancel() }
        }

        func cancel() {
            let task = state.withLock { current -> URLSessionDataTask? in
                current.cancelled = true
                return current.task
            }
            task?.cancel()
        }
    }

    /// Postman-style Network panel fields from transaction metrics + trust.
    private static func makeNetworkInfo(
        metrics: URLSessionTaskMetrics?,
        certificate: CertificateSnapshot?
    ) -> NetworkInfo {
        let transaction = metrics?.transactionMetrics.last
        return NetworkInfo(
            httpVersion: transaction?.networkProtocolName.map(displayHTTPVersion),
            localAddress: transaction?.localAddress,
            remoteAddress: transaction?.remoteAddress,
            tlsProtocol: transaction?.negotiatedTLSProtocolVersion.map(displayTLSVersion),
            cipherName: transaction?.negotiatedTLSCipherSuite.map(displayCipherSuite),
            certificateCN: certificate?.subjectCN,
            issuerCN: certificate?.issuerCN,
            validUntil: certificate?.notAfter
        )
    }

    /// Request/response byte counts for the Size panel. Wire counts come
    /// from the final transaction's task metrics when they landed in time;
    /// otherwise the same bytes are estimated by re-serializing the
    /// assembled request and the received headers.
    private static func makeSizeInfo(
        request: URLRequest,
        response: HTTPURLResponse,
        body: Data,
        metrics: URLSessionTaskMetrics?
    ) -> SizeInfo {
        let transaction = metrics?.transactionMetrics.last
        return SizeInfo(
            requestHeaders: transaction.map { Int($0.countOfRequestHeaderBytesSent) }
                ?? estimateHeaderBytes(
                    line: requestLine(for: request),
                    headers: (request.allHTTPHeaderFields ?? [:]).map { ($0, $1) }
                ),
            requestBody: transaction.map { Int($0.countOfRequestBodyBytesSent) }
                ?? request.httpBody?.count ?? 0,
            responseHeaders: transaction.map { Int($0.countOfResponseHeaderBytesReceived) }
                ?? estimateHeaderBytes(
                    line: "HTTP/1.1 \(response.statusCode)",
                    headers: response.allHeaderFields.compactMap { key, value in
                        (key as? String).map { ($0, "\(value)") }
                    }
                ),
            responseBody: transaction.map { Int($0.countOfResponseBodyBytesReceived) }
                // Metrics are the only source that knows the real transferred
                // size; `body` is the capped buffer, so it would under-report
                // a truncated download as exactly the cap. `expectedContentLength`
                // is the next best thing (-1 when unknown).
                ?? max(body.count, Int(response.expectedContentLength))
        )
    }

    /// Request timing phases for the Time panel, from the final
    /// transaction's task metrics. TCP excludes the TLS handshake when one
    /// happened (connect -> secureConnection -> connectEnd), so the phases
    /// do not double-count. Returns nil when metrics did not land in time.
    private static func makeTimingInfo(metrics: URLSessionTaskMetrics?) -> TimingInfo? {
        guard let transaction = metrics?.transactionMetrics.last else { return nil }
        func interval(_ start: Date?, _ end: Date?) -> TimeInterval? {
            guard let start, let end else { return nil }
            return Swift.max(0, end.timeIntervalSince(start))
        }
        let tcp =
            transaction.secureConnectionStartDate.map { interval(transaction.connectStartDate, $0) }
            ?? interval(transaction.connectStartDate, transaction.connectEndDate)
        return TimingInfo(
            dns: interval(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            tcp: tcp,
            tls: interval(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            requestSent: interval(transaction.requestStartDate, transaction.requestEndDate),
            waiting: interval(transaction.requestEndDate, transaction.responseStartDate),
            download: interval(transaction.responseStartDate, transaction.responseEndDate)
        )
    }

    /// Request line ("GET /path?query HTTP/1.1") for the header estimate.
    private static func requestLine(for request: URLRequest) -> String {
        guard let url = request.url else { return "\(request.httpMethod ?? "GET") / HTTP/1.1" }
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query {
            target += "?\(query)"
        }
        return "\(request.httpMethod ?? "GET") \(target) HTTP/1.1"
    }

    /// Header-block byte estimate: the request/status line plus one
    /// "Key: Value" line per header, each CRLF-terminated, and the blank
    /// line that ends the block. Fallback when task metrics did not land
    /// in time.
    private static func estimateHeaderBytes(line: String, headers: [(String, String)]) -> Int {
        let lines = [line] + headers.map { "\($0.0): \($0.1)" }
        return lines.reduce(0) { $0 + $1.utf8.count + 2 } + 2
    }

    /// URLSession reports `http/1.1` / `h2` / `h3`; the panel shows `1.1`.
    private static func displayHTTPVersion(_ name: String) -> String {
        if name.hasPrefix("http/") { return String(name.dropFirst("http/".count)) }
        if name.first == "h", let number = Int(name.dropFirst()) { return String(number) }
        return name
    }

    private static func displayTLSVersion(_ version: tls_protocol_version_t) -> String {
        switch version {
        case .TLSv10: "TLSv1.0"
        case .TLSv11: "TLSv1.1"
        case .TLSv12: "TLSv1.2"
        case .TLSv13: "TLSv1.3"
        case .DTLSv10: "DTLSv1.0"
        case .DTLSv12: "DTLSv1.2"
        default: "TLS"
        }
    }

    /// IANA/OpenSSL-style cipher label (`ECDHE-RSA-AES128-GCM-SHA256`),
    /// matching what Postman shows. `tls_ciphersuite_t` is a CF_ENUM imported
    /// as a raw struct - `String(describing:)` only prints `rawValue`, so the
    /// codepoint is mapped explicitly.
    private static func displayCipherSuite(_ suite: tls_ciphersuite_t) -> String {
        switch suite.rawValue {
        case 0x000A: "RSA-3DES-EDE-CBC-SHA"
        case 0x002F: "RSA-AES128-CBC-SHA"
        case 0x0035: "RSA-AES256-CBC-SHA"
        case 0x009C: "RSA-AES128-GCM-SHA256"
        case 0x009D: "RSA-AES256-GCM-SHA384"
        case 0x003C: "RSA-AES128-CBC-SHA256"
        case 0x003D: "RSA-AES256-CBC-SHA256"
        case 0xC008: "ECDHE-ECDSA-3DES-EDE-CBC-SHA"
        case 0xC009: "ECDHE-ECDSA-AES128-CBC-SHA"
        case 0xC00A: "ECDHE-ECDSA-AES256-CBC-SHA"
        case 0xC012: "ECDHE-RSA-3DES-EDE-CBC-SHA"
        case 0xC013: "ECDHE-RSA-AES128-CBC-SHA"
        case 0xC014: "ECDHE-RSA-AES256-CBC-SHA"
        case 0xC023: "ECDHE-ECDSA-AES128-CBC-SHA256"
        case 0xC024: "ECDHE-ECDSA-AES256-CBC-SHA384"
        case 0xC027: "ECDHE-RSA-AES128-CBC-SHA256"
        case 0xC028: "ECDHE-RSA-AES256-CBC-SHA384"
        case 0xC02B: "ECDHE-ECDSA-AES128-GCM-SHA256"
        case 0xC02C: "ECDHE-ECDSA-AES256-GCM-SHA384"
        case 0xC02F: "ECDHE-RSA-AES128-GCM-SHA256"
        case 0xC030: "ECDHE-RSA-AES256-GCM-SHA384"
        case 0xCCA8: "ECDHE-RSA-CHACHA20-POLY1305"
        case 0xCCA9: "ECDHE-ECDSA-CHACHA20-POLY1305"
        case 0x1301: "TLS_AES_128_GCM_SHA256"
        case 0x1302: "TLS_AES_256_GCM_SHA384"
        case 0x1303: "TLS_CHACHA20_POLY1305_SHA256"
        default: String(format: "0x%04X", suite.rawValue)
        }
    }

    // MARK: - Body building

    private struct BuiltBody {
        let data: Data
        /// Suggested Content-Type, applied only when the user did not set one.
        let contentType: String?
    }

    /// Bodies above this are refused with a clear error instead of attempting
    /// an allocation that aborts the read.
    private static let maxFileBodySize: Int64 = 100 * 1024 * 1024

    /// Reads a body file: `~` expands like a shell, and oversized files fail
    /// with `fileTooLarge` (naming the path the user typed) rather than a
    /// misleading "file not found".
    private static func fileData(atPath path: String) throws -> Data {
        let expanded = (path as NSString).expandingTildeInPath
        let size = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.size] as? Int64
        if let size, size > maxFileBodySize {
            throw HTTPClientError.fileTooLarge(path)
        }
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw HTTPClientError.fileNotFound(path)
        }
        return data
    }

    private static func buildBody(for request: Request, variables: [String: String]) throws -> BuiltBody? {
        switch request.requestBodyType {
        case .none:
            return nil
        case .raw:
            let resolved = VariableResolver.resolve(request.bodyText, variables: variables)
            guard !resolved.isEmpty, let data = resolved.data(using: .utf8) else { return nil }
            let contentType = VariableResolver.resolve(request.bodyContentType, variables: variables)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BuiltBody(data: data, contentType: contentType.isEmpty ? nil : contentType)
        case .urlEncoded:
            let pairs = request.urlEncodedFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !pairs.isEmpty else { return nil }
            var encodedPairs: [String] = []
            for field in pairs {
                let key = VariableResolver.resolve(field.key, variables: variables)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let value = VariableResolver.resolve(field.value, variables: variables)
                encodedPairs.append("\(percentEncode(key))=\(percentEncode(value))")
            }
            guard !encodedPairs.isEmpty else { return nil }
            let encoded = encodedPairs.joined(separator: "&")
            guard let data = encoded.data(using: .utf8) else { return nil }
            return BuiltBody(data: data, contentType: "application/x-www-form-urlencoded")
        case .formData:
            let fields = request.formFields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !fields.isEmpty else { return nil }
            var parts: [MultipartForm.Part] = []
            for field in fields {
                let key = VariableResolver.resolve(field.key, variables: variables)
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if field.fieldKind == .file {
                    let path = VariableResolver.resolve(field.value, variables: variables)
                    guard !path.isEmpty else {
                        throw HTTPClientError.fileNotFound(field.key)
                    }
                    let data = try fileData(atPath: path)
                    let expanded = (path as NSString).expandingTildeInPath
                    parts.append(
                        MultipartForm.Part(
                            name: key,
                            filename: (expanded as NSString).lastPathComponent,
                            mimeType: MultipartForm.mimeType(forPath: expanded),
                            data: data
                        ))
                } else {
                    let value = VariableResolver.resolve(field.value, variables: variables)
                    parts.append(
                        MultipartForm.Part(name: key, filename: nil, mimeType: nil, data: Data(value.utf8)))
                }
            }
            guard !parts.isEmpty else { return nil }
            let boundary = MultipartForm.makeBoundary()
            return BuiltBody(
                data: MultipartForm.encode(parts: parts, boundary: boundary),
                contentType: "multipart/form-data; boundary=\(boundary)"
            )
        case .binary:
            let path = VariableResolver.resolve(request.binaryFilePath, variables: variables)
            // No file chosen: send no body (same as empty raw), instead of
            // failing the whole send with a misleading "file not found".
            guard !path.isEmpty else { return nil }
            let data = try fileData(atPath: path)
            return BuiltBody(data: data, contentType: MultipartForm.mimeType(forPath: (path as NSString).expandingTildeInPath))
        }
    }

    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
