import AppKit
import SwiftUI

/// The lightweight code editor for the Scripts tab and the raw request
/// body: a standalone NSTextView pipeline (no dependency on
/// `VariableHighlightEditor`) with incremental tree-sitter highlighting -
/// each keystroke repaints only the lines the edit (and the parse's
/// changed ranges) touch instead of re-parsing the whole document.
///
/// Kept from the old multi-line editor: `{{variable}}` tints with the
/// completion popup (shared controller), ⌥⇧F formatting through the
/// caller's handler with the diagnostic capsule callback, read-only
/// selectable mode, placeholder, auto-grow and fill-container sizing,
/// plain-text discipline (no rich text, no smart substitutions), undo.
///
/// Code-editor enhancements on top: a line-number gutter, enter-line
/// indent carry (2-space unit, brace expansion between a fresh pair),
/// Tab / Shift-Tab indent and outdent of the selection's lines, bracket
/// and quote auto-pairing with skip-over and selection wrap, and ⌘/
/// comment toggling (line comments for JavaScript, block comments for
/// XML; JSON has no comments and stays untouched).
struct CodeEditor: View {
    @Binding var text: String
    var variables: [String: String] = [:]
    /// Completion candidates with scope metadata; nil derives names from
    /// `variables`.
    var suggestions: [VariableSuggestion]?
    var syntax: BodySyntax = .plain
    var isEditable: Bool = true
    /// Stretch to the available height (Scripts editor, raw body) instead
    /// of growing with the content between the auto-grow bounds.
    var fillsContainer: Bool = false
    var showsLineNumbers: Bool = true
    /// Vertical hairline between the gutter and the text. Off by default -
    /// the numbers alone read clean against the editor fill.
    var showsGutterSeparator: Bool = false
    /// Code typing assists: enter carries indentation (with brace
    /// expansion), Tab/Shift-Tab indent the selection's lines, ⌘/ toggles
    /// comments. Off for prose/paste surfaces where those are surprises.
    var enablesTypingAssist: Bool = true
    var font: VariableEditorFont = .monoSubheadline
    var placeholder: String?
    /// While the editor holds keyboard focus, ⌥⇧F runs its text through
    /// this handler as one undoable step. Returns the formatted text, nil
    /// when already formatted, or throws the diagnostic. Read fresh on
    /// every invocation.
    var formatHandler: ((String) throws -> String?)?
    /// Undo-menu label for the ⌥⇧F step ("Format Script", "Format Body").
    var formatActionName: String = "Format"
    /// Receives a format handler's diagnostic when ⌥⇧F hits text that does
    /// not parse (the transient bottom capsule of the caller).
    var onFormatError: ((String) -> Void)?

    /// Text view insets: the container inset plus the per-fragment padding
    /// make the text origin - the placeholder overlay matches it exactly.
    static let textInset = NSSize(width: 6, height: 6)
    static let fragmentPadding: CGFloat = 5

    /// Auto-grow bounds (fillsContainer = false), matching the old
    /// multi-line editor's description fields.
    private var minHeight: CGFloat { 40 }
    private var maxHeight: CGFloat { 96 }

    @State private var contentHeight: CGFloat = 40
    /// Live gutter width (line-count digits), synced from updateNSView so
    /// the placeholder clears the strip.
    @State private var gutterWidth: CGFloat = 0
    /// Editor-local find/replace state; the find bar overlays the top edge
    /// and the coordinator mirrors the query into its match pass.
    @State private var findState = CodeEditorFindState()
    @State private var findPendingAction: CodeEditorFindAction?
    /// Match count + selected index, pushed back from the coordinator.
    @State private var findCount = 0
    @State private var findIndex: Int?
    /// Go-to-line panel (⌥⌘L); mutually exclusive with the find bar.
    @State private var gotoVisible = false
    @State private var gotoText = ""
    @State private var gotoPendingLine: Int?
    /// Total lines, pushed back for the go-to-line prompt.
    @State private var lineCountHint = 1

