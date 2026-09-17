import AppKit
import SwiftUI

/// Font tokens for the AppKit-backed variable editors: `NSFont` for the text
/// views, SwiftUI `Font` for the placeholder overlay. Sizes mirror the
/// `AppFont` monospaced tokens (subheadline 11, body 13).
enum VariableEditorFont {
    case monoSubheadline
    case monoBody
    case monoURLBar

    var swiftUIFont: Font {
        switch self {
        case .monoSubheadline: AppFont.monoSubheadline
        case .monoBody: AppFont.monoBody
        case .monoURLBar: AppFont.monoCaption
        }
    }

    var nsFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var size: CGFloat {
        switch self {
        case .monoSubheadline: 11
        case .monoBody: 13
        case .monoURLBar: 12
        }
    }
}

/// A text editor that highlights `{{variable}}` placeholders: green
/// background when the variable resolves in scope, amber when it does not
/// (matching the inspector's "Unresolved Placeholders" warning), and
/// completes variable names while typing: `{{` opens a suggestion popup
/// below the caret, arrow keys navigate, Return/Tab insert, Escape dismisses.
///
/// Both backends are AppKit text views so they can share one completion
/// controller (caret rect, key interception) and one placeholder tinting
/// implementation. Single-line editors are NSTextField-backed: TextEditor
/// ignores `lineLimit` on macOS, so long text (a long URL) wraps into
/// multiple lines instead of scrolling - the field keeps the whole value on
/// one line and pans horizontally, like a real URL bar. Multi-line editors
/// are NSTextView-backed: TextEditor offers no caret or key access, which
/// the completion popup needs.
struct VariableHighlightEditor<FocusValue: Hashable>: View {
    @Binding var text: String
    var variables: [String: String] = [:]
    /// Completion candidates with scope metadata; nil derives names from
    /// `variables`.
    var suggestions: [VariableSuggestion]?
    /// Single-line editors run on a no-wrap, horizontally-scrolling AppKit
    /// text field (URL-bar behavior).
    var isSingleLine: Bool = true
    var wrapsWhenFocused: Bool = false
    /// Fill-container editors (the raw body) stretch to the available height
    /// instead of growing with their content.
    var fillsContainer: Bool = false
    var font: VariableEditorFont = .monoSubheadline
    var placeholder: String?
    /// Leading inset of the empty-state placeholder overlay. Matches the
    /// AppKit text origin: the wrapping URL bar runs zero fragment padding
    /// (text starts at the view edge), every other editor keeps the standard
    /// padding, so only the URL bar overrides this to zero.
    var placeholderLeadingPadding: CGFloat = AppSpacing.compact
    /// Optional programmatic focus wiring, for containers that move keyboard
    /// focus between cells (e.g. the key/value table's ghost row). A plain
    /// binding, deliberately NOT a `@FocusState`: the single-line editors are
    /// AppKit fields whose first responder is managed here, so a `@FocusState`
    /// (never registered with `.focused()`, which does not bridge to
    /// NSTextField) made writes no-ops and reads always nil - focus moves
    /// silently failed and the stale-nil comparison re-focused the field on
    /// every update, restarting its editing session (fresh sessions select
    /// all, so the next keystroke overwrote the whole text).
    var focus: Binding<FocusValue?>?
    var focusValue: FocusValue?
    /// Whether the AppKit field may grab first responder during SwiftUI
    /// updates. The key/value table needs it (ghost-row focus moves); a
    /// single-line display surface whose popup owns the keystrokes must opt
    /// out: force-focusing an NSTextField mid-typing starts a fresh editing
    /// session whose select-all replaces the whole text with the next
    /// keystroke.
    var autoFocusOnUpdate: Bool = true
    /// Called after this field's editing session ends, whatever took the
    /// focus elsewhere (the key/value table uses it to settle the ghost row
    /// once the materialized row owns the content).
    var onEditingEnded: (() -> Void)?
    /// Whether the AppKit field accepts typing. The inherited-authorization
    /// echo renders fields read-only but selectable, so values still copy.
    var isEditable: Bool = true
    /// Syntax foreground colors for the multi-line editor (the raw request
    /// body): JSON/XML token colors under the `{{variable}}` background
    /// tints. Single-line editors always stay plain.
    var syntax: BodySyntax = .plain
    /// Called when the user presses Return with no completion popup open
    /// (multi-line editors insert a line break instead).
    var onCommit: (() -> Void)?
    /// Single-line only: reports the live field-editor caret location on
    /// every caret move (click, arrow, typing). Containers that float a
    /// second editing surface over this one (the URL bar -> URL popup
    /// handoff) use it to continue typing at the same offset.
    var onCaretChange: ((Int) -> Void)?
    /// Multi-line only: caret location to apply when this editor takes over
    /// keyboard focus (first responder) from the single-line field, so the
    /// takeover continues at the offset the user had placed there instead of
    /// the fresh text view's default.
    var incomingCaretLocation: Int?

