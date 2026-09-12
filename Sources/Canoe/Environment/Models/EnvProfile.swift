import Foundation

/// A named set of variables that can be substituted into requests using
/// the `{{variable}}` syntax. Persisted as one JSON file per environment.
/// Environments are workspace-scoped: each belongs to exactly one workspace.
struct EnvProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "New Environment"
    var orderIndex: Int = 0
    var createdAt: Date = Date()
    /// Owning workspace. Optional only for decoding legacy files written
    /// before scoping existed - those are migrated on load.
    var workspaceID: UUID?
    var variables: [Variable] = []

    init(
        id: UUID = UUID(),
        name: String = "New Environment",
        orderIndex: Int = 0,
        workspaceID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.orderIndex = orderIndex
        self.workspaceID = workspaceID
    }

    /// A flat dictionary of enabled `key: value` pairs for variable
    /// resolution. Disabled variables and blank keys are skipped.
    var variablesDictionary: [String: String] {
        variables.resolvingDictionary()
    }
}
