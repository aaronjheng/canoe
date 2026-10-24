import Foundation
import OSLog
import QuickJS

/// Which direction a script phase runs in. The raw value is the phase name
/// the JS side sees in `__pm_reset_phase` (and reflected in
/// `pm.info.eventName`).
enum ScriptPhase: String, Sendable {
    case preRequest = "prerequest"
    case postResponse = "postresponse"
}

/// One script phase's findings: `pm.test` outcomes, console lines, the
/// variables the script set (the overlay the send pipeline merges in), the
/// per-scope names it unset, and the message when the script itself threw
/// (a failed `pm.test` is a result row, not this).
struct ScriptPhaseOutcome: Sendable {
    var results: [ScriptTestResult] = []
    var logs: [ScriptLog] = []
    /// The variable map this send should resolve placeholders against
    /// (base scopes + script writes - unsets, tier fallback applied).
    /// Nil when no script ran.
    var finalVariables: [String: String]?
    var headerChanges: [ScriptHeaderChange] = []
    /// The per-scope writes the script made via `pm.environment.set` & co
    /// (prelude scope names as keys), and the per-scope names it unset.
    /// Cumulative carried state: every phase of a send inherits the previous
    /// ones' writes, so the LAST phase's snapshot is the send's whole
    /// picture (pre-request writes included). The send pipeline persists it
    /// to the machine-local overrides layer; `pm.variables.set` (the local
    /// overlay) is deliberately absent - it never persists.
    var scopeSets: [String: [String: String]] = [:]
    var scopeUnsets: [String: Set<String>] = [:]
    var error: String?
}

/// One `pm.request.headers.add` / `.upsert({...})` / `.remove(name)` call a
/// script made (Postman's programmatic request mutation). Applied to the
/// outgoing request after the pre-request phase; the tab's rows stay the
/// user's template. Post-response mutations are recorded but discarded -
/// the request already went out.
struct ScriptHeaderChange: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case add
        case upsert
        case remove
    }

    var kind: Kind
    var name: String
    /// Empty for `.remove`.
    var value: String
}

/// Everything one phase evaluation needs, bundled so `run` stays a
/// single-argument call.
struct ScriptPhaseInput: Sendable {
    var phase: ScriptPhase
    var requestSnapshot: String
    var responseSnapshot: String?
    var source: String
    /// The resolved merged variable view (cross-scope references resolved).
    var baseVariables: [String: String]
    /// Raw per-scope maps for the read-side scope objects.
    var scopes: [String: [String: String]]
    /// Per-scope maps with cross-scope references resolved against
    /// `baseVariables` - the tiers `pm.variables` reads and the outgoing
    /// variable map are built from these.
    var scopesResolved: [String: [String: String]]
    /// True when this phase starts a fresh send's carried state (every
    /// pre-request phase; a post-response phase whose send had no
    /// pre-request script).
    var resetsCarriedState: Bool
    /// Resolves `{{...}}` placeholders in a text against a variable map
    /// (injected: the resolver service stays out of the engine). Covers
    /// pm.variables.replaceIn and the dynamic-variable fallback.
    var resolveText: @Sendable (String, [String: String]) -> String = { text, _ in text }
    /// Postman's dynamic variables ($guid & co), resolved fresh per call.
    var dynamicVariable: @Sendable (String) -> String? = { _ in nil }
    /// Cookies matching the request URL (the pm.cookies surface), snapshot
    /// taken just before the scripts run.
    var cookies: [[String: String]] = []
}

