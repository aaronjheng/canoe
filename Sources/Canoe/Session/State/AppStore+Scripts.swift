import Foundation

/// AppStore scripts: the QuickJS engine behind request-level pre-request
/// and post-response scripts (Postman's Pre-request / Tests tabs), driven
/// by the send pipeline in `AppStore+Sending`.
@MainActor
extension AppStore {
    /// Runs the pre-request phase. Throws only when the engine itself is
    /// unavailable (initialization failed) - the send aborts with an error
    /// banner; a script throwing merely aborts the phase, reported through
    /// `outcome.error`.
    /// Runs one script phase for a request - the request's own script or
    /// its collection's inherited script (Postman's inheritance chain).
    /// Throws only for engine-level failures; a script throwing is reported
    /// through `outcome.error`.
    func runScript(
        _ phase: ScriptPhase, script: String, of request: Request,
        variables: AppStore.ScriptVariables? = nil, resetsCarriedState: Bool,
        response: ResponseModel? = nil
    ) async throws -> ScriptPhaseOutcome {
        guard !script.isEmpty else { return ScriptPhaseOutcome() }
        let engine = try acquireScriptEngine()
        let requestJSON =
            ScriptSnapshots.encodeJSON(ScriptSnapshots.snapshot(for: request)) ?? "{}"
        let responseJSON =
            phase == .postResponse
            ? response.flatMap { ScriptSnapshots.encodeJSON(ScriptSnapshots.snapshot(for: $0)) }
            : nil
        return try await engine.run(
            ScriptPhaseInput(
                phase: phase,
                requestSnapshot: requestJSON,
                responseSnapshot: responseJSON,
                source: script,
                baseVariables: variables?.base ?? [:],
                scopes: variables?.scopes ?? [:],
                scopesResolved: variables?.scopesResolved ?? [:],
                resetsCarriedState: resetsCarriedState,
                resolveText: { text, variables in
                    VariableResolver.resolve(text, variables: variables)
                },
                dynamicVariable: { key in
                    DynamicVariables.value(for: key)
                }))
    }

    /// One engine per app session: runtime startup is paid once, and every
    /// run resets its own host state (fresh variables, fresh snapshots), so
    /// nothing carries over between sends. A failed initialization re-tries
    /// on the next scripted send instead of wedging permanently.
    private func acquireScriptEngine() throws -> ScriptEngine {
        if let scriptEngine { return scriptEngine }
        let engine = try ScriptEngine(sendSubRequest: Self.performSubRequest)
        scriptEngine = engine
        return engine
    }

    /// The pm.sendRequest executor: decodes the spec (Postman shape:
    /// url/method/header array/raw body), resolves `{{placeholders}}`
    /// against the send's current variable map, sends via the HTTP client,
    /// and encodes the result back as (responseJSON, errorJSON).
    private static func performSubRequest(
        _ specJSON: String, _ variablesJSON: String
    ) async -> (String, String?) {
        struct SubSpec: Codable {
            var url: String
            var method: String?
            var header: [SubHeader]?
            var body: String?
        }
        struct SubHeader: Codable {
            var key: String
            var value: String?
        }
        struct ErrorEnvelope: Codable {
            var message: String
        }

        func decodeJSON<T: Codable>(_ type: T.Type, _ json: String) -> T? {
            try? JSONDecoder().decode(type, from: Data(json.utf8))
        }

        guard let spec = decodeJSON(SubSpec.self, specJSON), !spec.url.isEmpty else {
            let err = try? JSONEncoder().encode(ErrorEnvelope(message: "pm.sendRequest: invalid request spec"))
            return ("null", err.flatMap { String(data: $0, encoding: .utf8) })
        }
        let variables = decodeJSON([String: String].self, variablesJSON) ?? [:]
        var request = Request(name: "pm.sendRequest")
        request.urlString = VariableResolver.resolve(spec.url, variables: variables)
        request.httpMethod = HTTPMethod(rawValue: (spec.method ?? "GET").uppercased()) ?? .get
        request.headers = (spec.header ?? []).compactMap { header in
            let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            return HTTPHeader(
                key: key,
                value: VariableResolver.resolve(header.value ?? "", variables: variables))
        }
        if let body = spec.body {
            request.requestBodyType = .raw
            request.bodyText = VariableResolver.resolve(body, variables: variables)
        }
        do {
            let response = try await HTTPClient.send(
                request: request, variables: variables, authorization: Authorization())
            let responseJSON = ScriptSnapshots.encodeJSON(ScriptSnapshots.snapshot(for: response))
            return (responseJSON ?? "null", nil)
        } catch {
            let err = try? JSONEncoder().encode(
                ErrorEnvelope(message: scriptFailureText(error)))
            return ("null", err.flatMap { String(data: $0, encoding: .utf8) })
        }
    }
}
