/// Materialized view of a QuickJS value: the engine's value has already been
/// converted and freed, so this is a plain value type with no lifetime ties.
public enum QJSValueKind: Equatable, Sendable {
    case undefined
    case null
    case boolean(Bool)
    case int(Int32)
    case float(Double)
    case string(String)
    /// Any heap object (object, function, symbol, bigint, ...). Not
    /// introspectable through the v0 facade; the `pm.*` bridge will add typed
    /// handles later.
    case object
    case bigInt
    case other

    public var description: String {
        switch self {
        case .undefined: return "undefined"
        case .null: return "null"
        case .boolean(let value): return "\(value)"
        case .int(let value): return "\(value)"
        case .float(let value): return "\(value)"
        case .string(let value): return "\"\(value)\""
        case .object: return "object"
        case .bigInt: return "bigint"
        case .other: return "other"
        }
    }
}
