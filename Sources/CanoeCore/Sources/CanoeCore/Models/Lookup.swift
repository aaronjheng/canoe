import Foundation

public func matchIDOrName<T>(_ value: String, in items: [T], id: (T) -> UUID, name: (T) -> String) -> T? {
    if let uuid = UUID(uuidString: value) {
        return items.first(where: { id($0) == uuid })
    }
    let lower = value.lowercased()
    return items.first(where: { name($0).lowercased() == lower })
        ?? items.first(where: { name($0).lowercased().contains(lower) })
}

public func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
}

public func printJSON(_ value: Any) {
    do {
        let data = try jsonData(value)
        if let s = String(data: data, encoding: .utf8) { print(s) }
    } catch {
        fputs("error: failed to encode json: \(error.localizedDescription)\n", stderr)
    }
}
