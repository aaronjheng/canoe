import Foundation

/// Resolves `{{variable}}` placeholders in a string using the in-scope
/// variables.
///
/// Scoping is Postman-style: workspace variables are the widest scope,
/// collection variables override them, and environment variables win over
/// both. Unknown placeholders are left untouched so the user can see what
/// is missing.
enum VariableResolver {
    private static let pattern = #"\{\{\s*([^}]+?)\s*\}\}"#

    /// Compiled once - the old code rebuilt the regex on every call, i.e.
    /// once per URL plus once per param/header key and value.
    private static let regex: NSRegularExpression? = try? NSRegularExpression(pattern: pattern, options: [])

    /// Unique `{{placeholder}}` keys in `string`, in order of first appearance,
    /// with surrounding whitespace trimmed. Used by the "Variables in Request"
    /// inspector to show which variables a request actually references.
    static func placeholders(in string: String) -> [String] {
        guard string.contains("{{"), let regex else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        var seen = Set<String>()
        var keys: [String] = []
        for match in regex.matches(in: string, options: [], range: range) {
            guard let keyRange = Range(match.range(at: 1), in: string) else { continue }
            let key = String(string[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }

    static func resolve(_ string: String, variables: [String: String]) -> String {
        guard !variables.isEmpty, string.contains("{{"), let regex else { return string }

        // Resolve recursively so a variable whose value references another
        // variable (e.g. base={{host}}/v1) still expands. Bounded to avoid
        // infinite loops on cyclic definitions.
        var result = string
        for _ in 0..<10 {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)
            if matches.isEmpty { break }
            var changed = false
            var next = result
            for match in matches.reversed() {
                guard let keyRange = Range(match.range(at: 1), in: result),
                    let fullRange = Range(match.range, in: result)
                else { continue }
                let key = String(result[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = variables[key] else { continue }
                next.replaceSubrange(fullRange, with: value)
                changed = true
            }
            result = next
            if !changed || !result.contains("{{") { break }
        }
        return result
    }
}