    /// Cap of the auto-grow editor height before it scrolls internally.
    /// Computed: static stored properties are unsupported on generic types.
    private var multiLineMaxHeight: CGFloat { 96 }

    @State private var contentHeight: CGFloat = 40
    @State private var urlContentHeight: CGFloat = 24

    init(
        text: Binding<String>,
        variables: [String: String] = [:],
        suggestions: [VariableSuggestion]? = nil,
        isSingleLine: Bool = true,
        wrapsWhenFocused: Bool = false,
        fillsContainer: Bool = false,
        font: VariableEditorFont = .monoSubheadline,
        placeholder: String? = nil,
        placeholderLeadingPadding: CGFloat = AppSpacing.compact,
        focus: Binding<FocusValue?>? = nil,
        focusValue: FocusValue? = nil,
        autoFocusOnUpdate: Bool = true,
        isEditable: Bool = true,
        onEditingEnded: (() -> Void)? = nil,
        onCommit: (() -> Void)? = nil,
        syntax: BodySyntax = .plain,
        onCaretChange: ((Int) -> Void)? = nil,
        incomingCaretLocation: Int? = nil
    ) {
        self._text = text
        self.variables = variables
        self.suggestions = suggestions
        self.isSingleLine = isSingleLine
        self.wrapsWhenFocused = wrapsWhenFocused
        self.fillsContainer = fillsContainer
        self.font = font
        self.placeholder = placeholder
        self.placeholderLeadingPadding = placeholderLeadingPadding
        self.focus = focus
        self.focusValue = focusValue
        self.autoFocusOnUpdate = autoFocusOnUpdate
        self.isEditable = isEditable
        self.onEditingEnded = onEditingEnded
        self.onCommit = onCommit
        self.syntax = syntax
        self.onCaretChange = onCaretChange
        self.incomingCaretLocation = incomingCaretLocation
    }

    var body: some View {
        Group {
            if isSingleLine {
                SingleLineField(
                    text: $text,
                    variables: variables,
                    suggestions: effectiveSuggestions,
                    font: font,
                    placeholder: placeholder,
                    focus: focus,
                    focusValue: focusValue,
                    autoFocusOnUpdate: autoFocusOnUpdate,
                    isEditable: isEditable,
                    onEditingEnded: onEditingEnded,
                    onCommit: onCommit,
                    onCaretChange: onCaretChange
                )
                .frame(minHeight: 24, alignment: .center)
            } else if wrapsWhenFocused {
                WrappingURLField(
                    text: $text,
                    variables: variables,
                    suggestions: effectiveSuggestions,
                    font: font,
                    placeholder: placeholder,
                    focus: focus,
                    focusValue: focusValue,
                    autoFocusOnUpdate: autoFocusOnUpdate,
                    isFocusedNow: focus?.wrappedValue == focusValue,
                    onCommit: onCommit,
                    onContentHeightChange: { newHeight in
                        // updateNSView runs inside SwiftUI's update transaction,
                        // where a synchronous @State write is silently dropped
                        // (measured 39, frame stayed 24). Defer one runloop so
                        // it applies; ordering is preserved (FIFO).
                        DispatchQueue.main.async { urlContentHeight = newHeight }
                    }
                )
                .frame(
                    height: focus?.wrappedValue == focusValue
                        ? max(urlContentHeight, WrappingURLField<FocusValue>.collapsedHeight)
                        : WrappingURLField<FocusValue>.collapsedHeight,
                    alignment: .top
                )
            } else {
                multiLine
                    .frame(
                        height: fillsContainer ? nil : min(max(contentHeight, 1), multiLineMaxHeight)
                    )
            }
        }
        .overlay(alignment: .topLeading) {
            // Multi-line placeholder; the single-line field uses NSTextField's
            // native placeholder.
            if !isSingleLine, text.isEmpty, let placeholder {
                Text(placeholder)
                    .font(font.swiftUIFont)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, placeholderLeadingPadding)
                    .padding(.top, AppSpacing.xSmall)
                    .allowsHitTesting(false)
            }
        }
    }

    private var multiLine: some View {
        MultiLineField(
            text: $text,
            variables: variables,
            suggestions: effectiveSuggestions,
            font: font,
            fillsContainer: fillsContainer,
            focus: focus,
            focusValue: focusValue,
            onEditingEnded: onEditingEnded,
            onCommit: onCommit,
            onContentHeightChange: fillsContainer ? nil : { contentHeight = $0 },
            syntax: syntax,
            incomingCaretLocation: incomingCaretLocation
        )
    }

    /// Completion candidates: explicit scope-derived suggestions when
    /// provided, otherwise names derived from the resolved dictionary.
    private var effectiveSuggestions: [VariableSuggestion] {
        suggestions ?? VariableSuggestion.suggestions(from: variables)
    }
}

