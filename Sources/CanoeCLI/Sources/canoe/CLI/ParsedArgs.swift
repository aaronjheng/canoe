import Foundation

struct ParsedArgs {
    var positionals: [String] = []
    var flags: [String: [String]] = [:]
    var json: Bool = false
}

func parseArgs(_ raw: [String]) -> ParsedArgs {
    var out = ParsedArgs()
    var i = raw.startIndex
    while i < raw.endIndex {
        let a = raw[i]
        if a == "--" {
            out.positionals.append(contentsOf: raw[raw.index(after: i)...])
            break
        } else if a == "--json" {
            out.json = true
        } else if a.hasPrefix("--"), a.contains("=") {
            let parts = a.dropFirst(2).split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                out.flags[String(parts[0]), default: []].append(String(parts[1]))
            }
        } else if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if raw.index(after: i) < raw.endIndex, !raw[raw.index(after: i)].hasPrefix("--") {
                out.flags[key, default: []].append(raw[raw.index(after: i)])
                i = raw.index(after: i)
            } else {
                out.flags[key, default: []].append("true")
            }
        } else if a.hasPrefix("-"), a != "-" {
            out.flags[a, default: []].append("true")
        } else {
            out.positionals.append(a)
        }
        i = raw.index(after: i)
    }
    return out
}

func flag(_ args: ParsedArgs, _ key: String) -> String? { args.flags[key]?.first }
func flagAll(_ args: ParsedArgs, _ key: String) -> [String] { args.flags[key] ?? [] }
func flagBool(_ args: ParsedArgs, _ key: String) -> Bool { args.flags[key] != nil }
