import AppKit
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterXML

/// A syntax the generic editor can highlight and comment: a tree-sitter
/// grammar plus its paint walk. The package ships JSON/XML/JavaScript
/// presets; a host adds languages (bash, lua, ...) by defining its own
/// `SyntaxProfile` and handing it to the editor - package code never
/// changes. Equatable by `id`: two profiles with the same id are the same
/// syntax (the editor diffs profiles to decide on full re-styles).
public struct SyntaxProfile: Equatable {
    /// How ⌘/ comments the language.
    public enum CommentStyle: Equatable {
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
    public let language: () -> Language?
    /// Walks a parsed tree into (range, color) runs. Receives the root node
    /// and the document's UTF-16 length; must append runs in order.
    public let paint: (_ root: Node, _ length: Int, _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]) -> Void
    public let commentStyle: CommentStyle

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    /// Creates a profile. Hosts add languages by constructing one of
    /// these around their own grammar + paint walk.
    public init(
        id: String,
        language: @escaping () -> Language?,
        paint: @escaping (_ root: Node, _ length: Int, _ cursor: inout Int, _ runs: inout [(NSRange, NSColor)]) -> Void,
        commentStyle: CommentStyle
    ) {
        self.id = id
        self.language = language
        self.paint = paint
        self.commentStyle = commentStyle
    }

    // MARK: Package presets

    /// No grammar: annotation tints only.
    public static var plain: SyntaxProfile {
        SyntaxProfile(
            id: "plain",
            language: { nil },
            paint: { _, _, _, _ in },
            commentStyle: .none)
    }

    public static var json: SyntaxProfile {
        SyntaxProfile(
            id: "json",
            language: { tree_sitter_json().map { Language($0) } },
            paint: { root, length, cursor, runs in
                SyntaxHighlight.paintJSON(run: root, asKey: false, length: length, cursor: &cursor, runs: &runs)
            },
            commentStyle: .none)
    }

    public static var xml: SyntaxProfile {
        SyntaxProfile(
            id: "xml",
            language: { tree_sitter_xml().map { Language($0) } },
            paint: { root, length, cursor, runs in
                SyntaxHighlight.paintXML(run: root, length: length, cursor: &cursor, runs: &runs)
            },
            commentStyle: .block(open: "<!--", close: "-->"))
    }

    public static var javascript: SyntaxProfile {
        SyntaxProfile(
            id: "javascript",
            language: { tree_sitter_javascript().map { Language($0) } },
            paint: { root, length, cursor, runs in
                SyntaxHighlight.paintJS(run: root, length: length, cursor: &cursor, runs: &runs)
            },
            commentStyle: .line(prefix: "// "))
    }
}
