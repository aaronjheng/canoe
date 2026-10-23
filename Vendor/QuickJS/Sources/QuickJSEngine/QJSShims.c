//
//  QJSShims.c
//  See QJSShims.h for rationale.
//
#include "QJSShims.h"

int qjs_kind_of(JSValue v) {
    switch (JS_VALUE_GET_TAG(v)) {
        case JS_TAG_UNDEFINED:
            return QJSKindUndefined;
        case JS_TAG_NULL:
            return QJSKindNull;
        case JS_TAG_BOOL:
            return QJSKindBoolean;
        case JS_TAG_INT:
            return QJSKindInt;
        case JS_TAG_FLOAT64:
            return QJSKindFloat;
        case JS_TAG_STRING:
            return QJSKindString;
        case JS_TAG_OBJECT:
            return QJSKindObject;
        case JS_TAG_BIG_INT:
            return QJSKindBigInt;
        default:
            return QJSKindOther;
    }
}

int64_t qjs_int_value(JSValue v) {
    return (int64_t)JS_VALUE_GET_INT(v);
}

double qjs_float_value(JSValue v) {
    return JS_VALUE_GET_FLOAT64(v);
}

JSValue qjs_undefined(void) {
    return JS_MKVAL(JS_TAG_UNDEFINED, 0);
}

JSValue qjs_null(void) {
    return JS_MKVAL(JS_TAG_NULL, 0);
}

JSValue qjs_bool(int v) {
    return JS_MKVAL(JS_TAG_BOOL, v);
}

JSValue qjs_int32(int32_t v) {
    return JS_MKVAL(JS_TAG_INT, v);
}

JSValue qjs_float64(double v) {
    return (JSValue){ (JSValueUnion){ .float64 = v }, JS_TAG_FLOAT64 };
}

JSValue qjs_exception(void) {
    return (JSValue){ (JSValueUnion){ .int32 = 0 }, JS_TAG_EXCEPTION };
}

JSValue qjs_new_string_len(JSContext *ctx, const char *utf8, size_t len) {
    return JS_NewStringLen(ctx, utf8, len);
}

bool qjs_is_number(JSValue v) {
    return JS_IsNumber(v);
}

const char *qjs_to_c_string(JSContext *ctx, JSValue v, size_t *len) {
    return JS_ToCStringLen2(ctx, len, v, false);
}

JSValue qjs_new_host_function(JSContext *ctx, JSCFunctionData *fn,
                              const char *name, int argc, int32_t key) {
    // JS_NewCFunctionData retains the data array entries; the local copy is
    // released after the call.
    JSValue data = JS_NewInt32(ctx, key);
    JSValue function = JS_NewCFunctionData(ctx, fn, name, argc, 1, &data);
    JS_FreeValue(ctx, data);
    return function;
}

int32_t qjs_host_key(JSValueConst *func_data) {
    return JS_VALUE_GET_INT(func_data[0]);
}

void qjs_free_value(JSContext *ctx, JSValue v) {
    JS_FreeValue(ctx, v);
}

void qjs_free_c_string(JSContext *ctx, const char *pointer) {
    JS_FreeCString(ctx, pointer);
}

JSValue qjs_throw_type_error(JSContext *ctx, const char *message) {
    return JS_ThrowTypeError(ctx, "%s", message);
}
