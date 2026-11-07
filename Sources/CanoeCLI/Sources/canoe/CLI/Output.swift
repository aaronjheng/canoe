import Foundation
import CanoeCore

func parseOverrides(_ items: [String]) -> [String: String] {
    var dict: [String: String] = [:]
    for item in items {
        if let eq = item.firstIndex(of: "=") {
            dict[String(item[..<eq])] = String(item[item.index(after: eq)...])
        } else {
            dict[item] = ""
        }
    }
    return dict
}

func fail(_ message: String, json: Bool = false) -> Int32 {
    if json {
        printJSON(["error": message])
    } else {
        fputs("error: \(message)\n", stderr)
    }
    return 1
}

// Re-exported helpers for Commands
typealias CommandArg = ParsedArgs
