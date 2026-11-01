import AppKit
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterXML

/// Incremental syntax highlighting for `CodeEditor`: one parser + parse
/// tree kept alive per editor, edited through tree-sitter's incremental
/// machinery instead of the full re-parse every keystroke that
/// `SyntaxHighlight.foregroundRuns` does for one-shot painting.
///
/// On each storage edit the engine
/// 1. feeds an `InputEdit` into the retained tree (UTF-16 code-unit offsets
///    double into UTF-16LE byte offsets - SwiftTreeSitter's convention),
/// 2. re-parses against the old tree exactly once and asks for
///    `changedRanges`,
/// 3. returns a repaint window: the edited lines united with everything the
///    parse says moved (a `/*` typed above recolors lines far below), and
/// 4. the fresh runs intersecting that window, from the same paint walks
///    the response viewer uses.
///
/// `{{variable}}` tints are line-scoped, so the caller re-tints the same
/// window; the window is always expanded to line boundaries first, which
/// also guarantees a placeholder never straddles its edge.
///
/// Anything unexpected (grammar load failure, parse cancellation, text over
/// the shared length cap) degrades to tint-only, matching
/// `SyntaxHighlight`'s contract: highlighting must never break the editor.
final class SourceHighlighter {
    private var syntax: BodySyntax
    private var parser: Parser?
    private var tree: MutableTree?
    /// UTF-16 offsets of every line start, kept incrementally so the
    /// InputEdit points stay O(edited lines) even on megabyte bodies.
    private var lineStarts: [Int] = [0]

    /// Same cap as `SyntaxHighlight`: beyond it the editor paints variable
    /// tints only and skips the grammar entirely.
    private let maxSyntaxLength = 200_000

    init(syntax: BodySyntax) {
        self.syntax = .plain
        setSyntax(syntax)
    }

    /// Switches the grammar (the raw body's JSON/XML/Text picker). Rebuilds
    /// the parser; the next paint is a full one.
    func setSyntax(_ syntax: BodySyntax) {
        guard syntax != self.syntax || parser == nil else { return }
        self.syntax = syntax
        parser = Self.parser(for: syntax)
        tree = nil
    }

    /// Feeds one storage edit through the incremental pipeline. `text` is
    /// the post-edit document; `editedRange` is NSTextStorage's editedRange
    /// (post-edit coordinates - it spans the characters now occupying the
    /// changed region) and `delta` its changeInLength. Returns the
    /// line-bounded repaint window plus the syntax runs inside it - runs
    /// nil means tint-only (over the cap, parse unavailable).
    func edit(_ text: String, editedRange: NSRange, delta: Int) -> (window: NSRange, runs: [(NSRange, NSColor)]?) {
        let nsText = text as NSString
        let length = nsText.length
        // Clamp against delegate reentry edges (empty documents, programmatic
        // edits racing layout): a malformed range must not crash the editor.
        let start = min(max(editedRange.location, 0), length)
        let newLength = min(max(editedRange.length, 0), length - start)
        let oldLength = max(newLength - delta, 0)
        let oldEnd = start + oldLength
        let newEnd = start + newLength

        let oldLineStarts = lineStarts
        let startLine = Self.lineIndex(of: start, in: oldLineStarts)
        let oldEndLine = Self.lineIndex(of: oldEnd, in: oldLineStarts)
        let startPoint = Point(row: startLine, column: 2 * (start - oldLineStarts[startLine]))
        let oldEndPoint = Point(row: oldEndLine, column: 2 * (oldEnd - oldLineStarts[oldEndLine]))
        lineStarts = Self.updatedLineStarts(
            oldLineStarts,
            span: EditSpan(start: start, oldEnd: oldEnd, newEnd: newEnd, delta: delta),
            text: nsText)
        let newEndLine = Self.lineIndex(of: newEnd, in: lineStarts)
        let newEndPoint = Point(row: newEndLine, column: 2 * (newEnd - lineStarts[newEndLine]))

        // The repaint floor: the lines the edit itself touched.
        var window = Self.lineWindow(
            for: NSRange(location: start, length: newEnd - start),
            lineStarts: lineStarts,
            length: length)

        // The single parse of this edit: incremental against the retained
        // tree, from scratch when there is none (first edit, previous parse
        // failure) or the grammar is unavailable (tint-only degradation).
        var runs: [(NSRange, NSColor)]?
        if length <= maxSyntaxLength, syntax != .plain, let parser {
            if let oldTree = tree {
                oldTree.edit(
                    InputEdit(
                        startByte: 2 * start,
                        oldEndByte: 2 * oldEnd,
                        newEndByte: 2 * newEnd,
                        startPoint: startPoint,
                        oldEndPoint: oldEndPoint,
                        newEndPoint: newEndPoint))
                if let newTree = parser.parse(tree: oldTree, string: text) {
                    // Everything the parse says moved joins the window: a
                    // `/*` typed above recolors lines far below the caret.
                    for changed in oldTree.changedRanges(from: newTree) {
                        let range = NSRange(
                            location: Int(changed.bytes.lowerBound) / 2,
                            length: (Int(changed.bytes.upperBound) - Int(changed.bytes.lowerBound)) / 2)
                        window = window.union(
                            Self.lineWindow(for: range, lineStarts: lineStarts, length: length))
                    }
                    tree = newTree
                } else {
                    tree = nil
                }
            }
            if let current = tree ?? parser.parse(text) {
                tree = current
                runs = Self.paint(current, syntax: syntax, length: length)
            } else {
                tree = nil
            }
        }

        return (window, Self.windowRuns(full: runs, window: window))
    }

