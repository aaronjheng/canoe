/// Formatting for the raw request body (⌥⇧F while the body editor holds
/// keyboard focus): native token rebuilders for JSON and XML that
/// re-indent the payload without reordering object members, rewriting
/// attribute order, or touching values, and report a parse diagnostic
/// on malformed input instead of guessing. `{{variable}}` placeholders
/// pass through as opaque tokens - shown with their surrounding braces -
/// wherever they appear, including bare-value positions that regular
/// parsers reject.
enum BodyFormatter {
    /// Formats the body for its kind. Returns `nil` when the text is
    /// already formatted (a no-op that keeps the editor's undo stack
    /// clean); `.text` bodies have no format step.
    static func format(_ source: String, kind: RawBodyKind) throws -> String? {
        do {
            switch kind {
            case .json: return try JSONFormat.format(source)
            case .xml: return try XMLFormat.format(source)
            case .text: return nil
            }
        } catch let error as TextFormatError {
            throw TextFormatError(message: "Invalid \(kind == .json ? "JSON" : "XML") - \(error.message)")
        } catch {
            throw TextFormatError(message: "Invalid \(kind == .json ? "JSON" : "XML") - Unexpected token")
        }
    }
}

/// Native JSON pretty-printer: 2-space indentation, object members one
/// per line in source order, empty containers inline, scalars byte-for-
/// byte from the source (numbers keep their original spelling). Parses
/// with a structural scanner rather than `JSONSerialization`, whose
/// dictionary round-trip would lose member order and number forms.
private enum JSONFormat {
    private indirect enum Value {
        case object([(String, Value)])
        case array([Value])
        case scalar(String)
    }

    static func format(_ source: String) throws -> String? {
        guard source.contains(where: { !$0.isWhitespace }) else { return nil }
        var scanner = Scanner(source)
        let value = try parseValue(&scanner)
        scanner.skipWhitespace()
        guard scanner.isAtEnd else { throw scanner.error("Unexpected content after the value") }
        let formatted = render(value, depth: 0)
        return formatted == source ? nil : formatted
    }

    private static func parseValue(_ scanner: inout Scanner) throws -> Value {
        scanner.skipWhitespace()
        guard let first = scanner.peek() else { throw scanner.error("Expected a value") }
        // `{{` starts an opaque placeholder wherever a value is expected;
        // it plays the role of any scalar the request-time resolver fills.
        if scanner.hasPrefix("{{") {
            return .scalar(try scanner.scanOpaqueBraces())
        }
        switch first {
        case "{": return try parseObject(&scanner)
        case "[": return try parseArray(&scanner)
        case "\"": return .scalar(try scanner.scanString())
        case _ where first == "-" || (first >= "0" && first <= "9"):
            return .scalar(scanner.scanNumber())
        case _:
            return .scalar(try scanner.scanLiteral())
        }
    }

    private static func parseObject(_ scanner: inout Scanner) throws -> Value {
        scanner.advance()  // {
        var members: [(String, Value)] = []
        while true {
            scanner.skipWhitespace()
            guard let next = scanner.peek() else { throw scanner.error("Unclosed object") }
            if next == "}" {
                scanner.advance()
                return .object(members)
            }
            let key: String
            if scanner.hasPrefix("{{") {
                key = try scanner.scanOpaqueBraces()
            } else if next == "\"" {
                key = try scanner.scanString()
            } else {
                throw scanner.error("Expected a string key")
            }
            scanner.skipWhitespace()
            guard scanner.pop() == ":" else { throw scanner.error("Expected ':' after the key") }
            let value = try parseValue(&scanner)
            members.append((key, value))
            scanner.skipWhitespace()
            switch scanner.pop() {
            case ",": continue
            case "}": return .object(members)
            case let commaOrBrace:
                if commaOrBrace == nil {
                    throw scanner.error("Unclosed object")
                }
                throw scanner.error("Expected ',' or '}'")
            }
        }
    }

