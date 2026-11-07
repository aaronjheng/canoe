//
//  QJSShims.h
//  Canoe vendor package: QuickJS-NG (v0.9.0)
//
//  Tiny C shims around QuickJS's macros and static-inline helpers, which Swift
//  cannot call directly (C macros and inline functions are not exported).
//  The Swift binding (target `QuickJS`) uses only these shims plus JS_EXTERN
//  functions; everything here is header-only visible through the module map
//  SwiftPM generates for `include/`.
//
#ifndef QJS_SHIMS_H
#define QJS_SHIMS_H

// The engine lives in the `third_party/quickjs/` submodule; the search
// path (see Package.swift cSettings) resolves this include for both the C
// compilation and the clang module Swift imports.
#include "../quickjs/quickjs.h"

/// Kind codes returned by `qjs_kind_of`. Ordinals mirror the Swift
/// `QJSValueKind` enum cases in the same order.
enum {
    QJSKindUndefined = 0,
    QJSKindNull = 1,
    QJSKindBoolean = 2,
    QJSKindInt = 3,
    QJSKindFloat = 4,
    QJSKindString = 5,
    QJSKindObject = 6,
    QJSKindBigInt = 7,
    QJSKindOther = 8,
};

/// Tag-driven view of a value: maps onto the quickjs tag enumeration that
/// lives behind JS_VALUE_GET_TAG (a macro).
int qjs_kind_of(JSValue v);

/// Union member read for int-tag values (guards against silently misreading
/// doubles; callers already checked `.int` or `.boolean`).
int64_t qjs_int_value(JSValue v);

/// Constructors for plain values (JS_MKVAL / JS_NewInt32 are inline macros).
JSValue qjs_undefined(void);
JSValue qjs_null(void);
JSValue qjs_bool(int v);
JSValue qjs_int32(int32_t v);
JSValue qjs_float64(double v);

/// The JS_EXCEPTION marker value (special tag, nothing to free).
JSValue qjs_exception(void);

JSValue qjs_new_string_len(JSContext *ctx, const char *utf8, size_t len);

bool qjs_is_number(JSValue v);

/// Union member read for float-tag values (kind already established).
double qjs_float_value(JSValue v);

/// JS_ToCStringLen2 is inline; wrap it. The returned pointer is released
/// with JS_FreeCString (an extern function, callable from Swift directly).
const char *qjs_to_c_string(JSContext *ctx, JSValue v, size_t *len);

/// Registers a host function whose JSCFunctionData callback receives a
/// one-element func-data array holding a process-unique int key, so the Swift
/// side can dispatch without any C-side global state. Returns the function
/// value (owned by the caller).
JSValue qjs_new_host_function(JSContext *ctx, JSCFunctionData *fn,
                              const char *name, int argc, int32_t key);

/// Reads the host-function key out of the func-data array (argument 0).
int32_t qjs_host_key(JSValueConst *func_data);

/// JS_FreeValue is an inline helper in some quickjs revisions; route every
/// value release through this shim so the Swift side is revision-proof.
void qjs_free_value(JSContext *ctx, JSValue v);

/// Same for JS_FreeCString.
void qjs_free_c_string(JSContext *ctx, const char *pointer);

/// Swift cannot call variadic C functions; format the message in Swift and
/// throw a plain text TypeError here.
JSValue qjs_throw_type_error(JSContext *ctx, const char *message);

#endif /* QJS_SHIMS_H */
