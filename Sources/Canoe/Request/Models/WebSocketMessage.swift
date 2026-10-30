import Foundation

// MARK: - Message format

/// The message composition format (Postman's WebSocket message editor
/// selector): text flavors with syntax highlighting plus binary flavors
/// entered as Base64 or hexadecimal. Raw-string storage so a saved message
/// or draft written by a future format keeps decoding.
enum WebSocketMessageFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case json
    case xml
    case html
    case binaryBase64 = "binary-base64"
    case binaryHex = "binary-hex"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .binaryBase64: "Base64"
        case .binaryHex: "Hexadecimal"
        }
    }

    /// The picker's group label: text flavors sit under one heading,
    /// binary flavors under another (Postman's two-step Binary menu).
    var isBinary: Bool {
        self == .binaryBase64 || self == .binaryHex
    }

    /// Syntax grammar for the editor and the expanded message view.
    var syntax: BodySyntax {
        switch self {
        case .text, .binaryBase64, .binaryHex: .plain
        case .json: .json
        case .xml, .html: .xml
        }
    }

    /// Decodes the editor text into the bytes that go on the wire. Binary
    /// flavors parse Base64 / hex (whitespace and `:` separators between
    /// hex pairs tolerated); invalid input returns nil and the send is
    /// dropped rather than putting garbage on the wire. Text flavors send
    /// the exact UTF-8 of the text.
    func wireData(fromEditorText text: String) -> Data? {
        switch self {
        case .text, .json, .xml, .html:
            return Data(text.utf8)
        case .binaryBase64:
            let cleaned =
                text
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            return Data(base64Encoded: cleaned)
        case .binaryHex:
            let cleaned =
                text
                .filter { !$0.isWhitespace && $0 != ":" }
            guard cleaned.count % 2 == 0 else { return nil }
            var data = Data(capacity: cleaned.count / 2)
            var index = cleaned.startIndex
            while index < cleaned.endIndex {
                let next = cleaned.index(index, offsetBy: 2)
                guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            return data
        }
    }

    /// Encodes received bytes back into the editor's text for this format
    /// (hex pairs uppercase, like Postman's hexdump).
    func editorText(fromWireData data: Data) -> String {
        switch self {
        case .text, .json, .xml, .html:
            return String(data: data, encoding: .utf8) ?? ""
        case .binaryBase64:
            return data.base64EncodedString()
        case .binaryHex:
            return data.map { String(format: "%02X", $0) }.joined()
        }
    }

    /// Whether the bytes decode as UTF-8 text (a received binary frame the
    /// viewer can show as text anyway).
    static func isUTF8Text(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }
}

// MARK: - Message draft

/// The composed message the editor holds: the text and its format. Kept as
/// in-memory session state per request (like the message log), so it
/// survives tab switches within the app session but not a relaunch.
struct WebSocketMessageDraft: Equatable, Sendable {
    var text: String = ""
    var format: WebSocketMessageFormat = .text
    /// The saved message the editor is bound to (Postman binds the editor
    /// to the selected saved message: Save updates that entry instead of
    /// appending a duplicate). Session state, like the rest of the draft.
    var linkedSavedID: UUID?
}

