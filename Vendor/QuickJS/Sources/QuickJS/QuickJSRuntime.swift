import Foundation
import Synchronization
import QuickJSEngine

/// One QuickJS virtual machine (runtime + single context): evaluates
/// Classic/Module scripts, registers host functions, drains promise jobs,
/// and enforces time/memory/stack budgets for user-authored scripts.
///
/// Confinement contract: a QuickJS runtime is single-threaded, so this type
/// is deliberately **not** Sendable. Confine all calls to one serial
/// executor; the Scripts layer provides its own actor/queue orchestration
/// on top of this raw facade.
///
/// Ownership follows QuickJS-NG's documented rules: values returned by
/// JS_ C functions are owned by the caller (freed here), host callbacks
/// borrow their arguments, and property setters take their stored value.
public final class QJSRuntime {
    private let runtime: OpaquePointer
    private let context: OpaquePointer
    private let interruptState = InterruptState()
    private var hostKeys: [Int32] = []

    /// Process-wide host-function dispatch table. `JS_NewCFunctionData` can
    /// only carry a small JS value, so each Swift handler hides behind an int
    /// key; keys are process-unique so several runtimes coexist.
    private static let hostTable = HostTable()

    public init(maxHeapBytes: Int? = nil, maxStackBytes: Int? = nil) throws {
        guard let runtime = JS_NewRuntime() else {
            throw QJSError(message: "JS_NewRuntime failed", stack: nil)
        }
        guard let context = JS_NewContext(runtime) else {
            JS_FreeRuntime(runtime)
            throw QJSError(message: "JS_NewContext failed", stack: nil)
        }
        self.runtime = runtime
        self.context = context
        if let maxHeapBytes {
            JS_SetMemoryLimit(runtime, maxHeapBytes)
        }
        if let maxStackBytes {
            JS_SetMaxStackSize(runtime, maxStackBytes)
        }
        JS_SetInterruptHandler(
            runtime,
            { _, opaque in
                guard let opaque else { return 0 }
                let state = Unmanaged<InterruptState>.fromOpaque(opaque)
                    .takeUnretainedValue()
                if state.cancelled.load(ordering: .relaxed) { return 1 }
                let deadline = state.deadline.load(ordering: .relaxed)
                if deadline != 0
                    && DispatchTime.now().uptimeNanoseconds >= deadline {
                    return 1
                }
                return 0
            },
            Unmanaged.passUnretained(interruptState).toOpaque())
    }

    deinit {
        JS_FreeContext(context)
        JS_FreeRuntime(runtime)
        for key in hostKeys {
            Self.hostTable.remove(key)
        }
    }

    // MARK: - Evaluation

    /// Evaluates a Classic script (or an ES module when `isModule`; note
    /// module imports need a module loader the v0 facade does not provide).
    /// `timeLimitMs` arms a watchdog for this evaluation only: once the
    /// deadline passes, the engine interrupts the script mid-loop and
    /// evaluation throws.
    ///
    /// `requestInterrupt()` applies to the evaluation in flight, or to the
    /// next one if none is running (a call made while idle aborts that next
    /// evaluation on its first checkpoint).
    public func evaluate(
        _ source: String,
        isModule: Bool = false,
        timeLimitMs: UInt64? = nil
    ) throws -> QJSValueKind {
        if let timeLimitMs {
            interruptState.deadline.store(
                DispatchTime.now().uptimeNanoseconds + timeLimitMs * 1_000_000,
                ordering: .relaxed)
        } else {
            interruptState.deadline.store(0, ordering: .relaxed)
        }
        // Each evaluation may land on a different cooperative-pool thread,
        // while the stack-overflow baseline was bound to whatever thread
        // created the runtime. Without this rebind the cross-thread check
        // never fires and a deep user-script recursion faults the process
        // instead of throwing a catchable InternalError.
        JS_UpdateStackTop(runtime)
        defer {
            // The request is consumed by the evaluation it applies to
            // (whether it fires or not), so interrupts never leak into
            // later scripts.
            interruptState.deadline.store(0, ordering: .relaxed)
            interruptState.cancelled.store(false, ordering: .relaxed)
        }

        // utf8CString includes the trailing NUL; JS_Eval wants the length
        // without it.
        let bytes = Array(source.utf8CString)
        return try bytes.withUnsafeBufferPointer { buffer throws in
            let length = buffer.count > 0 ? buffer.count - 1 : 0
            // JS_EVAL_TYPE_GLOBAL (0) / JS_EVAL_TYPE_MODULE (1) - the flag
            // macros are not importable from Swift, these constants mirror
            // quickjs.h.
            let flags: Int32 = isModule ? 1 : 0
            var filename = "<canoe>"
            return try filename.withCString { name in
                let value = JS_Eval(context, buffer.baseAddress, length, name, flags)
                if JS_HasException(context) {
                    throw takeException()
                }
                defer { qjs_free_value(context, value) }
                return Self.kind(of: value, in: context)
            }
        }
    }

