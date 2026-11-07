/// A QuickJS exception surfaced to Swift: `message` is the error's string
/// form (e.g. "RangeError: boom"), `stack` is the V8-style stack trace that
/// QuickJS-NG ships (`Error.captureStackTrace` machinery).
public struct QJSError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let stack: String?

    public init(message: String, stack: String?) {
        self.message = message
        self.stack = stack
    }

    public var description: String {
        if let stack, !stack.isEmpty { return "\(message)\n\(stack)" }
        return message
    }
}
