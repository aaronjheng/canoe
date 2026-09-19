import AppKit
import SwiftTreeSitter
import SwiftUI
import TreeSitterJSON
import TreeSitterXML

/// Request-body language selected in the raw editor. Drives syntax
/// foreground colors there; `{{variable}}` background tints compose on top
/// independently.
enum BodySyntax {
    case plain
    case json
    case xml
}

/// Syntax highlighting backed by tree-sitter.
///
/// The response body is parsed into a real syntax tree and token colors come
/// from node types, so keys/strings/numbers stay correct even with escapes or
/// nesting. Anything unexpected (parse failure, ABI mismatch, truncated
/// input) degrades to plain text - highlighting must never break the viewer.
///
/// The request body editor reuses the same grammars for live foreground
/// colors (see `foregroundRuns(in:syntax:)`); variable tints layer above.
enum SyntaxHighlight {
    private struct Run {
        /// nil means the default (primary) color.
        let color: Color?
        let text: String
    }

    /// Builds a syntax-colored view of a (pretty-printed) JSON document.
    static func highlightedText(_ source: String) -> Text {
        Text(attributedText(source))
    }

    /// The same syntax-colored document as an attributed string: the
    /// response body's find overlay layers match highlights on top of the
    /// token colors, which needs attribute access a plain Text can't give.
    static func attributedText(_ source: String) -> AttributedString {
        guard let runs = highlightRuns(in: source) else { return AttributedString(source) }
        var result = AttributedString("")
        for run in runs {
            var piece = AttributedString(run.text)
            if let color = run.color {
                piece.foregroundColor = color
            }
            result += piece
        }
        return result
    }

    private static func highlightRuns(in source: String) -> [Run]? {
        let pointer: OpaquePointer? = tree_sitter_json()
        guard let pointer else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(Language(pointer))) != nil else { return nil }
        guard let tree = parser.parse(source), let root = tree.rootNode else { return nil }