    /// Interrupts a running evaluation (see `evaluate` for the semantics).
    public func requestInterrupt() {
        interruptState.cancelled.store(true, ordering: .relaxed)
    }

    // MARK: - Budgets

    public func setMemoryLimit(bytes: Int) {
        JS_SetMemoryLimit(runtime, bytes)
    }

    public func setStackLimit(bytes: Int) {
        JS_SetMaxStackSize(runtime, bytes)
    }

    public func runGC() {
        JS_RunGC(runtime)
    }

    // MARK: - Jobs (the asynchronous pivot for pm.sendRequest)

    /// Drains the pending promise-job queue until it is empty; throws if a
    /// job itself threw. The engine has no event loop of its own - callers
    /// schedule this from their own scheduler (timers hit the same queue).
    public func drainPendingJobs() throws {
        var executed: Int32 = 0
        repeat {
            var contextPointer: OpaquePointer? = nil
            executed = JS_ExecutePendingJob(runtime, &contextPointer)
            if executed < 0 {
                throw takeException()
            }
        } while executed > 0
    }

    // MARK: - Host bridge

    /// Registers a global function implemented in Swift. Arguments arrive as
    /// `QJSValueKind`; the returned kind is converted back into JS. Throwing
    /// surfaces as a TypeError and fails the calling script.
    public func define(
        _ name: String,
        argumentCount: Int32 = 0,
        handler: @escaping @Sendable ([QJSValueKind]) throws -> QJSValueKind
    ) throws {
        let key = Self.hostTable.register(handler)
        func releaseKey() {
            Self.hostTable.remove(key)
        }

        let outcome: Result<Void, QJSError> = name.withCString { nameBuffer in
            let function = qjs_new_host_function(
                context,
                { ctx, thisValue, argc, argv, magic, funcData in
                    QJSRuntime.dispatchHostFunction(
                        ctx: ctx, argc: argc, argv: argv, funcData: funcData)
                },
                nameBuffer, argumentCount, key)
            var global = JS_GetGlobalObject(context)
            defer { qjs_free_value(context, global) }
            // JS_SetPropertyStr takes ownership of the function value on
            // success; free it here on failure.
            let propertyStatus = JS_SetPropertyStr(context, global, nameBuffer, function)
            if propertyStatus >= 0 {
                hostKeys.append(key)
                return .success(())
            }
            releaseKey()
            qjs_free_value(context, function)
            return .failure(takeException())
        }
        if case .failure(let error) = outcome {
            throw error
        }
    }

    /// Calls a global function by name - the pivot for resolving promises
    /// from the Swift side after async work outside the engine (the
    /// `pm.sendRequest` flow lands on this).
    public func invokeGlobal(
        _ name: String,
        arguments: [QJSValueKind] = []
    ) throws -> QJSValueKind {
        var global = JS_GetGlobalObject(context)
        defer { qjs_free_value(context, global) }
        let function = name.withCString {
            JS_GetPropertyStr(context, global, $0)
        }
        defer { qjs_free_value(context, function) }

        var argumentsBuffer = try arguments.map {
            try Self.materialize($0, in: context)
        }
        defer {
            for owned in argumentsBuffer {
                qjs_free_value(context, owned)
            }
        }
        let undefined = qjs_undefined()
        let result = JS_Call(
            context, function, undefined, Int32(argumentsBuffer.count), &argumentsBuffer)
        if JS_HasException(context) {
            throw takeException()
        }
        defer { qjs_free_value(context, result) }
        return Self.kind(of: result, in: context)
    }

    // MARK: - Dispatch across the C boundary

