import AppKit
import SwiftTreeSitter

/// A syntax the generic editor can highlight and comment: a tree-sitter
/// grammar plus its paint walk. The package is host-neutral by design - it
/// ships NO grammars and NO presets. Every language (json, xml, javascript,
/// bash, lua, ...) is a host-side `SyntaxProfile` built around the package's
/// `SyntaxHighlight` walks (or the host's own). Equatable by `id`: two
/// profiles with the same id are the same syntax (the editor diffs profiles
/// to decide on full re-styles).
public struct SyntaxProfile: Equatable, Sendable {
    /// How ⌘/ comments the language.
    public enum CommentStyle: Equatable, Sendable {
        /// The grammar has no comments (JSON): the key falls through.
        case none
        /// Line comments: `prefix` (with its trailing space) is inserted
        /// after the line's indent, e.g. `"// "` for JavaScript.
        case line(prefix: String)
        /// Block comments wrapped around the selection, e.g.
        /// `open: "<!--", close: "-->"` for XML.
        case block(open: String, close: String)
    }

    public let id: String
    /// Loads the tree-sitter language; nil (or a failed load) degrades the
    /// editor to annotation-only for this profile.
    public let language: @Sendable () -> Language?
    /// Walks a parsed tree into (range, color) runs. Receives the root node
    /// and the document's UTF-16 length; must append runs in order.
    public let paint: @Sendable (_ root: Node, _ length: Int, _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]) -> Void
    public let commentStyle: CommentStyle

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// Creates a profile. Hosts add languages by constructing one of
    /// these around their own grammar + paint walk.
    public init(
        id: String,
        language: @escaping @Sendable () -> Language?,
        paint: @escaping @Sendable (_ root: Node, _ length: Int, _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]) -> Void,
        commentStyle: CommentStyle
    ) {
        self.id = id
        self.language = language
        self.paint = paint
        self.commentStyle = commentStyle
    }

    /// The zero-syntax profile: no grammar, no paint, no comments. The
    /// editor's default; hosts that need annotation-only surfaces reuse it.
    public static var plain: SyntaxProfile {
        SyntaxProfile(
            id: "plain",
            language: { nil },
            paint: { _, _, _, _ in },
            commentStyle: .none)
    }
}
