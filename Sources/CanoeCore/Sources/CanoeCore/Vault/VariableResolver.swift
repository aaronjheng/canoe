import Foundation

public enum VariableResolver {
    /// Merges in precedence order (low → high): workspace → collection → environment → overrides.
    public static func mergedDictionary(
        workspace: Workspace?,
        collection: Collection?,
        environment: EnvironmentProfile?,
        overrides: [String: String]
    ) -> [String: String] {
        var dict: [String: String] = [:]
        dict = (workspace?.variables ?? []).resolvingDictionary(into: dict)
        dict = (collection?.variables ?? []).resolvingDictionary(into: dict)
        dict = (environment?.variables ?? []).resolvingDictionary(into: dict)
        for (k, v) in overrides { dict[k] = v }
        return dict
    }

    /// Resolves `{{var}}` (optional spaces). Missing vars stay as-is.
    /// Supports nested references (a={{b}}) up to 10 passes.
    public static func resolve(_ string: String, with vars: [String: String]) -> String {
        guard string.contains("{{") else { return string }
        let pattern = "\\{\\{\\s*([^}]+?)\\s*\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        var result = string
        for _ in 0..<10 {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { break }
            var out = ""
            var lastIndex = 0
            var changed = false
            for m in matches {
                let key = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = vars[key] {
                    out += ns.substring(with: NSRange(location: lastIndex, length: m.range.location - lastIndex))
                    out += value
                    lastIndex = m.range.location + m.range.length
                    changed = true
                }
            }
            if !changed && matches.isEmpty { break }
            if lastIndex == 0 { break }
            out += ns.substring(from: lastIndex)
            if out == result { break }
            result = out
            if !changed { break }
        }
        return result
    }

    public static func resolveFields(_ fields: [FormField], with vars: [String: String]) -> [(key: String, value: String, isFile: Bool)] {
        fields.filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { f in
            let key = resolve(f.key, with: vars)
            let value = resolve(f.value, with: vars)
            return (key: key, value: value, isFile: f.kind == "file")
        }
    }
}
