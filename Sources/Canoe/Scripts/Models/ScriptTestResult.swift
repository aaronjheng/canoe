import Foundation

/// One `pm.test(...)` outcome (Postman's Test Results row): the test name,
/// how it concluded, and the assertion message when it failed. Attached to
/// the response snapshot, so the Test Results tab survives history
/// navigation; persisted only in the machine-local response-history mirror.
struct ScriptTestResult: Codable, Sendable, Hashable {
    /// Postman's three result types (the "Result type" filter checkboxes):
    /// a skipped test registered with `pm.test.skip` concludes without
    /// running its assertions.
    enum Status: String, Codable, Sendable {
        case passed
        case failed
        case skipped
    }

    var name: String
    var status: Status
    var message: String?

    init(name: String, status: Status, message: String? = nil) {
        self.name = name
        self.status = status
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, passed, message
    }

    /// History snapshots taken before the skip support carried a bare
    /// `passed` boolean: map it rather than dropping the row, and degrade
    /// anything unrecognized to a failed row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        if let status = try? container.decode(Status.self, forKey: .status) {
            self.status = status
        } else if let passed = try? container.decodeIfPresent(Bool.self, forKey: .passed) {
            self.status = passed ? .passed : .failed
        } else {
            self.status = .failed
        }
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    /// Curated encoding: only what the current shape reads back (the legacy
    /// `passed` key is consumed on decode, never written).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// One `console.*` line a script printed during a run: level plus the
/// formatted text. Attached to the response snapshot below the test
/// results; console lines from both phases (pre-request + post-response)
/// land here, merged in phase order.
struct ScriptLog: Codable, Sendable, Hashable {
    enum Level: String, Codable, Sendable {
        case log
        case warn
        case error
    }

    var level: Level
    var message: String
}