        let nsSource = source as NSString
        var runs: [Run] = []
        var cursor = 0
        paint(root, asKey: false, nsSource: nsSource, cursor: &cursor, runs: &runs)
        if cursor < nsSource.length {
            runs.append(Run(color: nil, text: nsSource.substring(with: NSRange(location: cursor, length: nsSource.length - cursor))))
        }
        return runs
    }

    /// Recursively paints a node. `asKey` marks a `string` node as an object
    /// key (set by its parent `pair`).
    private static func paint(
        _ node: Node,
        asKey: Bool,
        nsSource: NSString,
        cursor: inout Int,
        runs: inout [Run]
    ) {
        guard let type = node.nodeType, !node.isMissing else { return }
        switch type {
        case "pair":
            // First named child is the key, the rest is the value (the ":"
            // between them falls through as punctuation).
            guard let key = node.namedChild(at: 0) else { return }
            paint(key, asKey: true, nsSource: nsSource, cursor: &cursor, runs: &runs)
            for index in 0..<node.childCount {
                guard let child = node.child(at: index), child != key else { continue }
                paint(child, asKey: false, nsSource: nsSource, cursor: &cursor, runs: &runs)
            }
        case "string":
            paintLeaf(node, color: asKey ? AppColor.syntaxKey : AppColor.syntaxString, nsSource: nsSource, cursor: &cursor, runs: &runs)
        case "number":
            paintLeaf(node, color: AppColor.syntaxNumber, nsSource: nsSource, cursor: &cursor, runs: &runs)
        case "true", "false", "null":
            paintLeaf(node, color: AppColor.syntaxKeyword, nsSource: nsSource, cursor: &cursor, runs: &runs)
        default:
            if node.childCount == 0 {
                // Unnamed leaves: brackets, colons, commas,(ERROR fragments.
                paintLeaf(node, color: .secondary, nsSource: nsSource, cursor: &cursor, runs: &runs)
            } else {
                for index in 0..<node.childCount {
                    guard let child = node.child(at: index) else { continue }
                    paint(child, asKey: false, nsSource: nsSource, cursor: &cursor, runs: &runs)
                }
            }
        }
    }

    /// Emits gap text (whitespace) since `cursor`, then the node itself.
    private static func paintLeaf(
        _ node: Node,
        color: Color,
        nsSource: NSString,
        cursor: inout Int,
        runs: inout [Run]
    ) {
        let range = node.range.clamped(to: 0..<nsSource.length)
        guard range.length > 0 else { return }
        if range.location > cursor {
            runs.append(Run(color: nil, text: nsSource.substring(with: NSRange(location: cursor, length: range.location - cursor))))
        }
        runs.append(Run(color: color, text: nsSource.substring(with: range)))
        cursor = range.location + range.length
    }

    // MARK: - Editor foreground runs (NSTextView)

    /// Cap shared with the response viewer: beyond this a full re-parse per
    /// keystroke is not worth it, and the editor degrades to variable tints.
    private static let maxSyntaxLength = 200_000

    /// Syntax foreground colors as attributed-string runs for the request
    /// body editor. nil means plain (no grammar, over the cap, or parse
    /// failure) - the caller still applies variable tints.
    static func foregroundRuns(in source: String, syntax: BodySyntax) -> [(NSRange, NSColor)]? {
        switch syntax {
        case .plain:
            return nil
        case .json:
            return jsonForegroundRuns(in: source)
        case .xml:
            return xmlForegroundRuns(in: source)
        }
    }

    private static func jsonForegroundRuns(in source: String) -> [(NSRange, NSColor)]? {
        let length = (source as NSString).length
        guard length <= maxSyntaxLength else { return nil }
        let pointer: OpaquePointer? = tree_sitter_json()
        guard let pointer else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(Language(pointer))) != nil else { return nil }
        guard let tree = parser.parse(source), let root = tree.rootNode else { return nil }
        var runs: [(NSRange, NSColor)] = []
        var cursor = 0
        paintJSON(run: root, asKey: false, length: length, cursor: &cursor, runs: &runs)
        return runs
    }

    /// Mirrors `paint` above, emitting attributed-string runs instead of
    /// Text pieces so the editor shares the exact JSON coloring.
    private static func paintJSON(
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
            let color = asKey ? AppColor.syntaxKey : AppColor.syntaxString
            paintJSONLeaf(node, color: NSColor(color), length: length, cursor: &cursor, runs: &runs)
        case "number":
            paintJSONLeaf(node, color: NSColor(AppColor.syntaxNumber), length: length, cursor: &cursor, runs: &runs)
        case "true", "false", "null":
            paintJSONLeaf(node, color: NSColor(AppColor.syntaxKeyword), length: length, cursor: &cursor, runs: &runs)
        default:
            if node.childCount == 0 {
                // Unnamed leaves: brackets, colons, commas, ERROR fragments.
                paintJSONLeaf(node, color: .secondaryLabelColor, length: length, cursor: &cursor, runs: &runs)
            } else {
                for index in 0..<node.childCount {
                    guard let child = node.child(at: index) else { continue }
                    paintJSON(run: child, asKey: false, length: length, cursor: &cursor, runs: &runs)
                }
            }
        }
    }

    private static func paintJSONLeaf(
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

    private static func xmlForegroundRuns(in source: String) -> [(NSRange, NSColor)]? {
        let length = (source as NSString).length
        guard length <= maxSyntaxLength else { return nil }
        let pointer: OpaquePointer? = tree_sitter_xml()
        guard let pointer else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(Language(pointer))) != nil else { return nil }
        guard let tree = parser.parse(source), let root = tree.rootNode else { return nil }
        var runs: [(NSRange, NSColor)] = []
        var cursor = 0
        paintXML(run: root, length: length, cursor: &cursor, runs: &runs)
        return runs
    }

    /// Walks an XML tree (tree-sitter-grammars/tree-sitter-xml node types):
    /// element names as keywords, attribute names as keys, attribute values
    /// as strings, references as numbers, comments tertiary, and markup
    /// punctuation secondary. Unknown leaves stay default; malformed input
    /// degrades through the generic recursion like the JSON walk.
    private static func paintXML(
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
                    paintXMLLeaf(child, color: NSColor(AppColor.syntaxKeyword), length: length, cursor: &cursor, runs: &runs)
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
                    paintXMLLeaf(child, color: NSColor(AppColor.syntaxKey), length: length, cursor: &cursor, runs: &runs)
                } else if child.nodeType == "AttValue" || child.nodeType == "PseudoAttValue" {
                    paintXMLLeaf(child, color: NSColor(AppColor.syntaxString), length: length, cursor: &cursor, runs: &runs)
                } else {
                    paintXML(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        case "AttValue", "EntityValue", "PseudoAttValue", "SystemLiteral", "PubidLiteral", "VersionNum", "EncName":
            paintXMLLeaf(node, color: NSColor(AppColor.syntaxString), length: length, cursor: &cursor, runs: &runs)
        case "EntityRef", "CharRef", "PEReference":
            paintXMLLeaf(node, color: NSColor(AppColor.syntaxNumber), length: length, cursor: &cursor, runs: &runs)
        case "PITarget":
            paintXMLLeaf(node, color: NSColor(AppColor.syntaxKeyword), length: length, cursor: &cursor, runs: &runs)
        case "Comment":
            paintXMLLeaf(node, color: .tertiaryLabelColor, length: length, cursor: &cursor, runs: &runs)
        case "CData":
            paintXMLLeaf(node, color: NSColor(AppColor.syntaxString), length: length, cursor: &cursor, runs: &runs)
        case "CharData":
            // Element text content stays default.
            break
        default:
            if node.childCount == 0 {
                if node.isNamed {
                    break
                }
                paintXMLLeaf(node, color: .secondaryLabelColor, length: length, cursor: &cursor, runs: &runs)
            } else {
                for index in 0..<node.childCount {
                    guard let child = node.child(at: index) else { continue }
                    paintXML(run: child, length: length, cursor: &cursor, runs: &runs)
                }
            }
        }
    }

    private static func paintXMLLeaf(
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
