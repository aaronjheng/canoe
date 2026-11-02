import AppKit
import SwiftTreeSitter
import SwiftUI

/// The package's grammar paint walks plus the generic one-shot driver,
/// backed by tree-sitter.
///
/// The walks are pure functions of a parsed tree (node types in, colored
/// ranges out), shared by the editor's incremental pipeline (one repaint
/// window per edit) and hosts' one-shot passes. Hosts add languages by
/// defining their own `SyntaxProfile` around these walks (or new ones) -
/// nothing here knows about the host app.
///
/// Anything unexpected (parse failure, ABI mismatch, truncated input)
/// degrades to plain text - highlighting must never break the editor.
public enum SyntaxHighlight {
    // MARK: - Generic drivers

    /// Cap: beyond this a full re-parse per keystroke is not worth it,
    /// and the editor degrades to annotations.
    private static let maxSyntaxLength = 200_000

    /// Foreground runs for the editors: parse `source` with the profile's
    /// grammar and walk the tree with the profile's paint. nil means plain
    /// (no grammar, over the cap, or parse failure) - the caller still
    /// applies its annotations.
    public static func foregroundRuns(in source: String, profile: SyntaxProfile) -> [(NSRange, NSColor)]? {
        guard let language = profile.language() else { return nil }
        let length = (source as NSString).length
        guard length <= maxSyntaxLength else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil else { return nil }
        guard let tree = parser.parse(source), let root = tree.rootNode else { return nil }
        var runs: [(NSRange, NSColor)] = []
        var cursor = 0
        profile.paint(root, length, &cursor, &runs)
        return runs
    }

    private struct Run {
        /// nil means the default (primary) color.
        let color: Color?
        let text: String
    }

    /// The same colored document as an attributed string: the response
    /// body's find overlay layers match highlights on top of the token
    /// colors, which needs attribute access a plain Text can't give.
    public static func attributedText(_ source: String, profile: SyntaxProfile) -> AttributedString {
        guard let foreground = foregroundRuns(in: source, profile: profile) else {
            return AttributedString(source)
        }
        return attributed(foreground, in: source)
    }

