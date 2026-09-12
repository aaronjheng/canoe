import Foundation

/// A single entry in the request history. Held in memory only (not synced) so
/// each device keeps its own recent-activity list.
struct HistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let requestID: UUID?
    let name: String
    let method: HTTPMethod
    let urlString: String
    let statusCode: Int
    let duration: TimeInterval
    let timestamp: Date

    var isSuccess: Bool { (200..<300).contains(statusCode) }
}
