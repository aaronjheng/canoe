import Foundation

/// One variable scope that applies to a request, as shown in the
/// "Variables in Request" inspector: the owning workspace, collection, or
/// environment together with its raw (unmerged) variables. Scopes are
/// transient inspection models - they are never persisted.
/// Precedence (low to high): workspace → collection → environment.
struct VariableScope: Identifiable, Hashable, Sendable {
    /// Which layer of the Postman-style hierarchy the variables come from.
    /// `rawValue` doubles as the display label.
    enum Kind: String, Hashable, Sendable {
        case workspace = "Workspace"
        case collection = "Collection"
        case environment = "Environment"

        /// Display label for the inspector section header.
        var label: String { rawValue }

        var systemImage: String {
            switch self {
            case .workspace: "square.stack.3d.up.fill"
            case .collection: "list.bullet.rectangle.fill"
            case .environment: "globe"
            }
        }
    }

    let kind: Kind
    /// ID of the owning workspace/collection/environment. Nil when there is
    /// none (e.g. no active environment, or a collection not linked to a
    /// workspace).
    let ownerID: UUID?
    let ownerName: String?
    /// Variables exactly as stored - disabled rows included so the inspector
    /// can show why a variable does not resolve. Script overrides already
    /// folded in (see `VariableOverrides`): overridden rows carry the
    /// effective value, masked rows are gone, script-created variables join
    /// as synthetic rows.
    let variables: [Variable]
    /// Keys in `variables` whose value comes from the script overrides layer
    /// (the "Script" badge in the inspector; rows also render read-only -
    /// the local layer is script-managed runtime state).
    var scriptSetKeys: Set<String> = []
    /// True when any override data exists for the scope's owner, even if it
    /// only masks stored rows (which hides them): drives the inspector's
    /// revert-to-stored-values action.
    var hasScriptData: Bool = false

    init(
        kind: Kind, ownerID: UUID?, ownerName: String?, variables: [Variable],
        scriptSetKeys: Set<String> = [], hasScriptData: Bool = false
    ) {
        self.kind = kind
        self.ownerID = ownerID
        self.ownerName = ownerName
        self.variables = variables
        self.scriptSetKeys = scriptSetKeys
        self.hasScriptData = hasScriptData
    }

    var id: String { "\(kind.label)-\(ownerID?.uuidString ?? "none")" }
}

/// Transition alias for the pre-rename scope name. Remove once all call sites use `VariableScope` directly.
typealias RequestVariableScope = VariableScope