/// The QuickJS runtime behind request-level scripts (one per app session).
/// A QuickJS runtime is single-threaded, so this actor is the confinement
/// boundary: `run` serializes every evaluation onto the actor's executor,
/// host callbacks execute inside the evaluation they serve, and the shared
/// per-run state lives in a locked `ScriptHostState` both sides can reach
/// synchronously (actor executors and host callbacks are different threads).
///
/// The engine exposes no std/os modules (quickjs-libc is not linked): a
/// script's whole world is the `pm` surface defined by `PMPrelude` plus the
/// plain ES intrinsics.
actor ScriptEngine {
    /// Watchdog per evaluation: generous for JSON round-trips and local
    /// helper work, strict enough that a runaway loop surfaces as a
    /// deadline abort instead of wedging a send forever.
    private static let evaluationTimeLimitMs: UInt64 = 5_000
    /// Heap budget for the JS object world (a script cannot grow past it -
    /// the evaluation throws, the send survives).
    private static let heapLimitBytes = 64 * 1024 * 1024
    /// JS stack budget. Conservative on purpose: evaluations run on
    /// cooperative-pool threads whose native stacks measure 512KB, and the
    /// JS limit must trip before the native stack does (JS_UpdateStackTop
    /// rebinds the overflow baseline per evaluation, so this bound is
    /// measured against the real eval thread). quickjs frames cost ~1KB
    /// each - roughly 350-400 recursion levels, plenty for test scripts.
    private static let stackLimitBytes = 384 * 1024

    private let runtime: QJSRuntime
    private let host: ScriptHostState
    /// Performs one pm.sendRequest sub-request: (specJSON, variablesJSON)
    /// -> (responseJSON, errorJSON?). Injected by the caller (the app wires
    /// it to HTTPClient); the engine never touches the network itself.
    private let sendSubRequest: @Sendable (String, String) async -> (String, String?)
    /// Serializes whole script executions: a second send's run must not
    /// interleave while the first is suspended awaiting its pm.sendRequest
    /// callbacks (beginPhase would reset the carried state out from under
    /// it). FIFO via `runWaiters`.
    private var runActive = false
    private var runWaiters: [CheckedContinuation<Void, Never>] = []
    /// One continuation per suspended run waiting for sub-request
    /// callbacks; resumed by `completeSendRequest` after each delivery.
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        sendSubRequest: @escaping @Sendable (String, String) async -> (String, String?)
    ) throws {
        self.sendSubRequest = sendSubRequest
        let host = ScriptHostState()
        self.host = host
        let runtime = try QJSRuntime(
            maxHeapBytes: Self.heapLimitBytes, maxStackBytes: Self.stackLimitBytes)
        try Self.registerHostFunctions(into: runtime, host: host)
        self.runtime = runtime
    }

    /// Runs one phase: installs the host snapshots + base variables, loads a
    /// fresh `pm` environment, and evaluates the script under the watchdog.
    /// Throws only for engine-level failures (initialization, prelude, the
    /// results handshake); a script throwing is fine - everything recorded
    /// before the throw survives, reported through `outcome.error`.
    func run(_ input: ScriptPhaseInput) async throws -> ScriptPhaseOutcome {
        // Whole-execution serialization (see `runWaiters`).
        while runActive {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                if !runActive {
                    cont.resume()
                    return
                }
                runWaiters.append(cont)
            }
        }
        runActive = true
        defer {
            runActive = false
            if !runWaiters.isEmpty { runWaiters.removeFirst().resume() }
        }
        var outcome = ScriptPhaseOutcome()
        host.beginPhase(input)
        // Re-evaluated per phase: a script that clobbers globals cannot
        // poison the next one, and the re-quote is a few KB of cheap JS.
        _ = try runtime.evaluate(PMPrelude.source, timeLimitMs: Self.evaluationTimeLimitMs)
        _ = try runtime.evaluate(
            "__pm_reset_phase('\(input.phase.rawValue)')", timeLimitMs: Self.evaluationTimeLimitMs)
        do {
            // Top-level `let`/`const`/`class` in a script create lexical
            // bindings that persist across evaluations on this runtime: a
            // second send of the same script would die on redeclaration.
            // Every script runs in a fresh function scope instead (Postman's
            // sandbox semantics - scripts never leak globals). The closing
            // brace lands on its own line so a trailing `// comment` cannot
            // swallow it; sharing the first line keeps stack-trace line
            // numbers aligned with the editor.
            let wrapped = "(function(){" + input.source + "\n})()"
            _ = try runtime.evaluate(wrapped, timeLimitMs: Self.evaluationTimeLimitMs)
        } catch let error as QJSError {
            outcome.error = error.message
        }
        // pm.sendRequest: the script registered sub-requests + callbacks.
        // Kick each spec through the injected sender (off the engine), then
        // wait until every callback has been delivered - Postman waits for
        // pm.sendRequest callbacks before the send/handshake completes.
        // While this run suspends, `runActive` keeps other runs queued.
        let pendingStarts = host.drainPendingStarts()
        if !pendingStarts.isEmpty {
            let variablesJSON =
                (try? JSONEncoder().encode(host.finalVariables()))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            for (id, specJSON) in pendingStarts {
                let sender = sendSubRequest
                Task.detached { [weak self] in
                    let (responseJSON, errorJSON) = await sender(specJSON, variablesJSON)
                    await self?.completeSendRequest(
                        id: id, errorJSON: errorJSON, responseJSON: responseJSON)
                }
            }
            while host.livePendingSendRequestCount > 0 {
                await waitForOneSendCompletion()
            }
        }
        // Everything recorded before a throwing statement still counts, so
        // results are collected regardless (and the handshake runs outside
        // the aborted script's watchdog).
        let handshake = try runtime.evaluate(
            "__pm_results_json()", timeLimitMs: Self.evaluationTimeLimitMs)
        if case .string(let json) = handshake {
            let envelope = try? JSONDecoder().decode(
                ScriptResultsEnvelope.self, from: Data(json.utf8))
            outcome.results = envelope?.results ?? []
            outcome.logs = envelope?.logs ?? []
        }

        outcome.headerChanges = host.headerChangesSnapshot
        outcome.scopeSets = host.scopeOverlaysSnapshot
        outcome.scopeUnsets = host.scopeUnsetsSnapshot
        return outcome
    }

    /// Decoded `__pm_results_json()` payload; both lists tolerate absence.
    private struct ScriptResultsEnvelope: Codable {
        var results: [ScriptTestResult]?
        var logs: [ScriptLog]?
    }

    /// Delivers one pm.sendRequest callback: invokes the JS callback with
    /// (err, response), then releases one waiter. Callback throws are
    /// console.error'd inside the delivery helper (they land in the logs).
    private func completeSendRequest(
        id: Int, errorJSON: String?, responseJSON: String?
    ) {
        // The payload travels as a JS object literal (JSON is a subset of
        // JS expressions) - embedding it in a string literal would break on
        // the JSON's own quote escapes. The delivery helper then consumes
        // it and invokes the registered callback.
        let payload =
            "globalThis.__pm_delivery = { id: \(id), error: \(errorJSON ?? "null"),"
            + " response: \(responseJSON ?? "null") };"
        do {
            _ = try runtime.evaluate(payload, timeLimitMs: Self.evaluationTimeLimitMs)
            _ = try runtime.evaluate(
                "__pm_deliver_send_response()", timeLimitMs: Self.evaluationTimeLimitMs)
        } catch {
            AppLogger.error("pm.sendRequest delivery failed: \(error)", category: "Scripts")
        }
        host.finishSendRequest()
        if !sendWaiters.isEmpty { sendWaiters.removeFirst().resume() }
    }

    /// Suspends until one sub-request callback has been delivered (no-op
    /// when none are pending; re-checks after suspension against
    /// interleaved completions).
    private func waitForOneSendCompletion() async {
        if host.livePendingSendRequestCount == 0 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if host.livePendingSendRequestCount == 0 {
                cont.resume()
                return
            }
            sendWaiters.append(cont)
        }
    }
}

