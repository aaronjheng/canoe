import AppKit
import Plume

// NOTE: Canoe-side feature code, NOT part of Plume (the editor base library).
// When the editor extracts into a shared package, this file stays here.

/// Shared `{{variable}}` tinting for the AppKit-backed editors
/// (`VariableHighlightEditor` and `CodeEditor`).
enum VariablePlaceholderStyling {
    /// The full attributed value for `text`: mono font, optional syntax
    /// foreground colors, plus tinted `{{variable}}` runs.
    static func attributed(
        _ plain: String,
        font: EditorFont,
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
            .foregroundColor: AppColor.textPrimaryNS,
        ]
        if let lineBreakMode {
            base[.paragraphStyle] = paragraphStyle(lineBreakMode: lineBreakMode)
        }
        let out = NSMutableAttributedString(string: plain, attributes: base)
        if let runs = SyntaxHighlight.foregroundRuns(in: plain, profile: syntax.profile) {
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
        // Dynamic variables ({{$guid}} & co) always resolve, so they carry
        // the success tint even though no definition holds them.
        let resolved = variables[name] != nil || DynamicVariables.isDynamic(name)
        return NSColor(resolved ? AppColor.success : AppColor.warning)
            .withAlphaComponent(AppOpacity.variableHighlight)
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

    /// Colored ranges for the generic editor's annotation seam: every
    /// `{{name}}` range paired with its resolved-tint background color
    /// (`CodeEditor` glue feeds this to `CodeEditorCore.annotations`).
    static func tintedRanges(in source: String, variables: [String: String]) -> [(NSRange, NSColor)] {
        variableRanges(in: source).map { (range, key) in (range, tint(key, in: variables)) }
    }

    /// The placeholder runs that resolve to nothing - neither a scope
    /// definition nor a dynamic variable. The editor's marker seam turns
    /// these into warning squiggles (Monaco: `setModelMarkers`), matching
    /// the inspector's "Unresolved Variables" list.
    static func unresolvedRanges(in source: String, variables: [String: String]) -> [(NSRange, String)] {
        variableRanges(in: source).filter { _, name in
            variables[name] == nil && !DynamicVariables.isDynamic(name)
        }
    }
}
