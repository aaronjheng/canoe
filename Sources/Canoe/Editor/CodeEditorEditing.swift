import AppKit

// MARK: - Line operations

extension CodeEditorCoordinator {
    /// ⌘D: duplicates the selection's lines right below, selecting the copy.
    func duplicateLines(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange),
            let currentText = textView.string as NSString?
        else { return }
        let insertLocation = NSMaxRange(selected.range)
        // After the block's last line: `block + \n` normally, `\n + block`
        // at the very end of the document (no newline to lean on there).
        let atEnd = insertLocation >= currentText.length
        let inserted = atEnd ? "\n" + selected.block : selected.block + "\n"
        replace(
            in: textView,
            range: NSRange(location: insertLocation, length: 0),
            with: inserted,
            caret: NSMaxRange(selected.range))
        // Select the copy, like every editor's duplicate.
        let copyStart = atEnd ? insertLocation + 1 : insertLocation
        textView.setSelectedRange(NSRange(location: copyStart, length: (selected.block as NSString).length))
    }

    /// ⌘⇧K: deletes the selection's lines, newline included, so no blank
    /// line is left behind (at the end of the document the preceding
    /// newline goes instead).
    func deleteLines(in textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        var range = NSRange(location: selected.range.location, length: selected.range.length + 1)
        if NSMaxRange(range) > (textView.string as NSString).length {
            // Last line: eat the preceding newline instead.
            range = NSRange(location: selected.range.location - 1, length: selected.range.length + 1)
        }
        guard range.location >= 0 else { return }
        replace(in: textView, range: range, with: "", caret: range.location)
    }

    /// ⌃⌘↑ / ⌃⌘↓: moves the selection's lines one line up/down, keeping
    /// the selection on the moved block.
    func moveLines(in textView: NSTextView, up: Bool) {
        guard textView.isEditable, !textView.hasMarkedText(),
            let selected = selectedBlock(textView.string as NSString, selection: textView.selectedRange)
        else { return }
        let text = textView.string as NSString
        if up {
            guard selected.range.location > 0 else { return }
            // The line above spans up to the newline just before the block.
            let aboveRange = text.lineRange(for: NSRange(location: selected.range.location - 1, length: 0))
            let above = text.substring(with: NSRange(location: aboveRange.location, length: aboveRange.length - 1))
            let span = NSRange(
                location: aboveRange.location,
                length: NSMaxRange(selected.range) - aboveRange.location)
            replace(
                in: textView,
                range: span,
                with: selected.block + "\n" + above,
                caret: span.location)
            textView.setSelectedRange(
                NSRange(
                    location: selected.range.location - aboveRange.length,
                    length: selected.range.length))
        } else {
            // The newline separating the block from the line below belongs
            // to the block in this swap; a block at the end of the document
            // cannot move down.
            guard NSMaxRange(selected.range) < text.length,
                char(text, NSMaxRange(selected.range)) == "\n"
            else { return }
            let belowRange = text.lineRange(
                for: NSRange(location: NSMaxRange(selected.range) + 1, length: 0))
            let belowEnd =
                belowRange.length > 0
                ? NSMaxRange(belowRange) - (char(text, NSMaxRange(belowRange) - 1) == "\n" ? 1 : 0)
                : belowRange.location
            let below = text.substring(with: NSRange(location: belowRange.location, length: belowEnd - belowRange.location))
            let span = NSRange(location: selected.range.location, length: belowEnd - selected.range.location)
            replace(
                in: textView,
                range: span,
                with: below + "\n" + selected.block,
                caret: span.location)
            textView.setSelectedRange(
                NSRange(
                    location: selected.range.location + below.count + 1,
                    length: selected.range.length))
        }
    }
}

// MARK: - Bracket matching

extension CodeEditorCoordinator {
    /// Highlights the bracket pair around the caret: the character before
    /// the caret wins, then the character at it. Temporary foreground
    /// attributes (edits drop them; the next selection change reapplies).
    func updateBracketHighlight(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in bracketHighlightRanges {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        bracketHighlightRanges = []
        guard textView.selectedRange().length == 0 else { return }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        var anchor: Int?
        if caret > 0, Self.isBracket(codeEditorChar(text, caret - 1)) {
            anchor = caret - 1
        } else if caret < length, Self.isBracket(codeEditorChar(text, caret)) {
            anchor = caret
        }
        guard let anchor, let match = bracketMatch(in: text, at: anchor) else { return }
        bracketHighlightRanges = [
            NSRange(location: anchor, length: 1),
            NSRange(location: match, length: 1),
        ]
        for range in bracketHighlightRanges {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor(AppColor.accent), forCharacterRange: range)
        }
    }