/// Human-readable text for a thrown script-phase failure: QuickJS errors
/// carry the JS message and stack in dedicated fields, which
/// `localizedDescription` flattens into a generic description (the send
/// banner would show "QuickJS.QJSError error 1." with the real cause lost).
func scriptFailureText(_ error: Error) -> String {
    if let jsError = error as? QJSError {
        var text = jsError.message
        if let stack = jsError.stack, !stack.isEmpty {
            text += "\n" + stack
        }
        return text
    }
    return error.localizedDescription
}

// MARK: - Host bridge

extension ScriptEngine {
    /// The synchronous core the `pm` surface calls from JS. Keep these
    /// tiny: they run inside the evaluation, hand out strings, and take
    /// everything else from the locked host state.
    private static func registerHostFunctions(
        into runtime: QJSRuntime, host: ScriptHostState
    ) throws {
        try runtime.define("__pm_vars_get", argumentCount: 1) { arguments in
            guard case .string(let name) = arguments.first else { return .null }
            return host.value(forKey: name).map(QJSValueKind.string) ?? .null
        }
        try runtime.define("__pm_vars_set", argumentCount: 2) { arguments in
            guard
                case .string(let name) = arguments.first,
                case .string(let value) = arguments.dropFirst().first
            else { return .undefined }
            host.setValue(value, forKey: name)
            return .undefined
        }
        try runtime.define("__pm_vars_unset", argumentCount: 1) { arguments in
            if case .string(let name) = arguments.first {
                host.unset(name)
            }
            return .undefined
        }
        try runtime.define("__pm_vars_json", argumentCount: 0) { _ in
            .string(
                (try? JSONEncoder().encode(host.finalVariables()))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
        }
        try runtime.define("__pm_scope_get", argumentCount: 2) { arguments in
            guard case .string(let scope) = arguments.first,
                case .string(let name) = arguments.dropFirst().first
            else { return .undefined }
            return host.scopeValue(kind: scope, forKey: name).map(QJSValueKind.string) ?? .undefined
        }
        try runtime.define("__pm_scope_set", argumentCount: 3) { arguments in
            guard case .string(let scope) = arguments.first,
                case .string(let name) = arguments.dropFirst().first,
                case .string(let value) = arguments.dropFirst(2).first
            else { return .undefined }
            host.setScopeValue(kind: scope, forKey: name, value: value)
            return .undefined
        }
        try runtime.define("__pm_scope_unset", argumentCount: 2) { arguments in
            guard case .string(let scope) = arguments.first,
                case .string(let name) = arguments.dropFirst().first
            else { return .undefined }
            host.unsetScopeValue(kind: scope, forKey: name)
            return .undefined
        }
        try runtime.define("__pm_scope_json", argumentCount: 1) { arguments in
            guard case .string(let scope) = arguments.first,
                let json = host.scopeJSON(kind: scope)
            else { return .undefined }
            return .string(json)
        }
        try runtime.define("__pm_cookies_json", argumentCount: 0) { _ in
            .string(
                (try? JSONEncoder().encode(host.cookies))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
        }
        try runtime.define("__pm_resolve", argumentCount: 1) { arguments in
            guard case .string(let text) = arguments.first else { return .undefined }
            return .string(host.resolve(text))
        }
        try runtime.define("__pm_send_request_begin", argumentCount: 2) { arguments in
            let id: Int
            switch arguments.first {
            case .int(let value): id = Int(value)
            case .float(let value): id = Int(value)
            default: return .undefined
            }
            guard case .string(let specJSON) = arguments.dropFirst().first
            else { return .undefined }
            host.beginSendRequest(id: id, specJSON: specJSON)
            return .undefined
        }
        try runtime.define("__pm_request_snapshot", argumentCount: 0) { _ in
            host.requestSnapshot.map(QJSValueKind.string) ?? .null
        }
        try runtime.define("__pm_response_snapshot", argumentCount: 0) { _ in
            host.responseSnapshot.map(QJSValueKind.string) ?? .null
        }
        try runtime.define("__pm_request_header_add", argumentCount: 2) { arguments in
            guard case .string(let name) = arguments.first,
                case .string(let value) = arguments.dropFirst().first
            else { return .undefined }
            host.recordHeader(.init(kind: .add, name: name, value: value))
            return .undefined
        }
        try runtime.define("__pm_request_header_upsert", argumentCount: 2) { arguments in
            guard case .string(let name) = arguments.first,
                case .string(let value) = arguments.dropFirst().first
            else { return .undefined }
            host.recordHeader(.init(kind: .upsert, name: name, value: value))
            return .undefined
        }
        try runtime.define("__pm_request_header_remove", argumentCount: 1) { arguments in
            guard case .string(let name) = arguments.first else { return .undefined }
            host.recordHeader(.init(kind: .remove, name: name, value: ""))
            return .undefined
        }
    }
}

/// Per-run state the host functions serve synchronously from inside the
/// evaluation: the base variables this send resolved, the per-scope maps
/// for the read-side scope objects, the script's write overlays, and the
/// request/response snapshot JSON. Locked, because `beginPhase` /
/// snapshot accessors run from the actor executor while the host functions
/// run inside the JS evaluation.
///
/// Variable resolution mirrors Postman's scope precedence: the local
/// overlay (`pm.variables.set`) wins, then per-scope script writes
/// (`pm.environment.set` ...) in environment > collection > workspace
/// order, then the resolved base scopes. `pm.variables.unset` clears only
/// the local entry (lower scopes still resolve, like Postman); a scope
/// unset masks that scope's contribution.
private final class ScriptHostState: @unchecked Sendable {
    private let lock = NSLock()
    private var baseVariables: [String: String] = [:]
    private var scopes: [String: [String: String]] = [:]
    private var scopesResolved: [String: [String: String]] = [:]
    private var resolveText: @Sendable (String, [String: String]) -> String = { text, _ in text }
    private var dynamicVariable: @Sendable (String) -> String? = { _ in nil }
    var cookies: [[String: String]] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cookiesStorage
        }
        set {
            lock.lock()
            cookiesStorage = newValue
            lock.unlock()
        }
    }
    private var cookiesStorage: [[String: String]] = []
    private var overlay: [String: String] = [:]
    private var scopeOverlays: [String: [String: String]] = [:]
    private var scopeUnsets: [String: Set<String>] = [:]
    private var headerChanges: [ScriptHeaderChange] = []
    /// pm.sendRequest registrations made by the running script, drained by
    /// the engine after the script evaluation returns.
    private var pendingStarts: [(id: Int, specJSON: String)] = []
    private var pendingSendRequestCount = 0

