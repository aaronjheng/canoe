/// The ⌥⇧F failure shape: a host's format handler throws it with the
/// exact note text the host surfaces (typically a transient capsule).
/// Shared by every editor that carries a format handler.
public struct TextFormatError: Error, Sendable {
    public var message: String

    /// Creates the error with the surfaced note text.
    public init(message: String) {
        self.message = message
    }
}
