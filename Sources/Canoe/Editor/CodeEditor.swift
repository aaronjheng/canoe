import AppKit
import Plume
import SwiftUI

/// Canoe-side glue over Plume's `Editor`: maps the `{{variable}}`
/// domain - placeholder tinting and completion - onto the core's injected
/// seams. NOT part of Plume: this wrapper stays Canoe-side (Plume's own
/// type is `Editor`); call sites keep this wrapper's signature.
struct CodeEditor: View {
    @Binding var text: String
    var variables: [String: String] = [:]
    /// Completion candidates with scope metadata; nil derives names from
    /// `variables`.
    var suggestions: [VariableSuggestion]?
    var syntax: BodySyntax = .plain
    var isEditable: Bool = true
    var fillsContainer: Bool = false
    var showsLineNumbers: Bool = true
    var showsGutterSeparator: Bool = false
    var enablesTypingAssist: Bool = true
    var font: EditorFont = .monoSubheadline
    /// Per-editor line-height multiplier (Monaco's `lineHeight`);
    /// 1.35 matches the host's installed default from the global era.
    var lineHeightMultiple: CGFloat = 1.35
    var placeholder: String?
    var formatHandler: ((String) throws -> String?)?
    var formatActionName: String = "Format"
    var onFormatError: ((String) -> Void)?
    /// Host-supplied diagnostics, merged with the wrapper's own unresolved
    /// `{{variable}}` warnings (Plume `markers`).
    var markers: [EditorMarker] = []
    /// Flag unresolved `{{variable}}` placeholders as warning markers
    /// (squiggles, gutter dots, ruler ticks). Off for surfaces holding
    /// non-variable text (the cURL import field).
    var flagsUnresolvedVariables: Bool = true
    /// Show Plume's overview ruler (worth it in the full-pane body/script
    /// editors, noise in the compact ones).
    var showsOverviewRuler: Bool = false
    /// Gutter line-number follows the caret highlight too (Monaco:
    /// `renderLineHighlight: "all"`), on for every Canoe editor.
    var renderLineHighlight: EditorLineHighlightMode = .all
    /// Word-under-caret occurrence wash (Monaco `occurrencesHighlight`).
    var occurrencesHighlight: Bool = true
    /// Inline color swatches (Monaco `colorDecorators`): bodies carry
    /// JSON with colors.
    var colorDecorators: Bool = true
    /// Bracket pairs painted by nesting depth (Monaco
    /// `bracketPairColorization`).
    var bracketPairColorization: Bool = true
    /// Final-newline pilcrow, boundary mode (Monaco
    /// `renderFinalNewline`): visible only on the last line.
    var renderFinalNewline: EditorFinalNewlineMode = .boundary
    /// Vertical guides spanning bracket pairs (Monaco
    /// `guides.bracketPairs`).
    var bracketGuides: Bool = false
    /// Vertical guides at every completed indent level (Monaco
    /// `guides.indentation`).
    var indentGuides: Bool = true
    /// Lines kept visible around the caret on jumps (Monaco
    /// `cursorSurroundingLines`).
    var cursorSurroundingLines: Int = 0
    /// Common ligatures (Monaco `fontLigatures`).
    var fontLigatures: Bool = false
    /// Overview-ruler border hairline (Monaco `overviewRulerBorder`).
    var overviewRulerBorder: Bool = true
    /// Hide the caret tick in the overview ruler.
    var hideCursorInOverviewRuler: Bool = false
    /// Selection change callback (Monaco `onDidChangeCursorPosition`).
    var onSelectionChange: ((EditorSelectionSnapshot) -> Void)?
    /// Selection-only formatting (Monaco formatSelection); ⌥⇧F with a
    /// selection routes here before the whole-document handler.
    var formatSelectionHandler: ((String) throws -> String?)?
    /// Host actions (Monaco `addAction`): menu entries + key equivalents.
    var actions: [EditorAction] = []
    /// Scrollable space past the last line (Monaco
    /// `scrollBeyondLastLine`); only visible in the scroll-mode (fill
    /// container) editors.
    var scrollBeyondLastLine: Bool = false
    /// Highlight invisible/ambiguous unicode (Monaco `unicodeHighlight`)
    /// - worth it on paste surfaces, where zero-width characters sneak in.
    var unicodeHighlight: Bool = false
    /// Open URL runs on click (Monaco `links`); read-only surfaces only.
    var linksEnabled: Bool = false
    /// Capsule shown when a read-only edit is attempted
    /// (Monaco `readOnlyMessage`).
    var readOnlyMessage: String?
    /// Gutter line-number style (Monaco `lineNumbers`); `.on` is historic.
    var lineNumbersMode: EditorLineNumbersMode = .on
    /// Caret glide (Monaco `cursorSmoothCaretAnimation`); `.off` is historic.
    var cursorSmoothCaretAnimation: EditorCursorSmoothCaretAnimation = .off
    /// Format whatever is pasted through `formatHandler` (JSON bodies).
    var formatOnPaste: Bool = false
    /// Debounced whole-document format after typing pauses.
    var formatOnType: Bool = false
    /// Starting zoom for the editor-local font scale (`⌃=`/`⌃-` afterwards).
    var initialFontScale: CGFloat = 1
    /// Observe zoom changes (for persistence); nil keeps zoom local.
    var onFontScaleChange: ((CGFloat) -> Void)?
    /// Go-to-definition (F12/⌘-click); nil keeps both as no-ops.
    var definitionProvider: ((_ range: NSRange) -> NSRange?)?
    /// Outline symbols (⌃⇧O); nil uses Plume's built-in extraction.
    var documentSymbolsProvider: ((_ text: String) -> [EditorDocumentSymbol])?
    /// Signature help on `(`; nil disables the popup.
    var signatureProvider: ((_ functionRange: NSRange, _ activeParameter: Int) -> EditorSignatureHelp?)?