    /// Converts flat (range, color) runs into text runs, filling the gaps
    /// with uncolored text so the attributed string covers the source.
    private static func attributed(_ foreground: [(NSRange, NSColor)], in source: String) -> AttributedString {
        let nsSource = source as NSString
        var result = AttributedString("")
        var cursor = 0
        for (range, color) in foreground {
            guard range.location >= cursor, range.length > 0 else { continue }
            if range.location > cursor {
                result += AttributedString(nsSource.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            var piece = AttributedString(nsSource.substring(with: range))
            piece.foregroundColor = Color(nsColor: color)
            result += piece
            cursor = range.location + range.length
        }
        if cursor < nsSource.length {
            result += AttributedString(nsSource.substring(with: NSRange(location: cursor, length: nsSource.length - cursor)))
        }
        return result
    }

    // MARK: - Grammar paint walks (NSTextView runs)

    /// Mirrors `paint` above, emitting attributed-string runs instead of
    /// Text pieces so the editor shares the exact JSON coloring.
    public static func paintJSON(
        run node: Node,
        asKey: Bool,
        length: Int,
        cursor: inout Int,
        runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "pair":
            guard let key = node.namedChild(at: 0) else { return }
            paintJSON(run: key, asKey: true, length: length, cursor: &cursor, runs: &runs)
            for index in 0..<node.childCount {
                guard let child = node.child(at: index), child != key else { continue }
                paintJSON(run: child, asKey: false, length: length, cursor: &cursor, runs: &runs)
            }
        case "string":
            let color = asKey ? EditorTheme.syntaxKey : EditorTheme.syntaxString
            paintJSONLeaf(node, color: NSColor(color), length: length, cursor: &cursor, runs: &runs)
        case "number":
            paintJSONLeaf(node, color: NSColor(EditorTheme.syntaxNumber), length: length, cursor: &cursor, runs: &runs)
        case "true", "false", "null":
            paintJSONLeaf(node, color: NSColor(EditorTheme.syntaxKeyword), length: length, cursor: &cursor, runs: &runs)
        default:
            if node.childCount == 0 {
                // Unnamed leaves: brackets, colons, commas, ERROR fragments.
                paintJSONLeaf(node, color: NSColor(EditorTheme.syntaxPlain), length: length, cursor: &cursor, runs: &runs)
            } else {
                for index in 0..<node.childCount {
                    guard let child = node.child(at: index) else { continue }
                    paintJSON(run: child, asKey: false, length: length, cursor: &cursor, runs: &runs)
                }
            }
        }
    }

    public static func paintJSONLeaf(
        _ node: Node,
        color: NSColor,
        length: Int,
        cursor: inout Int,
        runs: inout [(NSRange, NSColor)]
    ) {
        let range = node.range.clamped(to: 0..<length)
        guard range.length > 0 else { return }
        cursor = range.location + range.length
        runs.append((range, color))
    }

    /// Walks an XML tree (tree-sitter-grammars/tree-sitter-xml node types):
    /// element names as keywords, attribute names as keys, attribute values
    /// as strings, references as numbers, comments tertiary, and markup
    /// punctuation secondary. Unknown leaves stay default; malformed input
    /// degrades through the generic recursion like the JSON walk.
    public static func paintXML(
        run node: Node,
        length: Int,
        cursor: inout Int,
        runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "STag", "ETag", "EmptyElemTag":
            // First Name child is the element name; attributes paint
            // themselves below; the brackets fall through as punctuation.
            var namedTagName = false
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                if !namedTagName, child.nodeType == "Name", child.isNamed {
                    paintXMLLeaf(child, color: NSColor(EditorTheme.syntaxKeyword), length: length, cursor: &cursor, runs: &runs)
                    namedTagName = true
                } else {
                    paintXML(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        case "Attribute", "PseudoAtt":
            // Name, "=", quoted value.
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                if child.nodeType == "Name", child.isNamed {
                    paintXMLLeaf(child, color: NSColor(EditorTheme.syntaxKey), length: length, cursor: &cursor, runs: &runs)
                } else if child.nodeType == "AttValue" || child.nodeType == "PseudoAttValue" {
                    paintXMLLeaf(child, color: NSColor(EditorTheme.syntaxString), length: length, cursor: &cursor, runs: &runs)
                } else {
                    paintXML(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        case "AttValue", "EntityValue", "PseudoAttValue", "SystemLiteral", "PubidLiteral", "VersionNum", "EncName":
            paintXMLLeaf(node, color: NSColor(EditorTheme.syntaxString), length: length, cursor: &cursor, runs: &runs)
        case "EntityRef", "CharRef", "PEReference":
            paintXMLLeaf(node, color: NSColor(EditorTheme.syntaxNumber), length: length, cursor: &cursor, runs: &runs)
        case "PITarget":
            paintXMLLeaf(node, color: NSColor(EditorTheme.syntaxKeyword), length: length, cursor: &cursor, runs: &runs)
        case "Comment":
            paintXMLLeaf(node, color: NSColor(EditorTheme.syntaxPlain), length: length, cursor: &cursor, runs: &runs)
        case "CData":
            paintXMLLeaf(node, color: NSColor(EditorTheme.syntaxString), length: length, cursor: &cursor, runs: &runs)
        case "CharData":
            // Element text content stays default.
            break
        default:
            if node.childCount == 0 {
                if node.isNamed {
                    break
                }
                paintXMLLeaf(node, color: NSColor(EditorTheme.syntaxPlain), length: length, cursor: &cursor, runs: &runs)
            } else {
                for index in 0..<node.childCount {
                    guard let child = node.child(at: index) else { continue }
                    paintXML(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        }
    }

    public static func paintXMLLeaf(
        _ node: Node,
        color: NSColor,
        length: Int,
        cursor: inout Int,
        runs: inout [(NSRange, NSColor)]
    ) {
        let range = node.range.clamped(to: 0..<length)
        guard range.length > 0 else { return }
        cursor = range.location + range.length
        runs.append((range, color))
    }

    /// Anonymous JavaScript tokens that read as keywords: statements,
    /// declarations, literals, the arrow. Anything not on the list falls
    /// through to the editor's default text color, so being out of sync
    /// with the grammar only costs a color, never a crash.
    public static let jsKeywordTokens: Set<String> = [
        "function", "const", "let", "var", "return", "if", "else",
        "for", "while", "do", "switch", "case", "default", "break",
        "continue", "new", "delete", "typeof", "instanceof", "in", "of",
        "true", "false", "null", "undefined", "import", "export",
        "from", "class", "extends", "try", "catch", "finally", "throw",
        "this", "await", "async", "yield", "void", "=>",
    ]

    /// Walks a JavaScript tree: strings/numbers/comments take the shared
    /// token colors, anonymous keyword tokens the keyword color, and the
    /// callee side of every call (`pm.test`, `pm.expect(...).to.equal`)
    /// reads as one function-name chain (API consoles commonly emphasize
    /// a client surface this way). Plain identifiers and punctuation stay
    /// the default text color; malformed input degrades through the generic
    /// recursion like the JSON/XML walks.
    public static func paintJS(
        run node: Node,
        length: Int,
        cursor: inout Int,
        runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "string", "template_string":
            paintJSLeaf(node, color: NSColor(EditorTheme.syntaxString), length: length, cursor: &cursor, runs: &runs)
        case "number":
            paintJSLeaf(node, color: NSColor(EditorTheme.syntaxNumber), length: length, cursor: &cursor, runs: &runs)
        case "comment":
            paintJSLeaf(node, color: NSColor(EditorTheme.syntaxPlain), length: length, cursor: &cursor, runs: &runs)
        case "call_expression":
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                if child.id == node.child(byFieldName: "function")?.id {
                    paintJSCallee(child, length: length, cursor: &cursor, runs: &runs)
                } else {
                    paintJS(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        default:
            if node.childCount == 0 {
                if jsKeywordTokens.contains(type) {
                    paintJSLeaf(node, color: NSColor(EditorTheme.syntaxKeyword), length: length, cursor: &cursor, runs: &runs)
                }
            } else {
                for index in 0..<node.childCount {
                    guard let child = node.child(at: index) else { continue }
                    paintJS(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        }
    }

    /// Recursively paints a callee chain with the function-name color:
    /// identifiers and property names inside the chain, so `pm.test` and
    /// deep `pm.response.to.have.status` read whole. Strings in computed
    /// member chains (`a["x"]`) stay string-colored via the generic walk.
    public static func paintJSCallee(
        _ node: Node,
        length: Int,
        cursor: inout Int,
        runs: inout [(NSRange, NSColor)]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "identifier", "property_identifier":
            paintJSLeaf(node, color: NSColor(EditorTheme.syntaxKey), length: length, cursor: &cursor, runs: &runs)
        case "member_expression":
            let objectID = node.child(byFieldName: "object")?.id
            let propertyID = node.child(byFieldName: "property")?.id
            for index in 0..<node.childCount {
                guard let child = node.child(at: index) else { continue }
                if child.id == objectID || child.id == propertyID {
                    paintJSCallee(child, length: length, cursor: &cursor, runs: &runs)
                } else {
                    paintJS(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        default:
            // Anything else on the callee side (a parenthesized expression,
            // a call used as a callee) walks with the generic rules.
            paintJS(run: node, length: length, cursor: &cursor, runs: &runs)
        }
    }

    public static func paintJSLeaf(
        _ node: Node,
        color: NSColor,
        length: Int,
        cursor: inout Int,
        runs: inout [(NSRange, NSColor)]
    ) {
        let range = node.range.clamped(to: 0..<length)
        guard range.length > 0 else { return }
        cursor = range.location + range.length
        runs.append((range, color))
    }
}

extension NSRange {
    fileprivate func clamped(to bounds: Range<Int>) -> NSRange {
        let start = min(max(location, bounds.lowerBound), bounds.upperBound)
        let end = min(max(location + length, start), bounds.upperBound)
        return NSRange(location: start, length: end - start)
    }
}
