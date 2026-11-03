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
    var placeholder: String?
    var formatHandler: ((String) throws -> String?)?
    var formatActionName: String = "Format"
    var onFormatError: ((String) -> Void)?

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
            placeholder: placeholder,
            formatHandler: formatHandler,
            formatActionName: formatActionName,
            onFormatError: onFormatError,
            suggestFactory: { VariableCompletionBridge() },
            suggestItems: suggestions ?? VariableSuggestion.suggestions(from: variables)
        )
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
