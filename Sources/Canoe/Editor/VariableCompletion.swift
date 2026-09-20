import Foundation

/// One candidate in the `{{variable}}` completion popup: the placeholder name
/// to insert plus display metadata from its highest-precedence definition.
/// Values are deliberately absent - secret values must never surface in a
/// transient popup, and completion only needs names.
struct VariableSuggestion: Identifiable, Hashable, Sendable {
    let name: String
    /// Scope that wins resolution for this key; nil when derived from a
    /// plain resolved dictionary, which carries no scope metadata.
    let scopeKind: VariableScope.Kind?
    let scopeName: String?
    let isSecret: Bool

    var id: String { name }
}

extension VariableSuggestion {
    /// Builds candidates from the request's variable scopes, lowest
    /// precedence first (workspace → collection → environment): a key defined
    /// in several scopes appears once, attributed to the scope whose value
    /// would win. Disabled rows and blank keys never resolve, so suggesting
    /// them would produce red placeholders - they are excluded.
    static func suggestions(from scopes: [VariableScope]) -> [VariableSuggestion] {
        var byName: [String: VariableSuggestion] = [:]
        for scope in scopes {
            for variable in scope.variables where variable.isEnabled {
                let key = variable.key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                byName[key] = VariableSuggestion(
                    name: key,
                    scopeKind: scope.kind,
                    scopeName: scope.ownerName,
                    isSecret: variable.isSecret
                )
            }
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Names-only fallback for editors that only know the resolved
    /// dictionary (no scope metadata to show).
    static func suggestions(from variables: [String: String]) -> [VariableSuggestion] {
        variables.keys
            .map { VariableSuggestion(name: $0, scopeKind: nil, scopeName: nil, isSecret: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Parses the `{{` fragment under the caret and filters candidates for it.
/// Shared by the single-line (NSTextField) and multi-line (NSTextView)
/// variable editors.
enum VariableCompletionEngine {
    /// The active placeholder fragment: the text between the nearest
    /// unclosed `{{` and the caret, plus the ranges it occupies.
    struct Context: Equatable {
        /// UTF-16 range of the fragment in the editor string, starting just
        /// after `{{` and ending at the caret.
        let fragmentRange: NSRange
        /// Raw fragment text (may include surrounding whitespace).
        let fragment: String
        /// Range of a `}}` immediately following the caret, when the caret
        /// sits inside an already-closed placeholder - accepting then
        /// replaces the existing braces instead of duplicating them.
        let trailingCloseRange: NSRange?

        /// The range acceptance replaces: the fragment plus a trailing `}}`
        /// when present.
        var replacementRange: NSRange {
            NSRange(location: fragmentRange.location, length: fragmentRange.length + (trailingCloseRange == nil ? 0 : 2))
        }
    }

    /// Fragments longer than this are treated as pasted blobs, not names.
    private static let maxFragmentLength = 100

    /// Finds the completion context at `caret` (UTF-16 offset), or nil when
    /// the caret is not inside an unclosed `{{...` fragment.
    static func context(atCaret caret: Int, in text: String) -> Context? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let open = ns.range(of: "{{", options: [.backwards], range: NSRange(location: 0, length: caret))
        guard open.location != NSNotFound else { return nil }
        let fragmentStart = open.location + 2
        guard caret >= fragmentStart else { return nil }
        let fragment = ns.substring(with: NSRange(location: fragmentStart, length: caret - fragmentStart))
        // A closing brace before the caret means the placeholder is already
        // complete (or the user is typing `}}`) - nothing to complete.
        guard !fragment.contains("}") else { return nil }
        var trailingCloseRange: NSRange?
        if caret + 2 <= ns.length, ns.substring(with: NSRange(location: caret, length: 2)) == "}}" {
            trailingCloseRange = NSRange(location: caret, length: 2)
        }
        return Context(
            fragmentRange: NSRange(location: fragmentStart, length: caret - fragmentStart),
            fragment: fragment,
            trailingCloseRange: trailingCloseRange
        )
    }

    /// Candidates matching the fragment: case-insensitive prefix matches
    /// first, then substring matches, each keeping the given (sorted) order.
    static func suggestions(matching context: Context, from candidates: [VariableSuggestion]) -> [VariableSuggestion] {
        let query = context.fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= maxFragmentLength else { return [] }
        guard !query.isEmpty else { return candidates }
        let lowered = query.lowercased()
        let prefix = candidates.filter { $0.name.lowercased().hasPrefix(lowered) }
        let contains = candidates.filter { !$0.name.lowercased().hasPrefix(lowered) && $0.name.lowercased().contains(lowered) }
        return prefix + contains
    }
}
