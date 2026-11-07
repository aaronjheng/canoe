import Foundation

public struct SendResult: Codable {
    public var request: String
    public var method: String
    public var url: String
    public var statusCode: Int?
    public var headers: [String: String]
    public var body: String
    public var durationMs: Double
    public var error: String?
}

public enum SendError: LocalizedError {
    case invalidURL(String)
    case fileNotFound(String)
    case unsupportedAuth(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "unsupported URL: \(u)"
        case .fileNotFound(let p): return "file not found: \(p)"
        case .unsupportedAuth(let t): return "auth type not supported by CLI: \(t) (open Canoe.app for that part)"
        }
    }
}