    private static func parseArray(_ scanner: inout Scanner) throws -> Value {
        scanner.advance()  // [
        var items: [Value] = []
        while true {
            scanner.skipWhitespace()
            guard let next = scanner.peek() else { throw scanner.error("Unclosed array") }
            if next == "]" {
                scanner.advance()
                return .array(items)
            }
            items.append(try parseValue(&scanner))
            scanner.skipWhitespace()
            switch scanner.pop() {
            case ",": continue
            case "]": return .array(items)
            case _:
                throw scanner.error("Expected ',' or ']'")
            }
        }
    }

    /// Builds 2-space-indented lines; empty containers stay inline.
    private static func render(_ value: Value, depth: Int) -> String {
        switch value {
        case .scalar(let text):
            return text
        case .object(let members) where members.isEmpty:
            return "{}"
        case .object(let members):
            let lines = members.map { key, member in
                Scanner.indent(depth + 1) + key + ": " + render(member, depth: depth + 1)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + Scanner.indent(depth) + "}"
        case .array(let items) where items.isEmpty:
            return "[]"
        case .array(let items):
            let lines = items.map { Scanner.indent(depth + 1) + render($0, depth: depth + 1) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + Scanner.indent(depth) + "]"
        }
    }
}

/// Native XML pretty-printer: elements nest with 2-space indentation,
/// declaration/comment/DOCTYPE lines are kept verbatim, and attributes
/// keep their source order and spelling. Whitespace-only text between
/// elements is dropped (the xmllint `--format` rule), while text content -
/// including `{{placeholder}}` runs and CDATA - is copied verbatim. Empty
/// and leaf elements collapse back onto one line (`<a></a>`,
/// `<a>text</a>`).
private enum XMLFormat {
    static func format(_ source: String) throws -> String? {
        guard source.contains(where: { !$0.isWhitespace }) else { return nil }
        var scanner = Scanner(source)
        var lines: [String] = []
        var depth = 0
        var openStack: [String] = []

        while true {
            // Whitespace-only text between tokens never reaches the output:
            // the structure's own newlines and re-indent cover it.
            scanner.skipWhitespace()
            if scanner.isAtEnd { break }
            if scanner.hasPrefix("<") {
                if scanner.hasPrefix("</") {
                    let close = try scanner.scanTagClose()
                    guard let top = openStack.popLast() else {
                        throw scanner.error("Unexpected </\(close.name)>")
                    }
                    guard top == close.name else {
                        throw scanner.error("Mismatched </\(close.name)>, expected </\(top)>")
                    }
                    depth -= 1
                    lines.append(Scanner.indent(depth) + close.slice)
                } else if scanner.hasPrefix("<?") {
                    lines.append(
                        Scanner.indent(depth)
                            + (try scanner.scanThrough(
                                "?>", unterminated: "Unterminated processing instruction")))
                } else if scanner.hasPrefix("<!--") {
                    lines.append(Scanner.indent(depth) + (try scanner.scanThrough("-->", unterminated: "Unterminated comment")))
                } else if scanner.hasPrefix("<![CDATA[") {
                    guard !openStack.isEmpty else {
                        throw scanner.error("Unexpected content outside the root element")
                    }
                    lines.append(
                        Scanner.indent(depth)
                            + (try scanner.scanThrough(
                                "]]>", unterminated: "Unterminated CDATA section")))
                } else if scanner.hasPrefix("<!") {
                    lines.append(Scanner.indent(depth) + (try scanner.scanDoctype()))
                } else {
                    // An element: empty and leaf elements collapse back onto
                    // the open tag's line; anything with children indents.
                    let open = try scanner.scanTagOpen()
                    if open.selfClosing {
                        lines.append(Scanner.indent(depth) + open.slice)
                    } else if let leaf = try scanner.tryCollapseLeaf(openName: open.name, openSlice: open.slice) {
                        lines.append(Scanner.indent(depth) + leaf)
                    } else {
                        lines.append(Scanner.indent(depth) + open.slice)
                        depth += 1
                        openStack.append(open.name)
                    }
                }
            } else {
                guard !openStack.isEmpty else {
                    throw scanner.error("Unexpected content outside the root element")
                }
                lines.append(Scanner.indent(depth) + trimTextTail(scanner.scanText()))
            }
        }
        guard openStack.isEmpty else {
            throw scanner.error("Unclosed <\(openStack.last ?? "")>")
        }
        let formatted = lines.joined(separator: "\n")
        return formatted == source ? nil : formatted
    }

    /// Non-leaf text runs keep their inner line breaks verbatim, but the
    /// whitespace tail before the next tag is re-created by the emitter
    /// itself (`\n` + the next line's indent); drop it only when it
    /// crosses a line break so single-line spacers (`x <b/>`) stay
    /// byte-exact and reformats converge.
    private static func trimTextTail(_ text: String) -> String {
        var kept = text.count
        var sawBreak = false
        for character in text.reversed() {
            guard
                character == " " || character == "\t" || character == "\n"
                    || character == "\r"
            else { break }
            if character == "\n" { sawBreak = true }
            kept -= 1
        }
        return sawBreak ? String(text.prefix(kept)) : text
    }
}

/// The open-tag read: whole slice (with attributes), element name, and
/// whether the tag ends in `/>`.
private struct OpenTag {
    var slice: String
    var name: String
    var selfClosing: Bool
}

/// Forward cursor over the body text. The scanners read characters
/// straight from an array so braces, quotes and terminators are
/// unambiguous, and diagnostics carry a 1-based line/column.
private struct Scanner {
    let chars: [Character]
    private(set) var pos = 0

    init(_ source: String) {
        chars = Array(source)
    }

    static func indent(_ depth: Int) -> String {
        String(repeating: "  ", count: depth)
    }

    var isAtEnd: Bool { pos >= chars.count }

    func peek(_ ahead: Int = 0) -> Character? {
        pos + ahead >= 0 && pos + ahead < chars.count ? chars[pos + ahead] : nil
    }

    mutating func advance(_ count: Int = 1) { pos += count }

    mutating func pop() -> Character? {
        guard !isAtEnd else { return nil }
        defer { pos += 1 }
        return chars[pos]
    }

    func hasPrefix(_ prefix: String) -> Bool {
        let end = pos + prefix.count
        return end <= chars.count && String(chars[pos..<end]) == prefix
    }

    func slice(_ start: Int, _ end: Int) -> String {
        String(chars[start..<end])
    }

    mutating func skipWhitespace() {
        while let character = peek(), character == " " || character == "\t" || character == "\n" || character == "\r" {
            advance()
        }
    }

    /// Reads to the terminator (consumed) and returns the whole token;
    /// plain slices only - PIs, comments and CDATA never nest.
    mutating func scanThrough(_ terminator: String, unterminated: String) throws -> String {
        let start = pos
        while !isAtEnd {
            if hasPrefix(terminator) {
                advance(terminator.count)
                return slice(start, pos)
            }
            advance()
        }
        throw error(unterminated)
    }

    /// `<!DOCTYPE …>` with any `>` inside an internal subset `[ … ]`.
    mutating func scanDoctype() throws -> String {
        let start = pos
        advance()  // <
        var held = 0
        while true {
            guard let character = pop() else { throw error("Unterminated <!…> declaration") }
            switch character {
            case "[": held += 1
            case "]": held -= 1
            case ">" where held == 0:
                return slice(start, pos)
            default: break
            }
        }
    }

    /// `<name …>` or `<name/>`: to the tag end with quoted attribute values
    /// skipped, name cut out, and self-closing detected from the character
    /// before `>` (outside quotes only that position holds `/`).
    mutating func scanTagOpen() throws -> OpenTag {
        let start = pos
        advance()  // <
        let nameStart = pos
        let separators: Set<Character> = [">", "/", " ", "\t", "\n", "\r"]
        while let character = peek(), !separators.contains(character) {
            advance()
        }
        guard pos > nameStart else { throw error("Invalid element name") }
        let name = slice(nameStart, pos)
        var lastPlain = -1
        while true {
            guard let character = peek() else { throw error("Unclosed <\(name)>") }
            if character == "\"" || character == "'" {
                advance()
                while true {
                    guard let quoted = peek() else { throw error("Unterminated attribute value") }
                    advance()
                    if quoted == character { break }
                }
            } else if character == ">" {
                advance()
                break
            } else {
                if character != " " && character != "\t" && character != "\n" && character != "\r" { lastPlain = pos }
                advance()
            }
        }
        let selfClosing = lastPlain >= 0 && chars[lastPlain] == "/"
        return OpenTag(
            slice: slice(start, pos),
            name: name,
            selfClosing: selfClosing)
    }

    mutating func scanTagClose() throws -> (slice: String, name: String) {
        let start = pos
        advance(2)  // </
        let nameStart = pos
        while peek() != nil && peek() != ">" {
            advance()
        }
        guard peek() == ">" else { throw error("Unclosed closing tag") }
        advance()  // >
        let name = slice(nameStart, pos - 1).filter {
            $0 != " " && $0 != "\t" && $0 != "\n" && $0 != "\r"
        }
        guard !name.isEmpty else { throw error("Expected a tag name") }
        return (slice(start, pos), name)
    }

    mutating func scanText() -> String {
        let start = pos
        while let character = peek(), character != "<" {
            advance()
        }
        return slice(start, pos)
    }

    /// Collapses `<a></a>` and the one-line leaf `<a>text</a>` where the
    /// close tag follows the immediate content; runs on a copy and only
    /// commits the cursor when it matches. Multi-line text keeps its own
    /// line structure and gets no collapse.
    mutating func tryCollapseLeaf(openName: String, openSlice: String) throws -> String? {
        var probe = self
        probe.skipWhitespace()
        guard !probe.isAtEnd else { return nil }
        if probe.hasPrefix("</") {
            let close = try probe.scanTagClose()
            guard close.name == openName else {
                throw probe.error("Mismatched </\(close.name)>, expected </\(openName)>")
            }
            pos = probe.pos
            return openSlice + close.slice
        }
        guard !probe.hasPrefix("<") || probe.hasPrefix("<![CDATA[") else { return nil }
        let textStart = probe.pos
        if probe.hasPrefix("<![CDATA[") {
            _ = try probe.scanThrough("]]>", unterminated: "Unterminated CDATA section")
        } else {
            while let character = probe.peek(), character != "<" {
                probe.advance()
            }
        }
        let text = probe.slice(textStart, probe.pos)
        guard !text.contains("\n") else { return nil }
        probe.skipWhitespace()
        // Mixed content: the text is a sibling of more children - the open
        // path re-eats it as its own line later.
        guard probe.hasPrefix("</") else { return nil }
        let close = try probe.scanTagClose()
        guard close.name == openName else {
            throw probe.error("Mismatched </\(close.name)>, expected </\(openName)>")
        }
        pos = probe.pos
        return openSlice + text + close.slice
    }

    // MARK: JSON token scans

    /// A JSON string: opening quote is current, escapes skipped.
    mutating func scanString() throws -> String {
        let start = pos
        advance()
        while true {
            guard let character = peek() else { throw error("Unterminated string") }
            if character == "\\" {
                guard peek(1) != nil else { throw error("Unterminated string") }
                advance(2)
            } else if character == "\"" {
                advance()
                return slice(start, pos)
            } else {
                advance()
            }
        }
    }

    mutating func scanNumber() -> String {
        let start = pos
        while let character = peek(), "-+.eE".contains(character) || ("0"..."9").contains(character) {
            advance()
        }
        return slice(start, pos)
    }

    mutating func scanLiteral() throws -> String {
        for literal in ["true", "false", "null"] where hasPrefix(literal) {
            advance(literal.count)
            return literal
        }
        throw error("Unexpected token")
    }

    /// `{{ … }}` placeholder: an opaque token the request-time resolver
    /// fills, played here as any scalar. The first `}}` closes it.
    mutating func scanOpaqueBraces() throws -> String {
        let start = pos
        advance(2)
        while true {
            if peek() == "}", peek(1) == "}" {
                advance(2)
                return slice(start, pos)
            }
            guard !isAtEnd else { throw error("Unterminated placeholder") }
            advance()
        }
    }

    func error(_ message: String) -> TextFormatError {
        TextFormatError(message: "\(message) (line \(line), column \(column))")
    }

    private var line: Int {
        chars[..<pos].filter { $0 == "\n" }.count + 1
    }

    private var column: Int {
        let consumed = chars[..<pos]
        guard let lastBreak = consumed.lastIndex(where: { $0 == "\n" }) else {
            return consumed.count + 1
        }
        return pos - consumed.distance(from: consumed.startIndex, to: lastBreak)
    }
}