    /// ⌘⇧\: lands the caret on the matching bracket.
    func jumpToMatchingBracket(in textView: NSTextView) {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        var anchor: Int?
        if caret > 0, Self.isBracket(codeEditorChar(text, caret - 1)) {
            anchor = caret - 1
        } else if caret < text.length, Self.isBracket(codeEditorChar(text, caret)) {
            anchor = caret
        }
        guard let anchor, let match = bracketMatch(in: text, at: anchor) else { return }
        textView.setSelectedRange(NSRange(location: match, length: 1))
        textView.scrollRangeToVisible(NSRange(location: match, length: 1))
    }

    static func isBracket(_ character: Character?) -> Bool {
        guard let character else { return false }
        return "([{)]}".contains(character)
    }

    /// The matching bracket for the bracket at `pos`, scanning the full
    /// document with a bracket stack (string literals skipped, escapes
    /// honored). One forward pass - backward string detection is unreliable.
    func bracketMatch(in text: NSString, at pos: Int) -> Int? {
        let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
        let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var stack: [(open: Character, pos: Int)] = []
        var inString: Character?
        var index = 0
        let length = text.length
        while index < length {
            let character = codeEditorChar(text, index)
            if let quote = inString {
                if character == "\\" {
                    index += 1
                } else if character == quote {
                    inString = nil
                }
            } else if character == "\"" || character == "'" || character == "`" {
                inString = character
            } else if let closer = closers[character ?? " "], let top = stack.last, top.open == closer {
                if index == pos { return top.pos }
                if top.pos == pos { return index }
                stack.removeLast()
            } else if let character, openers[character] != nil {
                stack.append((character, index))
            }
            index += 1
        }
        return nil
    }
}

/// The character at a UTF-16 offset, or nil when out of bounds. Shared by
/// the coordinator's editing extensions.
func codeEditorChar(_ text: NSString, _ offset: Int) -> Character? {
    guard offset >= 0, offset < text.length,
        let scalar = UnicodeScalar(text.character(at: offset))
    else { return nil }
    return Character(scalar)
}

func isWordChar(_ character: Character?) -> Bool {
    guard let character else { return false }
    return character.isLetter || character.isNumber || character == "_"
}

extension CodeEditorCoordinator {
    /// Whether a format handler is installed (the menu's Format item).
    func canFormat(_ textView: NSTextView) -> Bool {
        parent.formatHandler != nil
    }

    /// Whether the current grammar has comments (drives the menu item).
    var supportsComments: Bool {
        parent.syntax == .javascript || parent.syntax == .xml
    }
}

// MARK: - Go to line / selection for find / delete to line start

extension CodeEditorCoordinator {
    /// ⌥⌘L's submit: lands the caret on the head of line `line` (1-based,
    /// clamped) and scrolls it into view.
    func goToLine(_ line: Int, in textView: NSTextView) {
        let starts = highlighter.lineStartOffsets
        let clamped = min(max(line, 1), max(starts.count, 1))
        let location = starts[clamped - 1]
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// ⌥⌘E: the selection becomes the find query (the bar stays closed; the
    /// next ⌘F searches for it).
    func useSelectionForFind(in textView: NSTextView) {
        let selection = textView.selectedRange()
        guard selection.length > 0, selection.length <= 200 else { return }
        let selected = (textView.string as NSString).substring(with: selection)
        guard !selected.contains("\n") else { return }
        parent.findHooks?.useSelection(selected)
    }

    /// ⌘⌫: deletes from the logical line's start to the caret; at the line
    /// start it deletes the preceding newline (joining the line above).
    /// With a selection the platform's delete-selection applies instead.
    func deleteToLogicalLineStart(in textView: NSTextView) {
        guard textView.isEditable, textView.selectedRange().length == 0,
            !textView.hasMarkedText()
        else { return }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        if caret > lineRange.location {
            replace(
                in: textView,
                range: NSRange(location: lineRange.location, length: caret - lineRange.location),
                with: "",
                caret: lineRange.location)
        } else if caret > 0, codeEditorChar(ns, caret - 1) == "\n" {
            replace(
                in: textView,
                range: NSRange(location: caret - 1, length: 1),
                with: "",
                caret: caret - 1)
        }
    }
}

// MARK: - Word occurrence highlight

extension CodeEditorCoordinator {
    /// Double-click/selection helper: when the selection is a bare word
    /// (letters, digits, underscore, ≤64 chars), washes every occurrence.
    /// Suspended while the find bar owns the background washes.
    func updateWordHighlight(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in wordHighlightRanges {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        wordHighlightRanges = []
        guard !parent.find.visible else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0, selection.length <= 64,
            let word = (textView.string as NSString).substring(with: selection) as String?,
            !word.isEmpty,
            word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return }

        let ns = textView.string as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: length)
        while searchRange.length > 0 {
            let found = ns.range(of: word, options: [.caseInsensitive], range: searchRange)
            guard found.location != NSNotFound else { break }
            // Whole-word: neither neighbor may be a word character.
            let beforeClean =
                found.location == 0
                || !isWordChar(codeEditorChar(ns, found.location - 1))
            let afterClean =
                NSMaxRange(found) >= length
                || !isWordChar(codeEditorChar(ns, NSMaxRange(found)))
            if beforeClean, afterClean {
                ranges.append(found)
            }
            searchRange.location = NSMaxRange(found)
            searchRange.length = length - searchRange.location
        }
        wordHighlightRanges = ranges
        let wash = NSColor(AppColor.accent).withAlphaComponent(0.12)
        for range in ranges {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: range)
        }
    }
}

