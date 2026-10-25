import Foundation

/// Native JavaScript formatting behind the Scripts editor's ⌘⇧F: the oxc
/// project's `oxfmt` backend, statically linked into the app from
/// `Vendor/Oxfmt` (see BUILD-INFO.md - no JavaScript engine is involved).
/// The shim crate exports this one C ABI pair, and the bindings below pin
/// its exact shape for Swift. Input and output are plain UTF-8 text; a
/// script that does not parse throws instead of being guessed at, so the
/// editor keeps the user's text untouched.
enum ScriptFormatter {
    /// The parser refused the script.
    struct ScriptFormatError: Error, Sendable {
        /// The diagnostic, e.g. "Unexpected token".
        var message: String
    }

    /// Mirror of the shim's C-repr `CanoeBuffer`; field order matters.
    /// `data` is raw UTF-8, not NUL-terminated; `len` is exact in bytes.
    private struct CanoeBuffer {
        var data: UnsafeMutableRawPointer?
        var len: Int
    }

    /// Mirror of the shim's C-repr `CanoeFormatResult`; field order
    /// matters. The shim zeroes both buffers first, so they are readable
    /// on every status.
    private struct CanoeFormatResult {
        var out: CanoeBuffer
        var err: CanoeBuffer
    }

    /// Formats JavaScript source text. Returns:
    /// - `0` and fills `result.out` with the formatted code,
    /// - `1` and fills `result.err` with a diagnostic message when the
    ///   input did not parse (the app surfaces it and keeps the text),
    /// - `2` when the input is not valid UTF-8,
    /// - `-1` on usage errors (null input or result pointer).
    ///
    /// Lengths are `usize` (LP64, matching Swift's `Int`); buffers are
    /// released via `canoeStrFree` with the exact pointer/length pair
    /// handed out.
    @_silgen_name("canoe_format_js")
    private static func canoeFormatJS(
        _ input: UnsafePointer<UInt8>?,
        _ inputLen: Int,
        _ result: UnsafeMutablePointer<CanoeFormatResult>
    ) -> Int32

    /// Releases a buffer handed out by `canoeFormatJS`; same pointer and
    /// length it returned, both required.
    @_silgen_name("canoe_str_free")
    private static func canoeStrFree(_ ptr: UnsafeMutableRawPointer?, _ len: Int)

    /// Formats `source`. Returns `nil` when the script is already
    /// formatted - a no-op that leaves the editor's undo stack clean
    /// instead of pushing a zero-diff entry. Throws `ScriptFormatError`
    /// when the input does not parse.
    static func format(_ source: String) throws -> String? {
        if source.isEmpty { return nil }
        // The engine takes UTF-8 bytes and hands back UTF-8 bytes; scripts
        // are small (a few KB), so the one-shot copies are nothing.
        let utf8 = Array(source.utf8)
        return try utf8.withUnsafeBufferPointer { bytes in
            var result = CanoeFormatResult(
                out: CanoeBuffer(data: nil, len: 0),
                err: CanoeBuffer(data: nil, len: 0))
            let status = canoeFormatJS(bytes.baseAddress, bytes.count, &result)
            if status == 0 {
                defer { canoeStrFree(result.out.data, result.out.len) }
                let buffer = UnsafeRawBufferPointer(start: result.out.data, count: result.out.len)
                guard let code = String(bytes: buffer, encoding: .utf8) else {
                    throw ScriptFormatError(message: "Formatter returned invalid UTF-8")
                }
                return code == source ? nil : code
            }
            var message = "Invalid JavaScript"
            if result.err.len > 0, let errData = result.err.data {
                defer { canoeStrFree(errData, result.err.len) }
                let buffer = UnsafeRawBufferPointer(start: errData, count: result.err.len)
                message = String(bytes: buffer, encoding: .utf8) ?? message
            }
            throw ScriptFormatError(message: message)
        }
    }
}