/// Shared `{{variable}}` tinting for the AppKit-backed editors.
private enum VariablePlaceholderStyling {
    /// The full attributed value for `text`: mono font, optional syntax
    /// foreground colors, plus tinted `{{variable}}` runs.
    static func attributed(
        _ plain: String,
        font: VariableEditorFont,
        variables: [String: String],
        syntax: BodySyntax = .plain,
        lineBreakMode: NSLineBreakMode? = nil
    ) -> NSAttributedString {
        // The break mode must ride on the paragraph style: the typesetter
        // consults it first and ignores the text container's own
        // `lineBreakMode` (verified: container-only char wrapping never took
        // effect). Nil keeps every other editor byte-identical.
        // Replacing text storage also replaces NSTextView's textColor:
        // keep a dynamic foreground on every run instead of defaulting to black.
        var base: [NSAttributedString.Key: Any] = [
            .font: font.nsFont,
            .foregroundColor: NSColor.labelColor,
        ]
        if let lineBreakMode {
            base[.paragraphStyle] = paragraphStyle(lineBreakMode: lineBreakMode)
        }
        let out = NSMutableAttributedString(string: plain, attributes: base)
        if let runs = SyntaxHighlight.foregroundRuns(in: plain, syntax: syntax) {
            for (range, color) in runs {
                out.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        for (range, name) in variableRanges(in: plain) {
            out.addAttribute(.backgroundColor, value: tint(name, in: variables), range: range)
        }
        return out
    }

    static func tint(_ name: String, in variables: [String: String]) -> NSColor {
        NSColor(variables[name] != nil ? AppColor.success : AppColor.warning).withAlphaComponent(0.22)
    }

    /// Fresh paragraph style carrying a line break mode (see `attributed`).
    static func paragraphStyle(lineBreakMode: NSLineBreakMode) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
        return style.copy() as? NSParagraphStyle ?? style
    }

    /// UTF-16 ranges of every `{{name}}` run with the trimmed name.
    /// Delegates to `VariableResolver` - the same parser resolution uses -
    /// so tinting never disagrees with what send/highlight counts as a
    /// placeholder (the old manual `{{`-to-`}}` scan tinted inputs like
    /// `{{a}b}}` that resolution ignores).
    static func variableRanges(in source: String) -> [(NSRange, String)] {
        VariableResolver.ranges(in: source).map { ($0.range, $0.key) }
    }
}

/// NSTextField-backed single-line editor: no wrap, horizontal auto-scroll,
/// with `{{variable}}` runs tinted via the attributed value and `{{`
/// completion driven by the field editor.
private struct SingleLineField<FocusValue: Hashable>: NSViewRepresentable {
    @Binding var text: String
    let variables: [String: String]
    let suggestions: [VariableSuggestion]
    let font: VariableEditorFont
    let placeholder: String?
    let focus: Binding<FocusValue?>?
    let focusValue: FocusValue?
    let autoFocusOnUpdate: Bool
    let isEditable: Bool
    let onEditingEnded: (() -> Void)?
    let onCommit: (() -> Void)?
    let onCaretChange: ((Int) -> Void)?
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        // The inherited-authorization echo reads its fields; keep them
        // selectable so values still copy, just not editable.
        field.isEditable = isEditable
        field.isSelectable = true
        field.font = font.nsFont
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.attributedStringValue = VariablePlaceholderStyling.attributed(text, font: font, variables: variables)
        field.delegate = context.coordinator
        context.coordinator.completion.setCandidates(suggestions)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.completion.setCandidates(suggestions)

        if field.stringValue != text {
            // External change (params-table recomposition, request switch):
            // rebuild the field, keeping the caret if it happens to be focused.
            coordinator.completion.hide()
            let editor = field.currentEditor() as? NSTextView
            let selection = editor?.selectedRange()
            field.attributedStringValue = VariablePlaceholderStyling.attributed(text, font: font, variables: variables)
            if let editor {
                editor.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
            }
        } else if coordinator.lastVariables != variables {
            // Variable scope changed (environment switch): re-tint in place.
            if field.currentEditor() != nil {
                coordinator.restyle(field)
            } else {
                field.attributedStringValue = VariablePlaceholderStyling.attributed(text, font: font, variables: variables)
            }
            coordinator.lastVariables = variables
        }