extension CodeEditorCoordinator {
    /// ⌥⌘L: opens the go-to-line panel (closing the find bar - the two
    /// overlays share the editor's top-right corner).
    func requestLinePanel(in textView: NSTextView) {
        parent.findHooks?.linePanel()
        _ = textView
    }
}

// MARK: - Syntax diagnostics

extension CodeEditorCoordinator {
    /// After every storage edit: dashes the tree's ERROR/MISSING ranges and
    /// marks their lines in the gutter. Capped (20 squiggles, 200 chars
    /// each) so one broken brace early in a huge body doesn't paint half
    /// the document.
    func refreshDiagnostics(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in diagnosticUnderlineRanges {
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
        diagnosticUnderlineRanges = []

        let style = NSNumber(value: NSUnderlineStyle.patternDash.rawValue)
        var errorLines: Set<Int> = []
        var underlineRanges: [NSRange] = []
        for (range, _) in highlighter.diagnostics() where underlineRanges.count < 20 {
            var squiggle = range.clampedToString(length)
            guard squiggle.length > 0 else { continue }
            if squiggle.length > 200 { squiggle.length = 200 }
            underlineRanges.append(squiggle)
            layoutManager.addTemporaryAttribute(.underlineStyle, value: style, forCharacterRange: squiggle)
            layoutManager.addTemporaryAttribute(
                .underlineColor, value: NSColor(AppColor.error), forCharacterRange: squiggle)
            errorLines.insert(highlighter.lineNumber(ofUTF16Offset: squiggle.location))
        }
        diagnosticUnderlineRanges = underlineRanges
        if let gutter = rootView?.gutterView {
            gutter.errorLines = errorLines
            gutter.needsDisplay = true
        }
    }
}

extension NSRange {
    /// Clamped to `0...length`, empty ranges dropped.
    fileprivate func clampedToString(_ length: Int) -> NSRange {
        guard location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let start = min(max(location, 0), length)
        let end = min(max(location + self.length, start), length)
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Paste and format

extension CodeEditorCoordinator {
    /// ⌥⇧⌘V / context menu: pastes the pasteboard string through the
    /// format handler (minified JSON lands pretty-printed). Falls back to
    /// a plain paste when there is no handler, the pasteboard is empty,
    /// or the text does not parse.
    func pasteAndFormat(in textView: NSTextView) {
        guard textView.isEditable,
            let formatHandler = parent.formatHandler,
            let pasted = NSPasteboard.general.string(forType: .string),
            !pasted.isEmpty
        else {
            textView.pasteAsPlainText(nil)
            return
        }
        let formatted: String
        do {
            formatted = try formatHandler(pasted) ?? pasted
        } catch {
            // Unparseable paste falls back to a normal paste; the user can
            // reach the diagnostic through ⌥⇧F on the result.
            textView.pasteAsPlainText(nil)
            return
        }
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: formatted) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: formatted)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + (formatted as NSString).length, length: 0))
    }
}