    private static func dispatchHostFunction(
        ctx: OpaquePointer?,
        argc: Int32,
        argv: UnsafeMutablePointer<JSValue>?,
        funcData: UnsafeMutablePointer<JSValue>?
    ) -> JSValue {
        guard let funcData else {
            return qjs_throw_type_error(ctx, "host function without dispatch payload")
        }
        let key = qjs_host_key(funcData)
        guard let handler = hostTable.handler(forKey: key) else {
            return qjs_throw_type_error(ctx, "unknown host function key \(key)")
        }
        var argumentKinds: [QJSValueKind] = []
        argumentKinds.reserveCapacity(max(Int(argc), 0))
        for index in 0..<max(Int(argc), 0) {
            guard let argv else { break }
            argumentKinds.append(kind(of: argv[index], in: ctx))
        }
        do {
            let returnedKind = try handler(argumentKinds)
            return try materialize(returnedKind, in: ctx)
        } catch {
            let text = "host error: \(String(describing: error))"
            return text.withCString { pointer in
                qjs_throw_type_error(ctx, pointer)
            }
        }
    }

    /// Understands enough of tags to read plain values; every union/macro
    /// access happens inside the C shims.
    private static func kind(of value: JSValue, in context: OpaquePointer?) -> QJSValueKind {
        // The C kind constants import as Int, the shim returns an int;
        // widen at the switch head so the patterns stay nameable.
        switch Int(qjs_kind_of(value)) {
        case QJSKindUndefined: return .undefined
        case QJSKindNull: return .null
        case QJSKindBoolean: return .boolean(qjs_int_value(value) != 0)
        case QJSKindInt: return .int(Int32(truncatingIfNeeded: qjs_int_value(value)))
        case QJSKindFloat: return .float(qjs_float_value(value))
        case QJSKindString:
            return .string(string(of: value, in: context) ?? "")
        case QJSKindObject: return .object
        case QJSKindBigInt: return .bigInt
        default: return .other
        }
    }

    private static func materialize(
        _ kind: QJSValueKind, in context: OpaquePointer?
    ) throws -> JSValue {
        switch kind {
        case .undefined: return qjs_undefined()
        case .null: return qjs_null()
        case .boolean(let value): return qjs_bool(value ? 1 : 0)
        case .int(let value): return qjs_int32(value)
        case .float(let value): return qjs_float64(value)
        case .string(let text):
            let bytes = Array(text.utf8)
            if bytes.isEmpty {
                return "".withCString { pointer in
                    qjs_new_string_len(context, pointer, 0)
                }
            }
            return bytes.withUnsafeBufferPointer { buffer in
                qjs_new_string_len(context, buffer.baseAddress, buffer.count)
            }
        case .object, .bigInt, .other:
            throw QJSError(message: "cannot materialize \(kind) into a JS value", stack: nil)
        }
    }

    private static func string(of value: JSValue, in context: OpaquePointer?) -> String? {
        guard let raw = qjs_to_c_string(context, value, nil) else { return nil }
        defer { qjs_free_c_string(context, raw) }
        return String(cString: raw)
    }

    private func takeException() -> QJSError {
        let exception = JS_GetException(context)
        defer { qjs_free_value(context, exception) }
        // Degenerate exception values (e.g. an out-of-memory throw that
        // could not even allocate its Error object) surface as null.
        let degenerate = Self.kind(of: exception, in: context)
        let message: String
        switch degenerate {
        case .null, .undefined: message = "<exception without a value>"
        default: message = Self.string(of: exception, in: context) ?? "<unknown exception>"
        }
        let stackValue = JS_GetPropertyStr(context, exception, "stack")
        defer { qjs_free_value(context, stackValue) }
        let stack = Self.string(of: stackValue, in: context)
        return QJSError(message: message, stack: stack)
    }
}

/// Arc-less pieces of state the C interrupt handler reads on the engine
/// thread; atomics because cancellation always comes from another thread.
private final class InterruptState {
    let deadline = Atomic<UInt64>(0)
    let cancelled = Atomic<Bool>(false)
}

private typealias HostHandler = @Sendable ([QJSValueKind]) throws -> QJSValueKind

/// Lock-protected ownership (not execution): registration happens on the
/// thread that owns the runtime; entries are removed per-runtime in deinit.
private final class HostTable: @unchecked Sendable {
    private let lock = NSLock()
    private var nextKey: Int32 = 1
    private var handlers: [Int32: HostHandler] = [:]

    func register(_ handler: @escaping HostHandler) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let key = nextKey
        nextKey &+= 1
        handlers[key] = handler
        return key
    }

    func remove(_ key: Int32) {
        lock.lock()
        defer { lock.unlock() }
        handlers[key] = nil
    }

    func handler(forKey key: Int32) -> HostHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[key]
    }
}
