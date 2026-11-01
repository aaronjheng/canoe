/// The ⌥⇧F failure shape: format handlers throw it with the exact note
/// text the container surfaces (the Scripts pane and the raw body show
/// it in a transient bottom capsule). Shared by both editors.
struct TextFormatError: Error, Sendable {
    var message: String
}
