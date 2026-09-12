import SwiftTreeSitter
import SwiftUI
import TreeSitterJSON

/// JSON syntax highlighting backed by tree-sitter
/// (https://github.com/tree-sitter/tree-sitter-json).
///
/// The response body is parsed into a real syntax tree and token colors come
/// from node types, so keys/strings/numbers stay correct even with escapes or
/// nesting. Anything unexpected (parse failure, ABI mismatch, truncated
/// input) degrades to plain text - highlighting must never break the viewer.
enum JSONSyntaxHighlight {
    private struct Run {
        /// nil means the default (primary) color.
        let color: Color?
        let text: String
    }

    /// Builds a syntax-colored view of a (pretty-printed) JSON document.
    static func highlightedText(_ source: String) -> Text {
        guard let runs = highlightRuns(in: source) else { return Text(source) }
        // `+` on Text is deprecated in macOS 26; interpolating Text values is
        // the replacement.
        var result = Text("")
        for run in runs {
            let piece: Text
            if let color = run.color {
                piece = Text(run.text).foregroundStyle(color)
            } else {
                piece = Text(run.text)
            }
            result = Text("\(result)\(piece)")
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
}

extension NSRange {
    fileprivate func clamped(to bounds: Range<Int>) -> NSRange {
        let start = min(max(location, bounds.lowerBound), bounds.upperBound)
        let end = min(max(location + length, start), bounds.upperBound)
        return NSRange(location: start, length: end - start)
    }
}