        // Programmatic focus moves (the key/value table's ghost row).
        // Editors that opt out (`autoFocusOnUpdate` false) never touch focus
        // here: force-focusing an NSTextField starts a new editing session,
        // and a fresh session selects all - so a field that regains focus
        // between keystrokes replaces the whole text with the next character.
        // When this editor DOES take focus programmatically, collapse that
        // fresh session's select-all to a caret at the end: the materialized
        // row already holds the first character, and typing must continue it,
        // not overwrite it.
        guard autoFocusOnUpdate, let focus, let focusValue else { return }
        guard focus.wrappedValue == focusValue, field.currentEditor() == nil else { return }
        if field.window != nil {
            Self.focusField(field)
        } else {
            // The first update runs before SwiftUI attaches the view to the
            // window, where makeFirstResponder would be a silent no-op; retry
            // once the view is in place (idempotent: the state is re-checked).
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let coordinator,
                    coordinator.parent.focus?.wrappedValue == focusValue,
                    field.currentEditor() == nil
                else { return }
                Self.focusField(field)
            }
        }
    }

    /// Takes first responder and collapses the fresh session's select-all to
    /// a caret at the end of the text.
    @MainActor
    private static func focusField(_ field: NSTextField) {
        field.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: (field.stringValue as NSString).length, length: 0))
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.completion.hide()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        fileprivate var parent: SingleLineField
        fileprivate var lastVariables: [String: String] = [:]
        fileprivate let completion = VariableCompletionController()

        init(_ parent: SingleLineField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Mirror the caret AFTER the inserted character: the floating
            // popup reads this when it takes over keyboard focus.
            if let editor = field.currentEditor() {
                parent.onCaretChange?(editor.selectedRange.location)
            }
            // Defensive: single-line values never carry line breaks.
            var value = field.stringValue
            if value.contains("\n") || value.contains("\r") {
                value =
                    value
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                field.stringValue = value
            }
            parent.text = value
            restyle(field)
            if let editor = field.currentEditor() as? NSTextView {
                completion.textChanged(editor)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // Mirror the click caret: the field editor's selection change on
            // session start is not forwarded via textViewDidChangeSelection.
            if let field = notification.object as? NSTextField, let editor = field.currentEditor() {
                parent.onCaretChange?(editor.selectedRange.location)
            }
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue != focusValue
            else { return }
            focus.wrappedValue = focusValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            completion.hide()
            clearFocusClaim()
            parent.onEditingEnded?()
        }

        /// Drops the focus claim when this field still holds it.
        private func clearFocusClaim() {
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue == focusValue
            else { return }
            focus.wrappedValue = nil
        }

        /// Field-editor caret moves (arrow keys, clicks): keep an open popup
        /// glued to the caret.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.onCaretChange?(editor.selectedRange.location)
            completion.selectionChanged(editor)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if completion.handleCommand(commandSelector) { return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let onCommit = parent.onCommit {
                onCommit()
                return true
            }
            return false
        }

        /// Re-tint the live field editor in place - replacing
        /// `attributedStringValue` mid-edit would reset the caret and the
        /// undo stack.
        func restyle(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView,
                let storage = editor.textStorage
            else { return }
            let length = (storage.string as NSString).length
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: length))
            for (range, name) in VariablePlaceholderStyling.variableRanges(in: storage.string) {
                storage.addAttribute(
                    .backgroundColor,
                    value: VariablePlaceholderStyling.tint(name, in: parent.variables),
                    range: range
                )
            }
        }
    }
}

/// NSTextView that reports actual first-responder changes. The
/// `NSTextViewDelegate` editing notifications (`textDidBeginEditing` /
/// `textDidEndEditing`) track the editing session, not keyboard focus: a
/// click that only moves the caret never starts a session, so relying on
/// them leaves the SwiftUI focus mirror stale (no ring, no expansion until
/// the first keystroke). Responder overrides fire on every click-away too,
/// which the editing notifications miss.
private final class FocusObservingTextView: NSTextView {
    var onDidBecomeFirstResponder: (() -> Void)?
    var onDidResignFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onDidBecomeFirstResponder?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onDidResignFirstResponder?() }
        return ok
    }
}

/// NSTextView-backed URL-bar editor that wraps in place while focused:
/// collapsed it is a fixed-height single line (no wrap, long URLs scroll
/// horizontally like a real URL bar, the line vertically centered),
/// focused it wraps and auto-grows with the content (the container clips
/// the growth into an overlay). One persistent text view - no focus-time
/// view swap, so the caret and undo stack survive the expand/collapse.
/// Return commits (drops focus) instead of inserting a line break; pasted
/// line breaks are stripped.
private struct WrappingURLField<FocusValue: Hashable>: NSViewRepresentable {
    /// Collapsed single-line height. The centering math in `updateNSView`
    /// must use this same value, or the line drifts off-center.
    /// Computed: static stored properties are unsupported on generic types.
    static var collapsedHeight: CGFloat { 24 }
    @Binding var text: String
    let variables: [String: String]
    let suggestions: [VariableSuggestion]
    let font: VariableEditorFont
    let placeholder: String?
    let focus: Binding<FocusValue?>?
    let focusValue: FocusValue?
    let autoFocusOnUpdate: Bool
    let isFocusedNow: Bool
    let onCommit: (() -> Void)?
    let onContentHeightChange: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.completion.setCandidates(suggestions)
        coordinator.lastVariables = variables

