//! C-ABI shim exposing oxc's JavaScript formatter (the `oxfmt` backend) to
//! the Canoe macOS app as a native static library - no JavaScript runtime.

use std::os::raw::c_char;
use std::slice;

use oxc_allocator::Allocator;
use oxc_diagnostics::OxcDiagnostic;
use oxc_formatter::{JsFormatOptions, Semicolons, format};
use oxc_span::SourceType;

/// Formats JavaScript source text. Returns:
/// - `0` and fills `out_data`/`out_len` with the formatted code on success,
/// - `1` and fills `err_data`/`err_len` with a diagnostic message when the
///   input did not parse (or printing failed),
/// - `2` when the input is not valid UTF-8,
/// - `-1` on usage errors (null out pointers).
///
/// Result buffers are heap-owned strings released via `canoe_str_free(ptr,
/// len)`. They are raw UTF-8 bytes, not NUL-terminated.
pub fn format_text(source: &str) -> Result<String, String> {
    let allocator = Allocator::default();
    // Canoe pins `semi: false` (ASI style, matching how Postman scripts
    // are usually authored); everything else stays at the oxfmt defaults.
    let options = JsFormatOptions { semicolons: Semicolons::AsNeeded, ..JsFormatOptions::default() };
    let result = format(&allocator, source, SourceType::cjs(), options);
    match result {
        Ok(formatted) => formatted
            .print()
            .map(|printed| printed.into_code())
            .map_err(|error| error.to_string()),
        Err(diagnostic) => Err(diagnostic_message(&diagnostic)),
    }
}

/// One-line diagnostic with message and source span, matching how oxc prints
/// parse errors.
fn diagnostic_message(diagnostic: &OxcDiagnostic) -> String {
    diagnostic.to_string()
}

/// One handed-out UTF-8 buffer: exact length in bytes, capacity folded
/// into the allocation so `canoe_str_free` can rebuild the box.
#[repr(C)]
pub struct CanoeBuffer {
    pub data: *mut c_char,
    pub len: usize,
}

/// The two slots `canoe_format_js` fills. The shim zeroes both first, so
/// the caller can read them on every status.
#[repr(C)]
pub struct CanoeFormatResult {
    pub out: CanoeBuffer,
    pub err: CanoeBuffer,
}

/// Boxed-slice transfer: length is exact, capacity is folded into the box
/// so the free side can rebuild it with a plain `Box::from_raw`.
fn leak_buffer(bytes: &[u8]) -> CanoeBuffer {
    let boxed: Box<[u8]> = bytes.to_vec().into_boxed_slice();
    let len = boxed.len();
    CanoeBuffer {
        data: Box::into_raw(boxed).cast::<c_char>(),
        len,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn canoe_format_js(
    input: *const c_char,
    input_len: usize,
    result: *mut CanoeFormatResult,
) -> i32 {
    if result.is_null() {
        return -1;
    }
    unsafe {
        (*result).out = CanoeBuffer { data: std::ptr::null_mut(), len: 0 };
        (*result).err = CanoeBuffer { data: std::ptr::null_mut(), len: 0 };
        if input.is_null() {
            return -1;
        }
        let bytes = slice::from_raw_parts(input.cast::<u8>(), input_len);
        let Ok(source) = std::str::from_utf8(bytes) else {
            return 2;
        };
        match format_text(source) {
            Ok(code) => {
                (*result).out = leak_buffer(code.as_bytes());
                0
            }
            Err(message) => {
                (*result).err = leak_buffer(message.as_bytes());
                1
            }
        }
    }
}

/// Releases a buffer handed out by `canoe_format_js`. Same pointer and length
/// the shim returned; both are required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn canoe_str_free(ptr: *mut c_char, len: usize) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let boxed = Box::from_raw(slice::from_raw_parts_mut(ptr.cast::<u8>(), len));
        drop(boxed);
    }
}