/// Standard hexdump rendering (`hexdump -C` layout) for the message detail's
/// Show Hexdump mode: 16 bytes per row, offset column, hex pairs, ASCII
/// gutter.
enum WebSocketHexDump {
    static func string(for data: Data, byteLimit: Int = 4_096) -> String {
        let bytes = data.prefix(byteLimit)
        var lines: [String] = []
        var rowStart = bytes.startIndex
        while rowStart < bytes.endIndex {
            let rowEnd =
                bytes.index(rowStart, offsetBy: 16, limitedBy: bytes.endIndex)
                ?? bytes.endIndex
            var hex = ""
            var ascii = ""
            for (offset, byte) in bytes[rowStart..<rowEnd].enumerated() {
                if offset == 8 { hex += " " }
                hex += String(format: "%02x ", byte)
                ascii += (0x20...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : "."
            }
            let byteOffset = bytes.distance(from: bytes.startIndex, to: rowStart)
            let hexColumnWidth = 16 * 3 + 1
            lines.append(String(format: "%08x  %-\(hexColumnWidth)s |\(ascii)|", byteOffset, hex))
            rowStart = rowEnd
        }
        if data.count > byteLimit {
            lines.append("… \(data.count - byteLimit) more bytes")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Saved message

/// A message saved with the request (Postman's Saved messages): composed
/// once, loaded back into the editor, and resent later. Persisted inside
/// the request (collection file), like every other request field.
struct WebSocketSavedMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    /// Raw `WebSocketMessageFormat` string so future formats keep decoding.
    var format: String = WebSocketMessageFormat.text.rawValue
    var text: String = ""
    var createdAt: Date = Date()

    var formatKind: WebSocketMessageFormat {
        get { WebSocketMessageFormat(rawValue: format) ?? .text }
        set { format = newValue.rawValue }
    }

    /// Display name: the user's, or "Message N" filled in when the row was
    /// created (Postman auto-names saved messages too).
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Message" : trimmed
    }
}

// MARK: - Connection state

/// Where the request's WebSocket connection stands. Shown by the message
/// pane's status badge and by the editor's Connect/Disconnect button.
enum WebSocketConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected(since: Date, subprotocol: String?)
    case disconnecting
    /// Off the wire. `reason` carries the failure text (or the close code)
    /// when the session ended on its own; nil for a clean user disconnect
    /// that has nothing to say.
    case disconnected(reason: String?)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        self == .connecting
    }

    /// Whether the Connect action is available at all (not mid-handshake,
    /// not already on the wire).
    var canConnect: Bool {
        switch self {
        case .idle, .disconnected: true
        case .connecting, .connected, .disconnecting: false
        }
    }
}

// MARK: - Message log

/// One row of the WebSocket message log (Postman's Response pane): a sent
/// frame, a received frame, or a system line (connected, closed, error,
/// ping/pong). Transient - the log lives in memory for the app session and
/// is never persisted.
struct WebSocketLogEntry: Identifiable, Sendable {
    enum Direction: Sendable {
        case sent
        case received
        case system
    }

    enum Kind: Sendable {
        case text
        case binary
        case ping
        case pong
        case connected
        case disconnected
        case error
    }

    var id = UUID()
    var date = Date()
    var direction: Direction
    var kind: Kind
    /// Text payload (sent/received text frames), or the system line's
    /// message for connection/error/close entries.
    var text: String?
    /// Binary payload (sent/received binary frames).
    var data: Data?
    /// Server close code for `disconnected` entries (URLSession's mapped
    /// `URLSessionWebSocketTask.CloseCode` raw value).
    var closeCode: Int?
    var subprotocol: String?

    /// One-line preview for the collapsed row: the payload's first line
    /// (whitespace-flattened), or the system message.
    var preview: String {
        let raw: String?
        if let text {
            raw = text
        } else if let data {
            raw = String(data: data, encoding: .utf8)
        } else {
            raw = nil
        }
        guard var line = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty
        else {
            if let data { return "Binary · \(Int64(data.count).formattedByteCount)" }
            return kind == .ping ? "Ping" : kind == .pong ? "Pong" : ""
        }
        line = line.replacingOccurrences(of: "\n", with: " ")
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }

    /// Payload byte size (the wire size of a frame, the system line's text
    /// length otherwise shown as nil).
    var payloadSize: Int? {
        if let data { return data.count }
        if let text { return Data(text.utf8).count }
        return nil
    }

    var isTextPayload: Bool {
        switch kind {
        case .text: true
        case .binary:
            // A binary frame that is really UTF-8 still shows as text.
            data.map(Self.isUTF8TextData) ?? false
        case .ping, .pong, .connected, .disconnected, .error: false
        }
    }

    /// Whether the row expands to a full payload view (frames only).
    var isExpandable: Bool {
        switch kind {
        case .text, .binary: true
        case .ping, .pong, .connected, .disconnected, .error: false
        }
    }

    /// The syntax grammar the expanded view uses. Received/sent frames
    /// sniff JSON; binary frames render Base64 as plain text.
    var detailSyntax: BodySyntax {
        guard isTextPayload, let source = text ?? data.flatMap({ String(data: $0, encoding: .utf8) })
        else { return .plain }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return .json
        }
        if trimmed.hasPrefix("<") {
            return .xml
        }
        return .plain
    }

    private static func isUTF8TextData(_ data: Data) -> Bool {
        WebSocketMessageFormat.isUTF8Text(data)
    }
}
