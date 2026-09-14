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
        var seen = Set<String>()
        return ranges(in: string).map(\.key).filter { seen.insert($0).inserted }
    }

    /// Every `{{name}}` match as a UTF-16 range plus the trimmed name, in
    /// order of appearance (every occurrence - highlighting tints each one).
    /// The single parser behind `placeholders(in:)` and `resolve`, so the
    /// editor never tints something resolution ignores (or the reverse).
    static func ranges(in string: String) -> [(range: NSRange, key: String)] {
        guard string.contains("{{"), let regex else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        var out: [(range: NSRange, key: String)] = []
        for match in regex.matches(in: string, options: [], range: range) {
            guard let keyRange = Range(match.range(at: 1), in: string) else { continue }
            let key = String(string[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            out.append((range: match.range, key: key))
        }
        return out
    }

    /// Variable keys that reference themselves transitively (`a={{b}}`,
    /// `b={{a}}`). `resolve` cannot expand these, so the wire carries
    /// literal `{{...}}` - callers surface them as warnings instead of
    /// showing them resolved.
    static func cyclicKeys(in variables: [String: String]) -> Set<String> {
        var cyclic: Set<String> = []
        for start in variables.keys {
            var stack = placeholders(in: variables[start] ?? "")
            var seen: Set<String> = [start]
            while let next = stack.popLast() {
                if next == start {
                    cyclic.insert(start)
                    break
                }
                guard seen.insert(next).inserted, let value = variables[next] else { continue }
                stack += placeholders(in: value)
            }
        }
        return cyclic
    }

    /// Subset of `used` that cannot fully resolve because expansion reaches
    /// a reference cycle - directly (`{{a}}` with `a` in a cycle) or
    /// transitively (`{{x}}` with `x` expanding toward a cycle). Undefined
    /// keys are not included; they are reported separately as unresolved.
    static func keysBlockedByCycle(used: Set<String>, variables: [String: String]) -> Set<String> {
        let cyclic = cyclicKeys(in: variables)
        guard !cyclic.isEmpty else { return [] }
        var blocked: Set<String> = []
        for key in used {
            var stack = [key]
            var seen: Set<String> = []
            while let next = stack.popLast() {
                if cyclic.contains(next) {
                    blocked.insert(key)
                    break
                }
                guard seen.insert(next).inserted, let value = variables[next] else { continue }
                stack += placeholders(in: value)
            }
        }
        return blocked
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