    var body: some View {
        CodeEditorRepresentable(
            text: $text,
            variables: variables,
            suggestions: suggestions ?? VariableSuggestion.suggestions(from: variables),
            syntax: syntax,
            isEditable: isEditable,
            fillsContainer: fillsContainer,
            showsLineNumbers: showsLineNumbers,
            showsGutterSeparator: showsGutterSeparator,
            enablesTypingAssist: enablesTypingAssist,
            font: font,
            formatHandler: formatHandler,
            formatActionName: formatActionName,
            onFormatError: onFormatError,
            onContentHeightChange: fillsContainer
                ? nil
                : { newHeight in
                    // updateNSView runs inside SwiftUI's update transaction,
                    // where a synchronous @State write is silently dropped.
                    // Defer one runloop so it applies; ordering is FIFO.
                    DispatchQueue.main.async { contentHeight = newHeight }
                },
            onGutterWidthChange: showsLineNumbers
                ? { newWidth in
                    DispatchQueue.main.async { gutterWidth = newWidth }
                }
                : nil,
            find: findState,
            findAction: findPendingAction,
            onFindActionHandled: { findPendingAction = nil },
            findHooks: CodeEditorFindHooks(
                requested: { selection, replaceMode in
                    findState.visible = true
                    findState.replacing = replaceMode
                    if let selection, !selection.isEmpty { findState.query = selection }
                    gotoVisible = false
                },
                countChanged: { count, index in
                    findCount = count
                    findIndex = index
                },
                closed: { findState.visible = false },
                useSelection: { selected in
                    findState.query = selected
                },
                linePanel: {
                    gotoVisible = true
                    gotoText = ""
                    findState.visible = false
                }
            ),
            gotoLine: gotoPendingLine,
            onGoToLineHandled: { gotoPendingLine = nil },
            onLineCountHint: { lineCountHint = $0 }
        )
        .overlay(alignment: .topTrailing) {
            if findState.visible {
                CodeEditorFindBar(
                    query: $findState.query,
                    replacement: $findState.replacement,
                    caseSensitive: $findState.caseSensitive,
                    replacing: $findState.replacing,
                    matchCount: findCount,
                    matchIndex: findIndex,
                    isEditable: isEditable,
                    onNext: { findPendingAction = .next },
                    onPrevious: { findPendingAction = .previous },
                    onReplace: { findPendingAction = .replaceCurrent },
                    onReplaceAll: { findPendingAction = .replaceAll },
                    onClose: { findState.visible = false }
                )
                .padding(.trailing, AppSpacing.medium)
                .padding(.top, AppSpacing.xSmall)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if gotoVisible {
                CodeEditorGoToLineBar(
                    text: $gotoText,
                    lineCount: lineCountHint,
                    onClose: { gotoVisible = false },
                    onSubmit: {
                        if let line = Int(gotoText) { gotoPendingLine = line }
                        gotoVisible = false
                    }
                )
                .padding(.trailing, AppSpacing.medium)
                .padding(.top, AppSpacing.xSmall)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(
            height: fillsContainer
                ? nil
                : min(max(contentHeight, minHeight), maxHeight),
            alignment: .topLeading
        )
        .overlay(alignment: .topLeading) {
            if text.isEmpty, let placeholder, !findState.visible {
                Text(placeholder)
                    .font(font.swiftUIFont)
                    .foregroundStyle(AppColor.tertiaryText)
                    .padding(.leading, Self.textInset.width + Self.fragmentPadding + gutterWidth)
                    .padding(.top, Self.textInset.height)
                    .animation(.easeInOut(duration: 0.15), value: gutterWidth)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - AppKit bridge

struct CodeEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let variables: [String: String]
    let suggestions: [VariableSuggestion]
    let syntax: BodySyntax
    let isEditable: Bool
    let fillsContainer: Bool
    let showsLineNumbers: Bool
    let showsGutterSeparator: Bool
    let enablesTypingAssist: Bool
    let font: VariableEditorFont
    let formatHandler: ((String) throws -> String?)?
    let formatActionName: String
    let onFormatError: ((String) -> Void)?
    let onContentHeightChange: ((CGFloat) -> Void)?
    let onGutterWidthChange: ((CGFloat) -> Void)?
    let find: CodeEditorFindState
    let findAction: CodeEditorFindAction?
    let onFindActionHandled: (() -> Void)?
    let findHooks: CodeEditorFindHooks?
    let gotoLine: Int?
    let onGoToLineHandled: (() -> Void)?
    let onLineCountHint: ((Int) -> Void)?

    func makeCoordinator() -> CodeEditorCoordinator {
        CodeEditorCoordinator(self)
    }

    /// Sizing like the NSScrollView this editor replaced: accept whatever
    /// the stack proposes (falls back to the constraint-derived fitting
    /// size only when a dimension is unconstrained). The default NSView
    /// sizing reports the constraint minimum (gutter width × 0), which
    /// reads as a zero-ideal editor - VSplitView/VStack then hand the
    /// pane's spare space to the other rows, which inflate into blank
    /// bands and squeeze the editor out.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CodeEditorRootView,
        context: Context
    ) -> CGSize? {
        let fitting = nsView.fittingSize
        return CGSize(
            width: proposal.width ?? fitting.width,
            height: proposal.height ?? fitting.height)
    }
    func makeNSView(context: Context) -> CodeEditorRootView {
        let coordinator = context.coordinator

        let textView = CodeEditorTextView()
        textView.focusRingType = .none
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = AppColor.textPrimaryNS
        textView.insertionPointColor = NSColor(AppColor.accent)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = CodeEditor.textInset
        textView.typingAttributes = [.font: font.nsFont, .foregroundColor: AppColor.textPrimaryNS]
        textView.delegate = coordinator
        textView.editorCoordinator = coordinator
        textView.textStorage?.delegate = coordinator

        let scrollView = CodeEditorScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        if fillsContainer {
            // Scroll past end: the last line can ride above the bottom edge
            // instead of gluing to it (auto-grow editors never scroll).
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 48, right: 0)
        }
        scrollView.onLayout = { [weak coordinator, weak textView] in
            // Paint invalidation only. Nothing here may mutate layout
            // (constraints, frames): this runs inside AppKit's layout pass,
            // and rescheduling layout from within it can starve the hosting
            // view's layer commits - the sibling SwiftUI rows around the
            // editor would blank out while AppKit-drawn content keeps
            // painting.
            coordinator?.reportContentHeight(textView)
            coordinator?.redrawGutter()
        }

        let root = CodeEditorRootView(
            textView: textView,
            scrollView: scrollView,
            showsGutter: showsLineNumbers)
        coordinator.rootView = root
        guard let gutter = root.gutterView else { return root }
        gutter.textView = textView
        gutter.showsSeparator = showsGutterSeparator
        gutter.observeScroll(of: scrollView)
        gutter.highlighter = coordinator.highlighter
        gutter.font = font.nsFont

        // Initial fill through the standard pipeline: setting the storage
        // fires the text-storage delegate, which parses and paints.
        coordinator.replaceAll(text, in: textView)
        return root
    }

    func updateNSView(_ root: CodeEditorRootView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.completion.setCandidates(suggestions)
        guard let textView = root.textView else { return }
        textView.isEditable = isEditable

        // Gutter width lives in the SwiftUI update pass: idempotent, runs
        // before layout, never re-enters layout from inside it.
        if let gutter = root.gutterView {
            gutter.font = font.nsFont
            let width = gutter.requiredWidth()
            root.setGutterWidth(width)
            gutter.needsDisplay = true
            onGutterWidthChange?(width)
        }

        if textView.string != text {
            // External change (request switch, phase switch, popup sync):
            // full replace through the standard pipeline, caret preserved
            // when it still fits.
            coordinator.replaceAll(text, in: textView)
        } else if coordinator.lastVariables != variables || coordinator.lastSyntax != syntax {
            // Variable scope changed (environment switch) or the raw body
            // kind changed (JSON/XML/Text): re-style from scratch. Rare -
            // the full static pass is fine here.
            coordinator.lastVariables = variables
            coordinator.lastSyntax = syntax
            coordinator.highlighter.setSyntax(syntax)
            coordinator.refreshStyling(in: textView)
        }
        if let gutter = root.gutterView {
            gutter.font = font.nsFont
        }

        // Find/action/goto pipeline (missing from the original: buttons
        // and go-to-line actions set state but never executed). Actions are
        // processed synchronously for immediate feedback; SwiftUI-state
        // clears are deferred (synchronous writes inside update transactions
        // are silently dropped) and tracked locally so re-renders don't
        // re-execute.
        if let action = findAction, action != coordinator.lastProcessedFindAction {
            coordinator.performFindAction(action, in: textView)
            coordinator.lastProcessedFindAction = action
            DispatchQueue.main.async { onFindActionHandled?() }
        }
        if let line = gotoLine, line != coordinator.lastProcessedGotoLine {
            coordinator.gotoLine = line
            coordinator.goToLine(line, in: textView)
            coordinator.lastProcessedGotoLine = line
            DispatchQueue.main.async { onGoToLineHandled?() }
        }
        coordinator.syncFindState(find, in: textView)
    }
    static func dismantleNSView(_ root: CodeEditorRootView, coordinator: CodeEditorCoordinator) {
        coordinator.completion.hide()
    }
}

/// Root container laying the gutter left of the scroll view with explicit
/// constraints (no stack view: the gutter width is a live constraint).
final class CodeEditorRootView: NSView {
    private(set) weak var textView: NSTextView?
    private(set) weak var gutterView: CodeEditorGutterView?
    private let gutterWidthConstraint: NSLayoutConstraint

    init(textView: NSTextView, scrollView: NSScrollView, showsGutter: Bool) {
        self.textView = textView
        let gutter = CodeEditorGutterView(frame: .zero)
        gutterView = gutter
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutterWidthConstraint = gutter.widthAnchor.constraint(equalToConstant: 30)
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidthConstraint,
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        gutter.isHidden = !showsGutter
    }

    func setGutterWidth(_ width: CGFloat) {
        guard let gutterView, !gutterView.isHidden else { return }
        gutterWidthConstraint.constant = width
    }

    required init?(coder: NSCoder) {
        fatalError("CodeEditorRootView is created in code only")
    }
}

/// NSScrollView that reports layout passes, so the auto-grow editor tracks
/// content-height changes caused by width changes (window resizes) and the
/// gutter redraws after rewraps.
final class CodeEditorScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// NSTextView with the editor's key surfaces: ⌥⇧F formatting (intercepted
/// in `keyDown` - AppKit routes only Command-carrying events through
/// `performKeyEquivalent`, so an Option+Shift press would sail past as the
/// composed character), ⌘/ comment toggling, and bracket/quote smart
/// insertion in `insertText`.
final class CodeEditorTextView: NSTextView, NSViewToolTipOwner {
    weak var editorCoordinator: CodeEditorCoordinator?
    /// The current-line band's last drawn rect (for targeted invalidation).
    private var lineBandRect: NSRect = .zero
    /// The registered tooltip rect's tag + the bounds it covers (re-registered
    /// when the view grows, so hovers work over newly revealed content).
    private var tooltipTag: NSView.ToolTipTag?
    private var tooltipBounds: NSRect = .zero

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isFormatKey =
            modifiers == [.option, .shift]
            && (event.keyCode == 0x03 || event.charactersIgnoringModifiers?.lowercased() == "f")
        if isFormatKey, window?.firstResponder === self, let editorCoordinator,
            editorCoordinator.applyFormat(self)
        {
            return
        }
        // Esc: the completion popup wins; otherwise a visible find bar closes.
        if event.keyCode == 53, window?.firstResponder === self, let editorCoordinator,
            !editorCoordinator.completion.isVisible, editorCoordinator.parent.find.visible
        {
            editorCoordinator.closeFind(in: self)
            return
        }
        // ⌘⌫: delete to the logical line's start (a selection keeps the
        // platform's delete-selection behavior).
        if modifiers == [.command], event.keyCode == 51,
            window?.firstResponder === self, selectedRange().length == 0,
            let editorCoordinator
        {
            editorCoordinator.deleteToLogicalLineStart(in: self)
            return
        }
        // Right arrow: jump past a closing bracket/quote when the caret
        // sits right before it, so the paired character does not trap the
        // caret between the pair.
        if event.keyCode == 124, selectedRange().length == 0, !string.isEmpty {
            let caret = selectedRange().location
            let text = string as NSString
            if caret < text.length {
                let char = codeEditorChar(text, caret)
                if ")]}".contains(char ?? " ") || char == "\"" || char == "'" || char == "`" {
                    let newLocation = min(caret + 1, text.length)
                    setSelectedRange(NSRange(location: newLocation, length: 0))
                    scrollRangeToVisible(NSRange(location: newLocation, length: 0))
                    return
                }
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard window?.firstResponder === self, let coordinator = editorCoordinator else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "/" {
            if coordinator.toggleComment(self) { return true }
            return super.performKeyEquivalent(with: event)
        }
        guard isEditable || Self.isNavigationEquivalent(event: event, modifiers: modifiers) else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "f" {
            coordinator.requestFind(replaceMode: false, in: self)
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "f" {
            coordinator.requestFind(replaceMode: true, in: self)
            return true
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "g" {
            coordinator.performFindAction(.next, in: self)
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "g" {
            coordinator.performFindAction(.previous, in: self)
            return true
        }
        if modifiers == [.command, .shift], event.keyCode == 43 {
            coordinator.jumpToMatchingBracket(in: self)
            return true
        }
        if modifiers == [.command], event.charactersIgnoringModifiers == "d" {
            coordinator.duplicateLines(in: self)
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "k" {
            coordinator.deleteLines(in: self)
            return true
        }
        if modifiers == [.command, .control], event.keyCode == 126 {
            coordinator.moveLines(in: self, up: true)
            return true
        }
        if modifiers == [.command, .control], event.keyCode == 125 {
            coordinator.moveLines(in: self, up: false)
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "l" {
            coordinator.requestLinePanel(in: self)
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "e" {
            coordinator.useSelectionForFind(in: self)
            return true
        }
        if modifiers == [.command, .option, .shift], event.charactersIgnoringModifiers == "v" {
            coordinator.pasteAndFormat(in: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Navigation equivalents (⌘F/⌘G and friends) stay live in read-only
    /// editors; editing ones do not.
    private static func isNavigationEquivalent(event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers == [.command], ["f", "g"].contains(event.charactersIgnoringModifiers ?? "") {
            return true
        }
        if modifiers == [.command, .option], event.charactersIgnoringModifiers == "f" {
            return true
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers == "g" {
            return true
        }
        return false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerTooltipRect()
    }

    override func layout() {
        super.layout()
        registerTooltipRect()
    }

    /// One tooltip rect covering the view; re-registered when the bounds
    /// grow (the owner hit-tests by point, so the rect just needs to cover
    /// the area the mouse can be in).
    private func registerTooltipRect() {
        guard window != nil, bounds != tooltipBounds else { return }
        if let tooltipTag { removeToolTip(tooltipTag) }
        tooltipBounds = bounds
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    /// Hover over an error squiggle: the diagnostic with its line/column.
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let coordinator = editorCoordinator, let layoutManager, let textContainer else { return "" }
        let characterIndex = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        for (index, range) in coordinator.diagnosticRanges.enumerated()
        where NSLocationInRange(characterIndex, range) {
            let position = coordinator.highlighter.lineAndColumn(ofUTF16Offset: range.location)
            let message =
                index < coordinator.diagnosticMessages.count
                ? coordinator.diagnosticMessages[index] : "Syntax error"
            return "\(message) (line \(position.line), column \(position.column))"
        }
        return ""
    }

    /// The band behind the caret's line, drawn before the text (the view's
    /// background is transparent, so the fill shows through).
    override func draw(_ dirtyRect: NSRect) {
        if lineBandRect.width > 0, lineBandRect.height > 0 {
            AppColor.textPrimaryNS.withAlphaComponent(0.04).setFill()
            lineBandRect.intersection(dirtyRect).fill()
        }
        drawIndentGuides(dirtyRect: dirtyRect)
        super.draw(dirtyRect)
    }

    /// Faint vertical guides at every indent level of each visible line
    /// fragment (the project's 2-space unit). Drawn under the text; wrapped
    /// continuations carry no leading whitespace and get none.
    private func drawIndentGuides(dirtyRect: NSRect) {
        guard let layoutManager = layoutManager, let container = textContainer,
            !string.isEmpty
        else { return }
        let nsString = string as NSString
        let unitWidth = ("  " as NSString).size(withAttributes: [.font: font]).width
        guard unitWidth > 0 else { return }
        let bounding = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounding, in: container)
        let guideColor = AppColor.textPrimaryNS.withAlphaComponent(0.12)
        guideColor.setFill()
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while index < end {
            var fragmentGlyphs = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            let charRange = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            let leading = nsString.substring(with: charRange).prefix { $0 == " " }.count
            let level = leading / 2
            if level > 0 {
                let baseX = fragment.minX + textContainerOrigin.x + CodeEditor.fragmentPadding
                for levelIndex in 0..<min(level, 12) {
                    NSRect(
                        x: baseX + CGFloat(levelIndex) * unitWidth,
                        y: fragment.minY + textContainerOrigin.y,
                        width: 1,
                        height: fragment.height
                    ).fill()
                }
            }
            index = NSMaxRange(fragmentGlyphs)
        }
    }

    /// Recomputes the caret line's band and invalidates the old and new
    /// rects. Called on selection changes and after edits.
    func refreshLineBand() {
        let previous = lineBandRect
        lineBandRect = Self.computeLineBand(for: self)
        if previous != lineBandRect {
            setNeedsDisplay(previous.insetBy(dx: -2, dy: -2))
            setNeedsDisplay(lineBandRect.insetBy(dx: -2, dy: -2))
        }
    }

    private static func computeLineBand(for textView: NSTextView) -> NSRect {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
            !textView.string.isEmpty
        else { return .zero }
        let length = (textView.string as NSString).length
        let caret = min(textView.selectedRange().location, length)
        let charRange = (textView.string as NSString).lineRange(for: NSRange(location: caret, length: 0))
        guard charRange.length > 0 else { return .zero }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var band = NSRect.zero
        var first = true
        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        while index < end {
            var fragmentGlyphs = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &fragmentGlyphs)
            // Fragment rects live in the container's coordinates.
            let viewRect = fragment.offsetBy(
                dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            band = first ? viewRect : band.union(viewRect)
            first = false
            index = NSMaxRange(fragmentGlyphs)
        }
        return band
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let coordinator = editorCoordinator else { return menu }
        let editable = isEditable

        func item(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags, _ action: Selector, _ enabled: Bool) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = mask
            menuItem.target = self
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }

        menu.addItem(.separator())
        item("Format", "f", [.option, .shift], #selector(menuFormat), editable && coordinator.canFormat(self))
        item("Toggle Comment", "/", [.command], #selector(menuToggleComment), editable && coordinator.supportsComments)
        menu.addItem(.separator())
        item("Duplicate Lines", "d", [.command], #selector(menuDuplicateLines), editable)
        item("Delete Lines", "k", [.command, .shift], #selector(menuDeleteLines), editable)
        let upKey = String(UnicodeScalar(NSUpArrowFunctionKey) ?? "?")
        let downKey = String(UnicodeScalar(NSDownArrowFunctionKey) ?? "?")
        item("Move Line Up", upKey, [.control, .command], #selector(menuMoveLinesUp), editable)
        item("Move Line Down", downKey, [.control, .command], #selector(menuMoveLinesDown), editable)
        menu.addItem(.separator())
        item("Paste and Format", "v", [.command, .option, .shift], #selector(menuPasteAndFormat), editable && coordinator.canFormat(self))
        item("Go to Line…", "l", [.command, .option], #selector(menuGoToLine), true)
        item("Use Selection for Find", "e", [.command, .option], #selector(menuUseSelectionForFind), selectedRange().length > 0)
        return menu
    }

    @objc private func menuFormat() { editorCoordinator?.applyFormat(self) }
    @objc private func menuToggleComment() { _ = editorCoordinator?.toggleComment(self) }
    @objc private func menuDuplicateLines() { editorCoordinator?.duplicateLines(in: self) }
    @objc private func menuDeleteLines() { editorCoordinator?.deleteLines(in: self) }
    @objc private func menuMoveLinesUp() { editorCoordinator?.moveLines(in: self, up: true) }
    @objc private func menuMoveLinesDown() { editorCoordinator?.moveLines(in: self, up: false) }
    @objc private func menuFind() { editorCoordinator?.requestFind(replaceMode: false, in: self) }
    @objc private func menuPasteAndFormat() { editorCoordinator?.pasteAndFormat(in: self) }
    @objc private func menuGoToLine() { editorCoordinator?.requestLinePanel(in: self) }
    @objc private func menuUseSelectionForFind() { editorCoordinator?.useSelectionForFind(in: self) }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // Smart pairs only for single plain characters from typing;
        // everything else (multi-char paste, completion acceptance, IME
        // commits, attributed strings) takes the standard path untouched.
        guard let coordinator = editorCoordinator,
            let string = insertString as? String,
            string.count == 1, let character = string.first,
            replacementRange.location == NSNotFound
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        if coordinator.handleTypedCharacter(character, in: self) {
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }
}

// MARK: - Coordinator

@MainActor
final class CodeEditorCoordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    var parent: CodeEditorRepresentable
    fileprivate let completion = VariableCompletionController()
    let highlighter: SourceHighlighter
    fileprivate var lastVariables: [String: String]
    fileprivate var lastSyntax: BodySyntax
    weak var rootView: CodeEditorRootView?
    private var lastReportedHeight: CGFloat = 0
    /// Editor-local find state: all matches of the active query, the
    /// selected one, and the last mirrored find state (for diffing).
    var findMatches: [NSRange] = []
    var findCurrentIndex: Int?
    var lastFindState: CodeEditorFindState?
    /// The currently highlighted bracket pair (temporary attributes).
    var bracketHighlightRanges: [NSRange] = []
    /// The currently washed word-occurrence ranges (temporary attributes).
    var wordHighlightRanges: [NSRange] = []
    /// The currently dashed error-underline ranges (temporary attributes).
    var diagnosticUnderlineRanges: [NSRange] = []
    /// The live diagnostics behind the underlines: range, message, and the
    /// 1-based line (parallel to `diagnosticUnderlineRanges`).
    var diagnosticRanges: [NSRange] = []
    var diagnosticMessages: [String] = []
    var diagnosticLines: [Int] = []
    /// The pending go-to-line number (nil = nothing queued).
    var gotoLine: Int?
    /// Last processed find/goto actions so synchronous SwiftUI-state
    /// clears (dropped inside update transactions) do not re-trigger.
    fileprivate var lastProcessedFindAction: CodeEditorFindAction?
    fileprivate var lastProcessedGotoLine: Int?
    var lastLineCountHint = 1

    fileprivate init(_ parent: CodeEditorRepresentable) {
        self.parent = parent
        self.lastVariables = parent.variables
        self.lastSyntax = parent.syntax
        self.highlighter = SourceHighlighter(syntax: parent.syntax)
        super.init()
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        parent.text = textView.string
        completion.textChanged(textView)
        reportContentHeight(textView)
        invalidateGutter()
        (textView as? CodeEditorTextView)?.refreshLineBand()
        updateBracketHighlight(in: textView)
        updateWordHighlight(in: textView)
    }

    /// Caret moves (arrow keys, clicks): keep an open popup glued to the
    /// caret, refresh the current-line band and the bracket-pair highlight.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        completion.selectionChanged(textView)
        (textView as? CodeEditorTextView)?.refreshLineBand()
        updateBracketHighlight(in: textView)
        updateWordHighlight(in: textView)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if completion.handleCommand(commandSelector) { return true }
        // Typing assists are gated: prose/paste surfaces keep the platform
        // defaults (plain newline, tab character, no comment toggle).
        guard parent.enablesTypingAssist else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            insertNewlineWithIndent(textView)
            return true
        case #selector(NSResponder.insertTab(_:)):
            indentSelection(textView, outdent: false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            indentSelection(textView, outdent: true)
            return true
        default:
            return false
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        completion.hide()
    }

    // MARK: Paint pipeline (text-storage delegate)

    /// Single restyle funnel: every character edit - typing, paste, the
    /// smart-edit helpers, external replaces - lands here with the precise
    /// edited range. The highlighter folds the edit into its parse tree and
    /// returns the repaint window (edited lines ∪ the parse's changed
    /// ranges, line-aligned); this sets base attributes on the window and
    /// layers the syntax runs and `{{variable}}` tints that intersect it.
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Only character edits enter the pipeline; the attribute writes
        // below re-enter with .editedAttributes and must fall through.
        guard editedMask.contains(.editedCharacters) else { return }
        let text = textStorage.string
        let length = (text as NSString).length
        let result = highlighter.edit(text, editedRange: editedRange, delta: delta)

        // Placeholder ranges come from the shared resolver scan; any that
        // touch the window pull the window out to cover them whole, so a
        // multi-line placeholder never ends up half-restyled.
        let tintRanges = VariablePlaceholderStyling.variableRanges(in: text)
        var window = result.window
        for (range, _) in tintRanges where NSIntersectionRange(range, window).length > 0 {
            window = window.union(range)
        }
        guard let clampedWindow = window.clamped(to: length), clampedWindow.length > 0 else {
            return
        }

        // Base attributes reset the window (inserted characters arrive
        // unattributed; pasted runs shed their fonts via isRichText=false,
        // and this normalizes anything else).
        textStorage.setAttributes(
            [.font: parent.font.nsFont, .foregroundColor: AppColor.textPrimaryNS],
            range: clampedWindow)
        if let runs = result.runs {
            for (range, color) in runs {
                let intersection = NSIntersectionRange(range, clampedWindow)
                guard intersection.length > 0 else { continue }
                textStorage.addAttribute(.foregroundColor, value: color, range: intersection)
            }
        }
        for (range, name) in tintRanges {
            let intersection = NSIntersectionRange(range, clampedWindow)
            guard intersection.length > 0 else { continue }
            textStorage.addAttribute(
                .backgroundColor,
                value: VariablePlaceholderStyling.tint(name, in: parent.variables),
                range: intersection)
        }
        invalidateGutter()
        if let textView = rootView?.textView {
            refreshDiagnostics(in: textView)
            if parent.find.visible {
                refreshFindHighlights(in: textView)
            }
        }
    }

    /// Full restyle for scope/kind switches (rare): the shared static
    /// one-shot walk over the whole text.
    func refreshStyling(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(
            [.font: parent.font.nsFont, .foregroundColor: AppColor.textPrimaryNS],
            range: full)
        if let runs = SyntaxHighlight.foregroundRuns(in: storage.string, syntax: parent.syntax) {
            for (range, color) in runs {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        for (range, name) in VariablePlaceholderStyling.variableRanges(in: storage.string) {
            storage.addAttribute(
                .backgroundColor,
                value: VariablePlaceholderStyling.tint(name, in: parent.variables),
                range: range)
        }
    }

    /// External replace: swap the whole content through the standard
    /// pipeline (the storage delegate repaints), keep the caret when it
    /// still fits, retire the popup, refresh the height report.
    func replaceAll(_ text: String, in textView: NSTextView) {
        completion.hide()
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: parent.font.nsFont,
                    .foregroundColor: AppColor.textPrimaryNS,
                ]))
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        lastVariables = parent.variables
        lastSyntax = parent.syntax
        reportContentHeight(textView)
        invalidateGutter()
    }

    func reportContentHeight(_ textView: NSTextView?) {
        guard let textView, let onContentHeightChange = parent.onContentHeightChange,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        let used = layoutManager.usedRect(for: container)
        let height = ceil(used.height + textView.textContainerInset.height * 2)
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onContentHeightChange(height)
    }

    func invalidateGutter() {
        // Paint invalidation only - see the onLayout note: constraint or
        // frame changes from here (storage edits fire inside SwiftUI's
        // makeNSView/updateNSView transactions) would reschedule layout
        // mid-transaction and blank sibling SwiftUI rows.
        redrawGutter()
    }

    func redrawGutter() {
        guard let gutter = rootView?.gutterView else { return }
        gutter.needsDisplay = true
    }

    // MARK: ⌥⇧F formatting

    /// Runs the caller's handler over the text as one undoable step.
    /// Returns false when no handler is installed (the key falls through).
    func applyFormat(_ textView: NSTextView) -> Bool {
        guard textView.isEditable, let formatHandler = parent.formatHandler else { return false }
        do {
            guard let formatted = try formatHandler(textView.string) else { return true }
            let caret = textView.selectedRange().location
            let sourceRange = NSRange(location: 0, length: (textView.string as NSString).length)
            // Registers the undo entry, then the storage edit funnels the
            // replacement through the repaint pipeline via didChangeText.
            guard textView.shouldChangeText(in: sourceRange, replacementString: formatted) else {
                return true
            }
            textView.textStorage?.replaceCharacters(in: sourceRange, with: formatted)
            textView.didChangeText()
            let formattedLength = (formatted as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, formattedLength), length: 0))
            textView.undoManager?.setActionName(parent.formatActionName)
            // Brief visual feedback for successful formatting.
            let originalColor = textView.insertionPointColor
            textView.insertionPointColor = NSColor(AppColor.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                textView.insertionPointColor = originalColor
            }
            return true
        } catch let error as TextFormatError {
            parent.onFormatError?(error.message)
            return true
        } catch {
            parent.onFormatError?("Unexpected token")
            return true
        }
    }

    // MARK: Smart editing

    private static let indentUnit = "  "
    /// Opening characters that auto-close, and quote characters that pair.
    /// `{` deliberately never pairs: in an API client every brace is either
    /// a JSON delimiter or the `{{template}}` opener, and pairing it eats
    /// the `{{` sequence the completion popup needs to trigger.
    private static let openers: [Character: Character] = [
        "(": ")", "[": "]", "\"": "\"", "'": "'", "`": "`",
    ]
    /// Characters skipped over instead of typed when the caret sits right
    /// before them.
    private static let skippers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    /// Bracket/quote smart insertion for a typed character. Consumes the
    /// keystroke (true) for skip-over, pairing, and selection wrap;
    /// anything else falls through to the standard insertion.
    func handleTypedCharacter(_ character: Character, in textView: NSTextView) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText() else { return false }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = selection.location

        // Skip-over: the matching character is already at the caret.
        if Self.skippers.contains(character), caret < text.length,
            char(text, caret) == character
        {
            textView.setSelectedRange(NSRange(location: caret + 1, length: 0))
            return true
        }

        guard let closer = Self.openers[character] else { return false }

        // Quotes never pair in the middle of a word (apostrophes: it's).
        if character == "\"" || character == "'" || character == "`", caret > 0 {
            let previous = char(text, caret - 1)
            if let previous, previous.isLetter || previous.isNumber { return false }
        }

        let next = char(text, caret)
        let nextIsBoundary = next == nil || next?.isWhitespace == true || next.map(Self.skippers.contains) == true

        if selection.length > 0 {
            // Wrap the selection in the pair (quotes included).
            let wrapped = text.substring(with: selection)
            replace(
                in: textView,
                range: selection,
                with: String(character) + wrapped + String(closer),
                caret: caret + (wrapped as NSString).length + 1)
            return true
        }
        if nextIsBoundary {
            replace(
                in: textView,
                range: NSRange(location: caret, length: 0),
                with: String(character) + String(closer),
                caret: caret + 1)
            return true
        }
        return false
    }

    /// Return: carries the current line's indentation; a fresh open brace
    /// before the caret expands to a blank indented line (and closes the
    /// pair when the matching closer sits ahead).
    func insertNewlineWithIndent(_ textView: NSTextView) {
        guard textView.isEditable, !textView.hasMarkedText() else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = selection.location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let line = text.substring(with: lineRange)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let previous = char(text, caret - 1)
        let next = char(text, caret)

        if let previous, let closer = Self.openers[previous] {
            if next == closer {
                // Between a fresh pair: blank indented line between two
                // carried-indent lines, caret in the middle.
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + indent + Self.indentUnit + "\n" + indent,
                    caret: caret + 1 + (indent + Self.indentUnit).count)
            } else {
                replace(
                    in: textView,
                    range: NSRange(location: caret, length: selection.length),
                    with: "\n" + indent + Self.indentUnit,
                    caret: caret + 1 + (indent + Self.indentUnit).count)
            }
            return
        }
        replace(
            in: textView,
            range: NSRange(location: caret, length: selection.length),
            with: "\n" + indent,
            caret: caret + 1 + indent.count)
    }

    /// Tab inserts the indent unit (or indents the selection's lines);
    /// Shift-Tab outdents the selection's lines by one unit.
    func indentSelection(_ textView: NSTextView, outdent: Bool) {
        guard textView.isEditable, !textView.hasMarkedText() else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let unit = Self.indentUnit
        if !outdent, selection.length == 0 {
            replace(
                in: textView,
                range: NSRange(location: selection.location, length: 0),
                with: unit,
                caret: selection.location + unit.count)
            return
        }
        guard
            let selected = selectedBlock(text, selection: selection)
        else { return }

        var lines = selected.block.components(separatedBy: "\n")
        var deltaBeforeCaret = 0
        var consumed = 0
        for index in lines.indices {
            defer { consumed += lines[index].count + 1 }
            let isBlank = lines[index].trimmingCharacters(in: .whitespaces).isEmpty
            guard !isBlank else { continue }
            let before = lines[index]
            if outdent {
                if before.hasPrefix("\t") {
                    lines[index] = String(before.dropFirst())
                } else {
                    var removed = 0
                    while removed < unit.count, lines[index].hasPrefix(" ") {
                        lines[index] = String(lines[index].dropFirst())
                        removed += 1
                    }
                }
            } else {
                lines[index] = unit + lines[index]
            }
            if consumed <= selected.caretOffset {
                deltaBeforeCaret += lines[index].count - before.count
            }
        }
        let newBlock = lines.joined(separator: "\n")
        guard newBlock != selected.block else { return }
        if selection.length == 0 {
            replace(
                in: textView,
                range: selected.range,
                with: newBlock,
                caret: selection.location + deltaBeforeCaret)
        } else {
            // Keep the block selected, like every editor's Tab behavior.
            let newLength = (newBlock as NSString).length
            replace(
                in: textView,
                range: selected.range,
                with: newBlock,
                caret: selected.range.location)
            textView.setSelectedRange(
                NSRange(location: selected.range.location, length: newLength))
        }
    }

    /// ⌘/: line comments for JavaScript, block comments for XML, nothing
    /// for JSON (no comments in the grammar). Returns whether anything
    /// changed, so an unhandled key falls through.
    func toggleComment(_ textView: NSTextView) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText() else { return false }
        switch parent.syntax {
        case .javascript:
            return toggleLineComments(textView)
        case .xml:
            return toggleBlockComment(textView)
        case .json, .plain:
            return false
        }
    }

    /// `// ` line comments: comment when any selected line is uncommented,
    /// uncomment when every non-blank selected line already carries `//`.
    private func toggleLineComments(_ textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard let selected = selectedBlock(text, selection: selection) else {
            return false
        }
        var lines = selected.block.components(separatedBy: "\n")
        var touched = false
        let allCommented = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        for index in lines.indices {
            guard !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let leading = lines[index].prefix { $0 == " " || $0 == "\t" }
            let body = lines[index].dropFirst(leading.count)
            if allCommented {
                var stripped = body
                if stripped.hasPrefix("//") { stripped = stripped.dropFirst(2) }
                if stripped.hasPrefix(" ") { stripped = stripped.dropFirst(1) }
                lines[index] = String(leading + stripped)
            } else {
                lines[index] = String(leading) + "// " + String(body)
            }
            touched = true
        }
        guard touched else { return false }
        let newBlock = lines.joined(separator: "\n")
        let newLength = (newBlock as NSString).length
        replace(
            in: textView,
            range: selected.range,
            with: newBlock,
            caret: selected.range.location)
        textView.setSelectedRange(
            NSRange(location: selected.range.location, length: newLength))
        return true
    }

    /// `<!--  -->` block comments: wrap the selection (or the caret), or
    /// unwrap the comment surrounding the selection.
    private func toggleBlockComment(_ textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let caret = min(selection.location, text.length)
        let before = text.substring(to: caret)
        let afterStart = min(NSMaxRange(selection), text.length)
        let after = text.substring(from: afterStart)

        // Uncomment when a `<!--` before the selection pairs with a `-->`
        // after it (simple surrounding check; comments do not nest).
        let beforeText = before as NSString
        let afterText = after as NSString
        let open = beforeText.range(of: "<!--", options: .backwards)
        let closeInAfter = afterText.range(of: "-->")
        if open.location != NSNotFound, closeInAfter.location != NSNotFound,
            NSMaxRange(open) <= caret,
            afterStart + closeInAfter.location >= NSMaxRange(selection)
        {
            // Remove the closer first (higher offset): " -->" or "-->".
            var closeStart = afterStart + closeInAfter.location
            var closeLength = closeInAfter.length
            if closeStart > 0, char(text, closeStart - 1) == " " {
                closeStart -= 1
                closeLength += 1
            }
            replace(
                in: textView,
                range: NSRange(location: closeStart, length: closeLength),
                with: "",
                caret: caret)
            // Opener after the first replace (offsets below it hold).
            var openLength = open.length
            let currentText = textView.string as NSString
            if NSMaxRange(open) < currentText.length,
                char(currentText, NSMaxRange(open)) == " "
            {
                openLength += 1
            }
            replace(
                in: textView,
                range: NSRange(location: open.location, length: openLength),
                with: "",
                caret: max(caret - openLength, open.location))
            return true
        }

        // Wrap: selection in place, or an empty pair at the caret.
        if selection.length > 0 {
            let wrapped = text.substring(with: selection)
            replace(
                in: textView,
                range: selection,
                with: "<!-- " + wrapped + " -->",
                caret: selection.location + (wrapped as NSString).length + 5)
        } else {
            replace(
                in: textView,
                range: NSRange(location: caret, length: 0),
                with: "<!--  -->",
                caret: caret + 5)
        }
        return true
    }

    // MARK: Shared edit plumbing

    /// The character at a UTF-16 offset, or nil when out of bounds.
    func char(_ text: NSString, _ offset: Int) -> Character? {
        guard offset >= 0, offset < text.length,
            let scalar = UnicodeScalar(text.character(at: offset))
        else { return nil }
        return Character(scalar)
    }

    /// A selected line block: its range (trailing newline excluded), the
    /// text, and the caret's offset within it - the shape every block
    /// transform (indent, outdent, comment toggle) consumes.
    struct SelectedBlock {
        let range: NSRange
        let block: String
        let caretOffset: Int
    }

    /// The line block covering the selection (or the caret's line), with
    /// its trailing newline excluded from the returned range.
    func selectedBlock(
        _ text: NSString,
        selection: NSRange
    ) -> SelectedBlock? {
        var end = selection.location + selection.length
        if selection.length > 0, end > selection.location,
            char(text, end - 1) == "\n"
        {
            end -= 1
        }
        var blockRange = text.lineRange(
            for: NSRange(location: selection.location, length: max(end - selection.location, 0)))
        if blockRange.length > 0,
            char(text, NSMaxRange(blockRange) - 1) == "\n"
        {
            blockRange.length -= 1
        }
        guard blockRange.length > 0 else { return nil }
        return SelectedBlock(
            range: blockRange,
            block: text.substring(with: blockRange),
            caretOffset: selection.location - blockRange.location)
    }

    /// One undoable replacement through the pipeline: registers the undo
    /// entry, funnels the edit through the text-storage delegate (paint +
    /// binding + height), and lands the caret where the caller says.
    @discardableResult
    func replace(
        in textView: NSTextView,
        range: NSRange,
        with replacement: String,
        caret: Int
    ) -> Bool {
        let length = (textView.string as NSString).length
        guard textView.isEditable, range.location >= 0, NSMaxRange(range) <= length else {
            return false
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            return false
        }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        let newLength = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(max(caret, 0), newLength), length: 0))
        return true
    }
}

extension NSRange {
    /// Clamped to `0...length` (a stray NSNotFound must never reach the
    /// storage). Nil when the range would be empty and out of bounds.
    fileprivate func clamped(to length: Int) -> NSRange? {
        guard location != NSNotFound else { return nil }
        let start = min(max(location, 0), length)
        let end = min(max(location + self.length, start), length)
        return NSRange(location: start, length: end - start)
    }
}
