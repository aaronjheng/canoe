import AppKit
import SwiftUI

/// Font tokens for the AppKit-backed variable editors: `NSFont` for the text
/// views, SwiftUI `Font` for the placeholder overlay. Sizes mirror the
/// `AppFont` monospaced tokens (subheadline 11, body 13).
enum VariableEditorFont {
    case monoSubheadline
    case monoBody

    var swiftUIFont: Font {
        switch self {
        case .monoSubheadline: AppFont.monoSubheadline
        case .monoBody: AppFont.monoBody
        }
    }

    var nsFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var size: CGFloat {
        switch self {
        case .monoSubheadline: 11
        case .monoBody: 13
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
    /// Fill-container editors (the raw body) stretch to the available height
    /// instead of growing with their content.
    var fillsContainer: Bool = false
    var font: VariableEditorFont = .monoSubheadline
    var placeholder: String?
    /// Optional programmatic focus wiring, for containers that move keyboard
    /// focus between cells (e.g. the key/value table's ghost row).
    var focus: FocusState<FocusValue?>.Binding?
    var focusValue: FocusValue?
    /// Called when the user presses Return with no completion popup open
    /// (multi-line editors insert a line break instead).
    var onCommit: (() -> Void)?

    /// Cap of the auto-grow editor height before it scrolls internally.
    /// Computed: static stored properties are unsupported on generic types.
    private var multiLineMaxHeight: CGFloat { 96 }

    @State private var contentHeight: CGFloat = 40

    init(
        text: Binding<String>,
        variables: [String: String] = [:],
        suggestions: [VariableSuggestion]? = nil,
        isSingleLine: Bool = true,
        fillsContainer: Bool = false,
        font: VariableEditorFont = .monoSubheadline,
        placeholder: String? = nil,
        focus: FocusState<FocusValue?>.Binding? = nil,
        focusValue: FocusValue? = nil,
        onCommit: (() -> Void)? = nil
    ) {
        self._text = text
        self.variables = variables
        self.suggestions = suggestions
        self.isSingleLine = isSingleLine
        self.fillsContainer = fillsContainer
        self.font = font
        self.placeholder = placeholder
        if let focus { self.focus = focus }
        if let focusValue { self.focusValue = focusValue }
        self.onCommit = onCommit
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
                    onCommit: onCommit
                )
                .frame(minHeight: 24, alignment: .center)
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
                    .padding(.leading, 6)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var multiLine: some View {
        let field = MultiLineField(
            text: $text,
            variables: variables,
            suggestions: effectiveSuggestions,
            font: font,
            fillsContainer: fillsContainer,
            focus: focus,
            focusValue: focusValue,
            onCommit: onCommit,
            onContentHeightChange: fillsContainer ? nil : { contentHeight = $0 }
        )
        return Group {
            if let focus, let focusValue {
                field.focused(focus, equals: focusValue)
            } else {
                field
            }
        }
    }

    /// Completion candidates: explicit scope-derived suggestions when
    /// provided, otherwise names derived from the resolved dictionary.
    private var effectiveSuggestions: [VariableSuggestion] {
        suggestions ?? VariableSuggestion.suggestions(from: variables)
    }
}

/// Shared `{{variable}}` tinting for the AppKit-backed editors.
private enum VariablePlaceholderStyling {
    /// The full attributed value for `text`: mono font plus tinted
    /// `{{variable}}` runs.
    static func attributed(_ plain: String, font: VariableEditorFont, variables: [String: String]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: plain, attributes: [.font: font.nsFont])
        for (range, name) in variableRanges(in: plain) {
            out.addAttribute(.backgroundColor, value: tint(name, in: variables), range: range)
        }
        return out
    }

    static func tint(_ name: String, in variables: [String: String]) -> NSColor {
        NSColor(variables[name] != nil ? AppColor.success : AppColor.warning).withAlphaComponent(0.22)
    }

    /// UTF-16 ranges of every `{{name}}` run with the trimmed name.
    static func variableRanges(in source: String) -> [(NSRange, String)] {
        let ns = source as NSString
        var ranges: [(NSRange, String)] = []
        var searchStart = 0
        while searchStart < ns.length {
            let open = ns.range(of: "{{", options: [], range: NSRange(location: searchStart, length: ns.length - searchStart))
            guard open.location != NSNotFound else { break }
            let close = ns.range(of: "}}", options: [], range: NSRange(location: open.location + 2, length: ns.length - open.location - 2))
            guard close.location != NSNotFound else { break }
            let range = NSRange(location: open.location, length: close.location + close.length - open.location)
            let name = ns.substring(with: NSRange(location: open.location + 2, length: close.location - open.location - 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ranges.append((range, name))
            searchStart = close.location + close.length
        }
        return ranges
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
    let focus: FocusState<FocusValue?>.Binding?
    let focusValue: FocusValue?
    let onCommit: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
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
        guard let focus, let focusValue else { return }
        if focus.wrappedValue == focusValue {
            if field.currentEditor() == nil {
                field.window?.makeFirstResponder(field)
            }
        } else if field.currentEditor() != nil {
            // Commit and blur: moving first responder back to the field itself
            // ends the field-editor session (NSText has no commit-and-blur API).
            field.window?.makeFirstResponder(field)
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
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue != focusValue
            else { return }
            focus.wrappedValue = focusValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            completion.hide()
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue == focusValue
            else { return }
            focus.wrappedValue = nil
        }

        /// Field-editor caret moves (arrow keys, clicks): keep an open popup
        /// glued to the caret.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
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

/// NSTextView-backed multi-line editor: text in a scroll view, `{{variable}}`
/// runs tinted like the single-line field, content height reported for
/// auto-grow, and `{{` completion driven by the text view itself.
private struct MultiLineField<FocusValue: Hashable>: NSViewRepresentable {
    @Binding var text: String
    let variables: [String: String]
    let suggestions: [VariableSuggestion]
    let font: VariableEditorFont
    let fillsContainer: Bool
    let focus: FocusState<FocusValue?>.Binding?
    let focusValue: FocusValue?
    let onCommit: (() -> Void)?
    let onContentHeightChange: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.completion.setCandidates(suggestions)
        coordinator.lastVariables = variables

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
            VariablePlaceholderStyling.attributed(text, font: font, variables: variables)
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
                VariablePlaceholderStyling.attributed(text, font: font, variables: variables)
            )
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            coordinator.lastVariables = variables
            coordinator.reportContentHeight(textView)
        } else if coordinator.lastVariables != variables {
            // Variable scope changed (environment switch): re-tint.
            coordinator.lastVariables = variables
            if textView.window?.firstResponder === textView {
                coordinator.restyle(textView)
            } else {
                textView.textStorage?.setAttributedString(
                    VariablePlaceholderStyling.attributed(text, font: font, variables: variables)
                )
            }
        }

        // Programmatic focus moves (the URL popup hands focus over once
        // inserted).
        guard let focus, let focusValue else { return }
        if focus.wrappedValue == focusValue {
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
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
            guard let focus = parent.focus, let focusValue = parent.focusValue,
                focus.wrappedValue == focusValue
            else { return }
            focus.wrappedValue = nil
        }

        /// Re-tint the `{{variable}}` runs in place - rebuilding the storage
        /// mid-edit would reset the caret and the undo stack.
        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
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
        fillsContainer: Bool = false,
        font: VariableEditorFont = .monoSubheadline,
        placeholder: String? = nil,
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
            onCommit: onCommit
        )
    }
}

extension View {
    /// Wraps a borderless variable editor in the standard rounded-border
    /// field chrome (a match of `.textFieldStyle(.roundedBorder)`).
    /// Focused fields use the stronger border so keyboard focus is visible.
    func variableFieldBordered(isFocused: Bool = false) -> some View {
        self
            .padding(.horizontal, AppSpacing.small - AppSpacing.xxSmall)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                    .strokeBorder(isFocused ? AppColor.accent.opacity(0.55) : AppColor.borderStrong, lineWidth: 1)
            )
    }
}
