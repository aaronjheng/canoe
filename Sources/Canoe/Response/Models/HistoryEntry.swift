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
    /// Machine-stable name of what went wrong for failed sends
    /// (`timedOut`, `cannotConnectToHost`, …), nil for successes - so a
    /// failed entry is distinguishable instead of collapsing into
    /// statusCode 0 / 0 ms.
    let errorKind: String?
    let timestamp: Date

    /// `id` is deliberately not coded: it is a fresh per-session identity
    /// for SwiftUI (nothing keys off it across relaunches), and excluding
    /// it keeps Codable synthesis from warning about the initial value.
    private enum CodingKeys: String, CodingKey {
        case requestID, name, method, urlString, statusCode, duration
        case errorKind, timestamp
    }

    init(
        requestID: UUID?,
        name: String,
        method: HTTPMethod,
        urlString: String,
        statusCode: Int,
        duration: TimeInterval,
        timestamp: Date,
        errorKind: String? = nil
    ) {
        self.requestID = requestID
        self.name = name
        self.method = method
        self.urlString = urlString
        self.statusCode = statusCode
        self.duration = duration
        self.timestamp = timestamp
        self.errorKind = errorKind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        // Tolerant on purpose: history.json is machine-local and outlives
        // builds - an entry a newer build saved with an unknown method (or
        // an older field layout) must cost one row's display, not the whole
        // file (the next save would otherwise rewrite history.json empty).
        method = HTTPMethod(rawValue: try container.decodeIfPresent(String.self, forKey: .method) ?? "") ?? .get
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString) ?? ""
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode) ?? 0
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        errorKind = try container.decodeIfPresent(String.self, forKey: .errorKind)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
    }
}