        let textView = FocusObservingTextView()
        textView.onDidBecomeFirstResponder = { [weak coordinator] in coordinator?.claimFocus() }
        textView.onDidResignFirstResponder = { [weak coordinator] in coordinator?.didResignFocus() }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
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
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // Character wrapping lives on the paragraph style (see
        // `VariablePlaceholderStyling.attributed`): the typesetter consults
        // it first and ignores the container's own `lineBreakMode`, which is
        // kept here only as defense in depth. URLs have no spaces, so word
        // wrapping would break only at `/` and leave the first line half
        // empty. (Collapsed single-line mode never wraps, so this only
        // affects the focused expansion.)
        textView.textContainer?.lineBreakMode = .byCharWrapping
        // Zero fragment padding: the text starts exactly at the view edge on
        // both sides (the SwiftUI padding outside supplies the symmetric
        // border gap), so the collapsed clip and the wrapped lines share one
        // origin and the first line breaks identically in both modes.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.typingAttributes = [
            .font: font.nsFont,
            .foregroundColor: NSColor.labelColor,
            // Fresh typing (e.g. after select-all + delete) inherits this
            // paragraph, so retyped URLs keep character wrapping.
            .paragraphStyle: VariablePlaceholderStyling.paragraphStyle(lineBreakMode: .byCharWrapping),
        ]
        textView.textStorage?.setAttributedString(
            VariablePlaceholderStyling.attributed(
                text, font: font, variables: variables, lineBreakMode: .byCharWrapping
            )
        )
        textView.delegate = coordinator

        let scrollView = LayoutObservingScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.onLayout = { [weak coordinator, weak textView, weak scrollView] in
            guard let coordinator, let textView, let scrollView else { return }
            // Post-settle healing (see `healWidths`): converges widths the
            // update pass may have measured transiently, then reports.
            coordinator.healWidths(scrollView: scrollView, textView: textView)
            coordinator.reportContentHeight(textView)
        }
        coordinator.startMouseDownWatch(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.completion.setCandidates(suggestions)
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            coordinator.completion.hide()
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                VariablePlaceholderStyling.attributed(
                    text, font: font, variables: variables, lineBreakMode: .byCharWrapping
                )
            )
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            coordinator.lastVariables = variables
            coordinator.reportContentHeight(textView)
        } else if coordinator.lastVariables != variables {
            coordinator.lastVariables = variables
            if textView.window?.firstResponder === textView {
                coordinator.restyle(textView)
            } else {
                textView.textStorage?.setAttributedString(
                    VariablePlaceholderStyling.attributed(
                        text, font: font, variables: variables, lineBreakMode: .byCharWrapping
                    )
                )
            }
        }

        // Stateless geometry: every update re-asserts the full layout for the
        // current focus state. A latched one-shot transition proved
        // deadlock-prone (one ineffective pass stuck the bar forever with no
        // retry); these assignments are idempotent and URL-scale cheap, so
        // convergence beats latching.
        let collapsed = !isFocusedNow
        Self.applyBarGeometry(
            collapsed: collapsed, textView: textView, scrollView: scrollView, nsFont: font.nsFont)
        coordinator.reportContentHeight(textView)
        if !collapsed {
            // Post-layout guarantee: if the bar is still unwrapped after the
            // synchronous pass (used wider than the wrap width), re-apply
            // once settled. Short URLs never trigger this - a fitting single
            // line is legitimate - and the follow-up never chains (no loop).
            let layoutManager = textView.layoutManager
            let container = textView.textContainer
            if let layoutManager, let container {
                let wrapWidth = scrollView.contentSize.width
                let used = layoutManager.usedRect(for: container)
                if wrapWidth > 1, used.width > wrapWidth + 1 {
                    let nsFont = font.nsFont
                    DispatchQueue.main.async { [weak textView, weak scrollView, weak coordinator] in
                        guard let textView, let scrollView, let coordinator,
                            coordinator.parent.focus?.wrappedValue == coordinator.parent.focusValue
                        else { return }
                        Self.applyBarGeometry(
                            collapsed: false, textView: textView, scrollView: scrollView, nsFont: nsFont)
                        coordinator.reportContentHeight(textView)
                    }
                }
            }
        }

        if isFocusedNow {
            if textView.window != nil, textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
        } else if textView.window?.firstResponder === textView {
            // The SwiftUI side cleared the claim (Send, tab switch, method
            // menu): drop AppKit focus so the next click re-enters through
            // becomeFirstResponder and the bar collapses immediately.
            textView.window?.makeFirstResponder(nil)
        }
    }

    /// Idempotent focus-mode geometry for one text view: collapsed is a true
    /// single line (no wrap, horizontally scrolling, vertically centered),
    /// expanded wraps at the clip width. Safe to run on every update and
    /// from the post-layout retry - only layout changes, never the text, so
    /// the caret and undo stack survive. Both modes share the same top
    /// inset, so the first line never moves on focus.
    private static func applyBarGeometry(
        collapsed: Bool, textView: NSTextView, scrollView: NSScrollView, nsFont: NSFont
    ) {
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: nsFont) ?? 15
        let top = max(0, (Self.collapsedHeight - lineHeight) / 2)
        textView.textContainerInset = NSSize(width: 0, height: top)
        if collapsed {
            // No `.width` mask: tiling would pin the document to the clip
            // width and the tail could never scroll into view. `minSize`
            // keeps short text full-width so empty bar area stays clickable.
            textView.autoresizingMask = []
            let minWidth = scrollView.contentSize.width
            if minWidth > 1 {
                textView.minSize = NSSize(width: minWidth, height: 0)
            }
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            let wrapWidth = scrollView.contentSize.width
            if wrapWidth > 1 {
                // Narrow the view first so the tracked container follows
                // synchronously, then pin the width explicitly as well:
                // neither flag alone snaps a wide container back.
                textView.setFrameSize(NSSize(width: wrapWidth, height: textView.frame.height))
                // Fragment padding is zero (see `makeNSView`), so both modes
                // fill from the same origin for the same width: the first
                // line breaks on the same character collapsed and expanded.
                textView.textContainer?.containerSize = NSSize(
                    width: wrapWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            // Container mutations do not reliably invalidate layout on their
            // own - notify explicitly, then lay out synchronously.
            layoutManager.textContainerChangedGeometry(container)
            layoutManager.ensureLayout(for: container)
        }
        // Redraw from the settled layout and bring a possibly scrolled-out
        // caret back into view.
        textView.needsDisplay = true
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopMouseDownWatch()
        coordinator.completion.hide()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var parent: WrappingURLField
        fileprivate var lastVariables: [String: String] = [:]
        fileprivate let completion = VariableCompletionController()
        private var lastReportedHeight: CGFloat = 0
        private weak var watchedScrollView: NSScrollView?
        private var mouseDownMonitor: Any?

        init(_ parent: WrappingURLField) {
            self.parent = parent
        }

        /// Clicking a blank (non-focusable) area never moves AppKit focus on
        /// its own, so the bar would stay expanded. Watch mouse-downs like
        /// the completion popup does and drop the claim for outside clicks;
        /// `updateNSView` then resigns real focus and the bar collapses.
        /// Clicks inside the visible bar or into the suggestion panel keep
        /// editing (the panel is non-activating and must not blur the field).
        fileprivate func startMouseDownWatch(_ scrollView: NSScrollView) {
            watchedScrollView = scrollView
            guard mouseDownMonitor == nil else { return }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleMouseDown(event)
                }
                return event
            }
        }

        fileprivate func stopMouseDownWatch() {
            watchedScrollView = nil
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
                self.mouseDownMonitor = nil
            }
        }

        private func handleMouseDown(_ event: NSEvent) {
            guard parent.focus?.wrappedValue == parent.focusValue,
                let scrollView = watchedScrollView
            else { return }
            // A suggestion pick: the panel never takes focus, editing goes on.
            if let popup = completion.popupWindow, event.window === popup { return }
            if event.window === scrollView.window {
                let location = scrollView.convert(event.locationInWindow, from: nil)
                // Inside the (possibly expanded) visible bar: just caret moves.
                if scrollView.bounds.contains(location) { return }
            }
            clearFocusClaim()
        }

        /// Post-layout width healing, run from `onLayout` (i.e. once geometry
        /// has settled): if the container no longer matches the clip - e.g.
        /// the update pass measured a transient width, or a height-only
        /// relayout never re-fired width tracking - snap it back and let the
        /// caller re-measure. Deliberately scroll-free (never yank the caret
        /// during layout) and converging (no-ops once equal, so no loop).
        fileprivate func healWidths(scrollView: NSScrollView, textView: NSTextView) {
            let clipWidth = scrollView.contentSize.width
            guard clipWidth > 1,
                let container = textView.textContainer
            else { return }
            if parent.focus?.wrappedValue == parent.focusValue {
                guard abs(container.containerSize.width - clipWidth) > 0.5 else { return }
                container.containerSize = NSSize(width: clipWidth, height: CGFloat.greatestFiniteMagnitude)
            } else if abs(textView.minSize.width - clipWidth) > 0.5 {
                textView.minSize = NSSize(width: clipWidth, height: 0)
                return
            } else {
                return
            }
            if let layoutManager = textView.layoutManager {
                layoutManager.textContainerChangedGeometry(container)
                layoutManager.ensureLayout(for: container)
            }
            textView.needsDisplay = true
        }

        /// Real keyboard focus arrived (click or programmatic): claim it so
        /// the ring shows and the field expands before the first keystroke.
        fileprivate func claimFocus() {
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue != focusValue
            else { return }
            focus.wrappedValue = focusValue
        }

        /// Real keyboard focus left (click-away or programmatic resign):
        /// hide the popup, collapse, and drop the claim.
        fileprivate func didResignFocus() {
            completion.hide()
            clearFocusClaim()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            var value = textView.string
            if value.contains("\n") || value.contains("\r") {
                value =
                    value
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                textView.string = value
                // `setString` drops the paragraph style above; restore it so
                // pasted URLs keep character wrapping.
                textView.textStorage?.addAttribute(
                    .paragraphStyle,
                    value: VariablePlaceholderStyling.paragraphStyle(lineBreakMode: .byCharWrapping),
                    range: NSRange(location: 0, length: (value as NSString).length)
                )
            }
            parent.text = value
            restyle(textView)
            completion.textChanged(textView)
            reportContentHeight(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            completion.selectionChanged(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if completion.handleCommand(commandSelector) { return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let onCommit = parent.onCommit {
                onCommit()
                return true
            }
            return false
        }

        func textDidBeginEditing(_ notification: Notification) {
            claimFocus()
        }

        func textDidEndEditing(_ notification: Notification) {
            didResignFocus()
        }

        /// Drops the focus claim when this view still holds it.
        private func clearFocusClaim() {
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue == focusValue
            else { return }
            focus.wrappedValue = nil
        }

        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let length = (storage.string as NSString).length
            let fullRange = NSRange(location: 0, length: length)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            for (range, name) in VariablePlaceholderStyling.variableRanges(in: storage.string) {
                storage.addAttribute(
                    .backgroundColor,
                    value: VariablePlaceholderStyling.tint(name, in: parent.variables),
                    range: range
                )
            }
        }

        /// Reports the laid-out content height so the SwiftUI side can grow
        /// the editor with its content (auto-grow mode only).
        func reportContentHeight(_ textView: NSTextView?) {
            guard let textView,
                let onContentHeightChange = parent.onContentHeightChange,
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else { return }
            // A fresh edit invalidates layout, and `usedRect` reads back
            // empty until it is laid out again (seen as bogus ~9pt reports
            // that would collapse an expanded bar for a frame). Settle first;
            // at URL-bar scale this is trivially cheap.
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let height = ceil(used.height + textView.textContainerInset.height * 2)
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            onContentHeightChange(height)
        }
    }
}