    /// The live sub-request count (the engine's wait loop reads it).
    var livePendingSendRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingSendRequestCount
    }
    private var requestSnapshotJSON: String?
    private var responseSnapshotJSON: String?

    /// The scope tiers in resolution precedence, highest first.
    private static let scopeTierOrder = ["environment", "collection", "workspace"]

    func beginPhase(_ input: ScriptPhaseInput) {
        lock.lock()
        defer { lock.unlock() }
        baseVariables = input.baseVariables
        scopes = input.scopes
        scopesResolved = input.scopesResolved
        resolveText = input.resolveText
        dynamicVariable = input.dynamicVariable
        cookiesStorage = input.cookies
        requestSnapshotJSON = input.requestSnapshot
        responseSnapshotJSON = input.responseSnapshot
        // A pre-request phase always starts a fresh send's carried state; a
        // post-response phase does too when its send had no pre-request
        // script (otherwise it inherits THIS send's pre-request writes).
        if input.phase == .preRequest || input.resetsCarriedState {
            overlay = [:]
            scopeOverlays = [:]
            scopeUnsets = [:]
            headerChanges = []
            pendingStarts = []
            pendingSendRequestCount = 0
        }
    }

    /// The variable a script reads: local overlay first, then per-scope
    /// script writes (environment > collection > workspace), then the
    /// resolved base - with a scope unset masking the base entry for that
    /// name (an approximation: Postman would still resolve lower scopes
    /// that carry the same name).
    func value(forKey rawName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // Tolerate the braced form: pm.variables.get("{{$randomInt}}").
        let name =
            rawName.hasPrefix("{{") && rawName.hasSuffix("}}")
            ? String(rawName.dropFirst(2).dropLast(2)) : rawName
        if let local = overlay[name] { return local }
        for kind in Self.scopeTierOrder {
            if let written = scopeOverlays[kind]?[name] { return written }
            if scopeUnsets[kind]?.contains(name) == true { continue }
            if let stored = scopesResolved[kind]?[name] {
                return stored
            }
        }
        return baseVariables[name] ?? dynamicVariable(name)
    }

    /// `pm.variables.set` - the local overlay, the highest tier.
    func setValue(_ value: String, forKey name: String) {
        lock.lock()
        defer { lock.unlock() }
        overlay[name] = value
    }

    /// `pm.variables.unset` - clears the local entry only; lower scopes
    /// still resolve (Postman's VariableScope.unset semantics).
    func unset(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        overlay.removeValue(forKey: name)
    }

    /// `pm.<scope>.set` - a per-scope write that overrides that scope's
    /// stored value for this send. The send pipeline persists the final
    /// writes to the machine-local overrides layer (see `VariableOverrides`);
    /// the vault files themselves are never written by scripts.
    func setScopeValue(kind: String, forKey name: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        scopeOverlays[kind, default: [:]][name] = value
        scopeUnsets[kind, default: []].remove(name)
    }

    /// `pm.<scope>.unset` - masks that scope's contribution to this send.
    func unsetScopeValue(kind: String, forKey name: String) {
        lock.lock()
        defer { lock.unlock() }
        scopeOverlays[kind]?.removeValue(forKey: name)
        scopeUnsets[kind, default: []].insert(name)
    }

    /// One scope's current value as the scope object reads it: its script
    /// writes first, then the stored map minus its unsets.
    func scopeValue(kind: String, forKey name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let written = scopeOverlays[kind]?[name] { return written }
        if scopeUnsets[kind]?.contains(name) == true { return nil }
        return scopes[kind]?[name]
    }

    /// One scope's full map as JSON (the scope object's toObject()).
    func scopeJSON(kind: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var map = scopes[kind] ?? [:]
        for (name, value) in scopeOverlays[kind] ?? [:] { map[name] = value }
        for name in scopeUnsets[kind] ?? [] { map.removeValue(forKey: name) }
        return (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The variable map the send pipeline should resolve placeholders
    /// against: resolved per-tier maps merged low to high
    /// (workspace -> collection -> environment), each tier's script writes
    /// applied, each tier's unset masking that tier's contribution with
    /// fallback to the highest lower tier still carrying the name, and the
    /// local overlay (`pm.variables.set`) last.
    func finalVariables() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var final: [String: String] = [:]
        for kind in ["workspace", "collection", "environment"] {
            for (name, value) in scopesResolved[kind] ?? [:] { final[name] = value }
            for (name, value) in scopeOverlays[kind] ?? [:] { final[name] = value }
        }
        for kind in Self.scopeTierOrder {
            for name in scopeUnsets[kind] ?? [] {
                if let fallback = fallbackValue(below: kind, name: name) {
                    final[name] = fallback
                } else {
                    final.removeValue(forKey: name)
                }
            }
        }
        for (name, value) in overlay { final[name] = value }
        return final
    }

    /// The value a scope unset falls back to: the highest lower-precedence
    /// tier (its script write, or its resolved stored value) still carrying
    /// the name.
    private func fallbackValue(below kind: String, name: String) -> String? {
        let lowerTiers = Self.scopeTierOrder.drop(while: { $0 != kind }).dropFirst()
        for tier in lowerTiers {
            if let written = scopeOverlays[tier]?[name] { return written }
            if let stored = scopesResolved[tier]?[name] { return stored }
        }
        return nil
    }

    /// The local overlay copy the send pipeline merges after the phase.
    /// Resolves `{{...}}` placeholders in a text against the CURRENT
    /// variable state (base scopes + script writes - unsets): the engine's
    /// face of `pm.variables.replaceIn`. The resolver function is injected
    /// from the caller (see ScriptPhaseInput).
    func resolve(_ text: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        var state: [String: String] = [:]
        for kind in ["workspace", "collection", "environment"] {
            for (name, value) in scopesResolved[kind] ?? [:] { state[name] = value }
        }
        for (_, map) in scopeOverlays {
            for (name, value) in map { state[name] = value }
        }
        for (name, value) in overlay { state[name] = value }
        for (_, names) in scopeUnsets {
            for name in names { state.removeValue(forKey: name) }
        }
        return resolveText(text, state)
    }

    var overlaySnapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return overlay
    }

    /// The per-scope unsets the send pipeline applies while building the
    /// resolved variable map.
    var scopeUnsetsSnapshot: [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return scopeUnsets.filter { !$0.value.isEmpty }
    }

    /// The per-scope script writes (cumulative carried state) for the
    /// phase outcome - the raw material the send pipeline persists.
    var scopeOverlaysSnapshot: [String: [String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return scopeOverlays.filter { !$0.value.isEmpty }
    }

    /// The header mutations this run recorded (pre-request ops are the ones
    /// the send pipeline applies).
    var headerChangesSnapshot: [ScriptHeaderChange] {
        lock.lock()
        defer { lock.unlock() }
        return headerChanges
    }

    func recordHeader(_ change: ScriptHeaderChange) {
        lock.lock()
        defer { lock.unlock() }
        headerChanges.append(change)
    }

    /// `pm.sendRequest` registration from the running script: the spec is
    /// queued for the engine to kick after evaluation, the count keeps the
    /// run waiting until every callback has been delivered.
    func beginSendRequest(id: Int, specJSON: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingStarts.append((id, specJSON))
        pendingSendRequestCount += 1
    }

    /// Marks one sub-request delivered (its callback has run).
    func finishSendRequest() {
        lock.lock()
        defer { lock.unlock() }
        pendingSendRequestCount = max(0, pendingSendRequestCount - 1)
    }

    /// The queued sub-request specs; empties the queue.
    func drainPendingStarts() -> [(id: Int, specJSON: String)] {
        lock.lock()
        defer { lock.unlock() }
        let drained = pendingStarts
        pendingStarts = []
        return drained
    }

    var requestSnapshot: String? {
        lock.lock()
        defer { lock.unlock() }
        return requestSnapshotJSON
    }

    var responseSnapshot: String? {
        lock.lock()
        defer { lock.unlock() }
        return responseSnapshotJSON
    }
}
