import Foundation

/// One scope of variables that applies to a request, as shown in the
/// "Variables in Request" inspector: the owning workspace, collection, or
/// environment together with its raw (unmerged) variables.
struct RequestVariableScope: Identifiable, Hashable, Sendable {
    /// Which layer of the Postman-style hierarchy the variables come from.
    /// `rawValue` doubles as the display label.
    enum Kind: String, Hashable, Sendable {
        case workspace = "Workspace"
        case collection = "Collection"
        case environment = "Environment"

        var systemImage: String {
            switch self {
            case .workspace: "square.stack.3d.up.fill"
            case .collection: "folder.fill"
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
    /// can show why a variable does not resolve.
    let variables: [Variable]

    var id: String { "\(kind.rawValue)-\(ownerID?.uuidString ?? "none")" }
}