/// NSTextView-backed multi-line editor: text in a scroll view, `{{variable}}`
/// runs tinted like the single-line field, content height reported for
/// auto-grow, and `{{` completion driven by the text view itself.
private struct MultiLineField<FocusValue: Hashable>: NSViewRepresentable {
    @Binding var text: String
    let variables: [String: String]
    let suggestions: [VariableSuggestion]
    let font: VariableEditorFont
    let fillsContainer: Bool
    let focus: Binding<FocusValue?>?
    let focusValue: FocusValue?
    let onEditingEnded: (() -> Void)?
    let onCommit: (() -> Void)?
    let onContentHeightChange: ((CGFloat) -> Void)?
    var syntax: BodySyntax = .plain
    let incomingCaretLocation: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.completion.setCandidates(suggestions)
        coordinator.lastVariables = variables
        coordinator.lastSyntax = syntax

        let textView = NSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
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
        textView.textContainer?.containerSize = NSSize(width: CGFloat(0), height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = [.font: font.nsFont, .foregroundColor: NSColor.labelColor]
        textView.textStorage?.setAttributedString(
            VariablePlaceholderStyling.attributed(text, font: font, variables: variables, syntax: syntax)
        )
        textView.delegate = coordinator

        let scrollView = LayoutObservingScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.onLayout = { [weak coordinator, weak textView] in
            coordinator?.reportContentHeight(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.completion.setCandidates(suggestions)
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            // External change (request switch, popup-binding newline sync):
            // rebuild the content, keeping the caret when it still fits.
            coordinator.completion.hide()
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(
                VariablePlaceholderStyling.attributed(text, font: font, variables: variables, syntax: syntax)
            )
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            coordinator.lastVariables = variables
            coordinator.reportContentHeight(textView)
        } else if coordinator.lastVariables != variables || coordinator.lastSyntax != syntax {
            // Variable scope changed (environment switch) or the raw body
            // kind changed (JSON/XML/Text): re-tint.
            coordinator.lastVariables = variables
            coordinator.lastSyntax = syntax
            if textView.window?.firstResponder === textView {
                coordinator.restyle(textView)
            } else {
                textView.textStorage?.setAttributedString(
                    VariablePlaceholderStyling.attributed(text, font: font, variables: variables, syntax: syntax)
                )
            }
        }

        // Programmatic focus moves (the URL popup hands focus over once
        // inserted). Unlike NSTextField, taking first responder on an
        // NSTextView does not select all, and resigning via nil does not
        // restart anything - both handoffs are safe here.
        guard let focus, let focusValue else { return }
        if focus.wrappedValue == focusValue {
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
                // Continue at the offset the single-line field held when this
                // editor took over (the URL bar -> popup handoff): without
                // this the fresh text view's default caret discards the
                // position the user had placed in the bar.
                if let location = incomingCaretLocation {
                    let length = (textView.string as NSString).length
                    textView.setSelectedRange(NSRange(location: min(location, length), length: 0))
                }
            }
        } else if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.completion.hide()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate var parent: MultiLineField
        fileprivate var lastVariables: [String: String] = [:]
        fileprivate var lastSyntax: BodySyntax = .plain
        fileprivate let completion = VariableCompletionController()
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: MultiLineField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            restyle(textView)
            completion.textChanged(textView)
            reportContentHeight(textView)
        }

