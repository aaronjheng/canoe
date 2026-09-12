import Foundation

/// The request body type, mirroring Postman's body selector:
/// none / form-data / x-www-form-urlencoded / raw / binary.
enum RequestBodyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case formData
    case urlEncoded
    case raw
    case binary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "none"
        case .formData: "form-data"
        case .urlEncoded: "x-www-form-urlencoded"
        case .raw: "raw"
        case .binary: "binary"
        }
    }
}

/// The raw body format. Decides the default Content-Type and stays limited to
/// the three formats Postman offers in its raw dropdown core set.
enum RawBodyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case json
    case xml

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .json: "JSON"
        case .xml: "XML"
        }
    }

    var contentType: String {
        switch self {
        case .text: "text/plain"
        case .json: "application/json"
        case .xml: "application/xml"
        }
    }
}

/// One form-data or url-encoded row. For `file` rows `value` holds the file
/// path (the sandbox is disabled, so paths can be read directly on send).
enum FormFieldKind: String, Codable, CaseIterable, Sendable {
    case text
    case file
}

struct FormField: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isEnabled: Bool = true
    var kind: String = FormFieldKind.text.rawValue

    var fieldKind: FormFieldKind {
        get { FormFieldKind(rawValue: kind) ?? .text }
        set { kind = newValue.rawValue }
    }
}