    var body: some View {
        Editor(
            text: $text,
            annotations: { source in
                VariablePlaceholderStyling.tintedRanges(in: source, variables: variables)
            },
            restyleKey: variables.isEmpty ? "" : String(variables.hashValue),
            syntax: syntax.profile,
            isEditable: isEditable,
            fillsContainer: fillsContainer,
            showsLineNumbers: showsLineNumbers,
            showsGutterSeparator: showsGutterSeparator,
            enablesTypingAssist: enablesTypingAssist,
            font: font,
            lineHeightMultiple: lineHeightMultiple,
            placeholder: placeholder,
            formatHandler: formatHandler,
            formatActionName: formatActionName,
            onFormatError: onFormatError,
            suggestFactory: { VariableCompletionBridge() },
            suggestItems: suggestions ?? VariableSuggestion.suggestions(from: variables),
            markers: markers + unresolvedVariableMarkers,
            showsOverviewRuler: showsOverviewRuler,
            // Read-only views are for reading, not caret tracking: the
            // current-line band is an editing affordance (Monaco hides it
            // in read-only panes too).
            renderLineHighlight: isEditable ? renderLineHighlight : .none,
            scrollBeyondLastLine: scrollBeyondLastLine,
            unicodeHighlight: unicodeHighlight,
            occurrencesHighlight: occurrencesHighlight,
            colorDecorators: colorDecorators,
            bracketPairColorization: bracketPairColorization,
            readOnlyMessage: readOnlyMessage,
            linksEnabled: linksEnabled,
            renderFinalNewline: renderFinalNewline,
            overviewRulerBorder: overviewRulerBorder,
            hideCursorInOverviewRuler: hideCursorInOverviewRuler,
            cursorSurroundingLines: cursorSurroundingLines,
            fontLigatures: fontLigatures,
            bracketGuides: bracketGuides,
            indentGuides: indentGuides,
            onSelectionChange: onSelectionChange,
            formatSelectionHandler: formatSelectionHandler,
            actions: actions,
            lineNumbersMode: lineNumbersMode,
            cursorSmoothCaretAnimation: cursorSmoothCaretAnimation,
            formatOnPaste: formatOnPaste,
            formatOnType: formatOnType,
            initialFontScale: initialFontScale,
            onFontScaleChange: onFontScaleChange,
            definitionProvider: definitionProvider,
            documentSymbolsProvider: documentSymbolsProvider,
            signatureProvider: signatureProvider
        )
    }

    /// Unresolved `{{variable}}` placeholders as warning markers (Monaco:
    /// `setModelMarkers`): the same set the variables inspector's
    /// "Unresolved Variables" list reports, surfaced in the editor itself.
    private var unresolvedVariableMarkers: [EditorMarker] {
        guard flagsUnresolvedVariables else { return [] }
        return VariablePlaceholderStyling.unresolvedRanges(in: text, variables: variables)
            .map { range, name in
                EditorMarker(
                    severity: .warning,
                    range: range,
                    message: "Unresolved variable: \(name)")
            }
    }
}

/// Bridges Canoe's `VariableCompletionController` onto the generic editor's
/// opaque `EditorSuggestControlling` protocol - pure forwarding, no
/// state of its own.
@MainActor
private final class VariableCompletionBridge: EditorSuggestControlling {
    private let controller = VariableCompletionController()

    func candidatesChanged(_ candidates: [Any]) {
        controller.setCandidates(candidates as? [VariableSuggestion] ?? [])
    }

    func textChanged(_ textView: NSTextView) {
        controller.textChanged(textView)
    }

    func selectionChanged(_ textView: NSTextView) {
        controller.selectionChanged(textView)
    }

    func handleCommand(_ selector: Selector) -> Bool {
        controller.handleCommand(selector)
    }

    var isVisible: Bool { controller.isVisible }

    func hide() {
        controller.hide()
    }
}