    // MARK: - Painting

    /// Walks a fresh tree once with the shared paint walks. The walk is
    /// O(nodes) - microseconds next to the attribute work - so the caller
    /// filters rather than re-strategizing the traversal.
    private static func paint(_ tree: MutableTree, syntax: BodySyntax, length: Int) -> [(NSRange, NSColor)]? {
        guard let root = tree.rootNode else { return nil }
        var runs: [(NSRange, NSColor)] = []
        var cursor = 0
        switch syntax {
        case .plain:
            return nil
        case .json:
            SyntaxHighlight.paintJSON(run: root, asKey: false, length: length, cursor: &cursor, runs: &runs)
        case .xml:
            SyntaxHighlight.paintXML(run: root, length: length, cursor: &cursor, runs: &runs)
        case .javascript:
            SyntaxHighlight.paintJS(run: root, length: length, cursor: &cursor, runs: &runs)
        }
        return runs
    }

    /// The runs intersecting the repaint window (nil = tint-only).
    private static func windowRuns(full: [(NSRange, NSColor)]?, window: NSRange) -> [(NSRange, NSColor)]? {
        guard let full else { return nil }
        return full.filter { NSIntersectionRange($0.0, window).length > 0 }
    }

    /// Parser for a body language; nil when the grammar is unavailable
    /// (plain, or the tree-sitter language function failed to load).
    private static func parser(for syntax: BodySyntax) -> Parser? {
        let pointer: OpaquePointer?
        switch syntax {
        case .plain:
            return nil
        case .json:
            pointer = tree_sitter_json()
        case .xml:
            pointer = tree_sitter_xml()
        case .javascript:
            pointer = tree_sitter_javascript()
        }
        guard let pointer else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(Language(pointer))) != nil else { return nil }
        return parser
    }

    // MARK: - Line bookkeeping

    /// Total logical lines. A trailing newline opens a phantom line -
    /// editors number it too (it is where the next character lands).
    var lineCount: Int { lineStarts.count }

    /// UTF-16 offsets of every line start (line 1 begins at 0) - the
    /// go-to-line jump reads this ledger.
    var lineStartOffsets: [Int] { lineStarts }

    /// Syntax diagnostics from the retained tree: the outermost ERROR
    /// nodes ("Syntax error") and MISSING tokens ("Missing x") as UTF-16
    /// ranges. Empty when the tree is clean, plain, or over the cap.
    func diagnostics() -> [(range: NSRange, message: String)] {
        guard let tree, let root = tree.rootNode, root.hasError else { return [] }
        var out: [(range: NSRange, message: String)] = []
        func walk(_ node: Node) {
            if node.nodeType == "ERROR" {
                out.append((node.range, "Syntax error"))
                return  // outermost error wins; its children are the damage
            }
            if node.isMissing {
                out.append((node.range, "Missing \(node.nodeType ?? "token")"))
                return
            }
            guard node.hasError else { return }
            for index in 0..<node.childCount {
                if let child = node.child(at: index) { walk(child) }
            }
        }
        walk(root)
        return out
    }

    /// 1-based logical line number for a UTF-16 offset (clamped). An offset
    /// at or past the last line start lands on the last line - which is the
    /// phantom line when the document ends with a newline, so both share
    /// one clamp.
    func lineNumber(ofUTF16Offset offset: Int) -> Int {
        let clamped = min(max(offset, 0), lineStarts.last ?? 0)
        return Self.lineIndex(of: clamped, in: lineStarts) + 1
    }

    /// Whether a UTF-16 offset opens a line (offset 0, or just after `\n`).
    /// The gutter numbers only fragments that start a line, so wrapped
    /// continuations repeat nothing.
    func isLineStart(_ offset: Int) -> Bool {
        guard let last = lineStarts.last, offset <= last else { return false }
        return lineStarts[Self.lineIndex(of: offset, in: lineStarts)] == offset
    }

    private static func lineStartOffsets(in text: String) -> [Int] {
        var starts: [Int] = [0]
        var index = 0
        for unit in text.utf16 {
            // Only `\n` opens a line, matching tree-sitter's own point rows;
            // a lone `\n` unit can never be half a surrogate pair.
            if unit == 0x0A {
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    /// Last line-start index whose offset is <= `location` (binary search).
    private static func lineIndex(of location: Int, in lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Line-bounded expansion of `range`: from the start of the line holding
    /// its first character through the start of the line after its last.
    /// Line boundaries guarantee `{{placeholder}}` scans never straddle the
    /// window edge and keep repaint coalescing predictable.
    private static func lineWindow(for range: NSRange, lineStarts: [Int], length: Int) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, start), length)
        let firstLine = lineIndex(of: start, in: lineStarts)
        let windowStart = lineStarts[firstLine]
        let lastLine = lineIndex(of: max(end - 1, start), in: lineStarts)
        let windowEnd = lastLine + 1 < lineStarts.count ? lineStarts[lastLine + 1] - 1 : length
        return NSRange(location: windowStart, length: max(windowEnd - windowStart, 0))
    }

    /// One character edit in UTF-16 coordinates: post-edit replacement
    /// span (`start`..<`newEnd`), the pre-edit end of the replaced region,
    /// and the length change.
    private struct EditSpan {
        let start: Int
        let oldEnd: Int
        let newEnd: Int
        let delta: Int
    }

    /// Folds one edit into the line-start array: keep entries at or before
    /// the edit, drop starts inside the replaced span (their newlines were
    /// replaced), insert starts for newlines the replacement carries, shift
    /// the tail by the delta. An entry exactly at the old end belongs to a
    /// newline inside the replaced span, so it is dropped too - the scan
    /// re-adds one at the new end when the replacement itself ends in `\n`.
    private static func updatedLineStarts(
        _ old: [Int],
        span: EditSpan,
        text: NSString
    ) -> [Int] {
        var updated: [Int] = []
        updated.reserveCapacity(old.count + 8)
        for offset in old where offset <= span.start {
            updated.append(offset)
        }
        var scan = span.start
        while scan < span.newEnd {
            let found = text.rangeOfCharacter(
                from: CharacterSet(charactersIn: "\n"),
                options: [],
                range: NSRange(location: scan, length: span.newEnd - scan))
            guard found.location != NSNotFound else { break }
            updated.append(found.location + 1)
            scan = found.location + 1
        }
        for offset in old where offset > span.oldEnd {
            updated.append(offset + span.delta)
        }
        return updated
    }
}

extension NSRange {
    /// Unites two ranges into their smallest cover (assumes valid inputs).
    fileprivate func union(_ other: NSRange) -> NSRange {
        let start = min(location, other.location)
        let end = max(NSMaxRange(self), NSMaxRange(other))
        return NSRange(location: start, length: max(end - start, 0))
    }
}
