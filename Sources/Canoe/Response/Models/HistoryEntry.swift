import Foundation

/// A single entry in the request history. Per-device activity: mirrored to
/// the machine-local `history.json` (like `drafts.json`, never synced) so
/// each device keeps its own recent-activity list across relaunches.
struct HistoryEntry: Identifiable, Hashable, Codable {
    let id = UUID()
    let requestID: UUID?
    let name: String
    let method: HTTPMethod
    /// The request URL exactly as entered (e.g. `{{baseUrl}}/users`),
    /// matching the request editor - not the resolved address the console
    /// logs.
    let urlString: String
    let statusCode: Int
    let duration: TimeInterval
    let timestamp: Date

    /// `id` is deliberately not coded: it is a fresh per-session identity
    /// for SwiftUI (nothing keys off it across relaunches), and excluding
    /// it keeps Codable synthesis from warning about the initial value.
    private enum CodingKeys: String, CodingKey {
        case requestID, name, method, urlString, statusCode, duration, timestamp
    }
}