        /// Caret moves (arrow keys, clicks): keep an open popup glued to the
        /// caret.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            completion.selectionChanged(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if completion.handleCommand(commandSelector) { return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let onCommit = parent.onCommit {
                onCommit()
                return true
            }
            return false
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue != focusValue
            else { return }
            focus.wrappedValue = focusValue
        }

        func textDidEndEditing(_ notification: Notification) {
            completion.hide()
            clearFocusClaim()
            parent.onEditingEnded?()
        }

        /// Drops the focus claim when this view still holds it.
        private func clearFocusClaim() {
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue == focusValue
            else { return }
            focus.wrappedValue = nil
        }

        /// Re-tint the `{{variable}}` runs in place - rebuilding the storage
        /// mid-edit would reset the caret and the undo stack. Syntax
        /// foreground colors refresh with the same pass.
        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let length = (storage.string as NSString).length
            let fullRange = NSRange(location: 0, length: length)
            storage.removeAttribute(.backgroundColor, range: fullRange)
            storage.removeAttribute(.foregroundColor, range: fullRange)
            if let runs = SyntaxHighlight.foregroundRuns(in: storage.string, syntax: parent.syntax) {
                for (range, color) in runs {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            for (range, name) in VariablePlaceholderStyling.variableRanges(in: storage.string) {
                storage.addAttribute(
                    .backgroundColor,
                    value: VariablePlaceholderStyling.tint(name, in: parent.variables),
                    range: range
                )
            }
        }

        /// Reports the laid-out content height so the SwiftUI side can grow
        /// the editor with its content (auto-grow mode only).
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
    }
}

