import Foundation

/// A transient HTTP response used for display. Not persisted to the vault.
struct ResponseModel: Identifiable, Sendable {
    let id = UUID()
    let statusCode: Int
    let headers: [HTTPHeaderField]
    let body: Data
    let duration: TimeInterval
    let timestamp: Date
    let mimeType: String?

    var bodySize: Int { body.count }

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? "<binary data, \(body.count) bytes>"
    }

    /// The response body, pretty-printed when it is JSON.
    var prettyBodyString: String {
        // Skip the JSON round-trip for very large bodies - it blocks the main
        // thread and the raw text is shown (truncated) instead.
        guard body.count <= 2_000_000 else { return bodyString }
        let trimmed = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return bodyString }

        guard let object = try? JSONSerialization.jsonObject(with: body, options: .allowFragments) else { return bodyString }
        guard
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return bodyString }
        return String(data: pretty, encoding: .utf8) ?? bodyString
    }

    /// Whether the body is JSON (and small enough to pretty-print/highlight).
    var isJSONBody: Bool {
        guard body.count <= 2_000_000 else { return false }
        let trimmed = bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: body, options: .allowFragments)) != nil
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    var statusText: String {
        statusCode == 0 ? "Error" : HTTPURLResponse.localizedString(forStatusCode: statusCode)
    }

    var formattedDuration: String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        }
        return String(format: "%.2f s", duration)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file)
    }
}
