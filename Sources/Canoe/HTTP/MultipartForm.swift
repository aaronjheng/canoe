import Foundation
import UniformTypeIdentifiers

/// Builds `multipart/form-data` request bodies, mirroring what Postman sends
/// for form-data rows (text fields inline, file fields with filename + MIME).
enum MultipartForm {
    struct Part {
        let name: String
        let filename: String?
        let mimeType: String?
        let data: Data
    }

    static func makeBoundary() -> String {
        "CanoeBoundary-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func encode(parts: [Part], boundary: String) -> Data {
        var body = Data()
        for part in parts {
            body.append(string: "--\(boundary)\r\n")
            if let filename = part.filename {
                body.append(string: "Content-Disposition: form-data; name=\"\(escape(part.name))\"; filename=\"\(escape(filename))\"\r\n")
                body.append(string: "Content-Type: \(part.mimeType ?? "application/octet-stream")\r\n")
            } else {
                body.append(string: "Content-Disposition: form-data; name=\"\(escape(part.name))\"\r\n")
            }
            body.append(string: "\r\n")
            body.append(part.data)
            body.append(string: "\r\n")
        }
        body.append(string: "--\(boundary)--\r\n")
        return body
    }

    /// Guesses a MIME type from a file path's extension.
    static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty,
            let type = UTType(filenameExtension: ext),
            let mime = type.preferredMIMEType
        else {
            return "application/octet-stream"
        }
        return mime
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

extension Data {
    fileprivate mutating func append(string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