/// NSScrollView that reports layout passes, so auto-grow editors can track
/// content-height changes caused by width changes (window resizes).
private final class LayoutObservingScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

extension VariableHighlightEditor where FocusValue == Never {
    /// Convenience init for editors without programmatic focus wiring.
    init(
        text: Binding<String>,
        variables: [String: String] = [:],
        suggestions: [VariableSuggestion]? = nil,
        isSingleLine: Bool = true,
        wrapsWhenFocused: Bool = false,
        fillsContainer: Bool = false,
        font: VariableEditorFont = .monoSubheadline,
        placeholder: String? = nil,
        isEditable: Bool = true,
        onCommit: (() -> Void)? = nil
    ) {
        self.init(
            text: text,
            variables: variables,
            suggestions: suggestions,
            isSingleLine: isSingleLine,
            fillsContainer: fillsContainer,
            font: font,
            placeholder: placeholder,
            focus: nil,
            focusValue: nil,
            isEditable: isEditable,
            onCommit: onCommit
        )
    }
}

extension View {
    /// Wraps a borderless variable editor in the standard rounded-border
    /// field chrome (a match of `.textFieldStyle(.roundedBorder)`).
    /// Focused fields swap the hairline for a thicker solid accent border so
    /// the focused surface is unmistakable.
    func variableFieldBordered(isFocused: Bool = false, verticalPadding: CGFloat = AppSpacing.xxSmall) -> some View {
        self
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(AppColor.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(
                        isFocused ? AppColor.accent : AppColor.borderStrong,
                        lineWidth: isFocused ? 2 : 1
                    )
            )
    }
}
