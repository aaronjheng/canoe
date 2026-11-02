import AppKit
import Plume
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterXML

/// Canoe's `SyntaxProfile` library: the languages Canoe's editors speak.
/// Plume ships no grammars by design - every syntax is a host-side profile
/// built over the package's walks. These presets cover the request body's
/// JSON/XML picker and the Scripts tab's JavaScript.
extension SyntaxProfile {
    /// The raw body's JSON dialect: keys read in the key color, scalars in
    /// the shared token colors, no comments (the grammar has none).
    public static let json = SyntaxProfile(
        id: "json",
        language: { tree_sitter_json().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintJSON(run: root, asKey: false, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .none)

    /// The raw body's XML dialect: element names as keywords, attribute
    /// names as keys, attribute values as strings, block `<!-- -->`
    /// comments.
    public static let xml = SyntaxProfile(
        id: "xml",
        language: { tree_sitter_xml().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintXML(run: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .block(open: "<!--", close: "-->"))

    /// The Scripts tab's JavaScript: strings/numbers/comments in the shared
    /// token colors, keyword tokens, and the `pm.` callee chain emphasized.
    public static let javascript = SyntaxProfile(
        id: "javascript",
        language: { tree_sitter_javascript().map { Language($0) } },
        paint: { root, length, cursor, runs in
            SyntaxHighlight.paintJS(run: root, length: length, cursor: &cursor, runs: &runs)
        },
        commentStyle: .line(prefix: "// "))
}
