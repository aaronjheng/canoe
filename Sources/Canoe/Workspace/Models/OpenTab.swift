import Foundation

// MARK: - Navigation

/// A single open tab in the workspace detail area:
/// - `.request`: the request editor. The optional second payload is the
///   per-tab view id of a Duplicate Tab (Postman desktop): the request and
///   its unsaved edits are shared, only the response area and in-flight
///   send belong to the tab. nil is the primary tab.
/// - `.environment`: the environment's variables editor.
/// - `.collection`: the collection's variables editor (not a collection
///   overview - case name kept for stored-tab compatibility).
/// - `.folder`: a folder's page (Overview + Authorization).
/// - `.workspace`: the workspace Overview (stats), opened only from the
///   workspaces management list.
/// - `.workspaceVariables`: the workspace's variables editor.
///
/// Codable so the tab strip survives relaunches (machine-local UI state in
/// UserDefaults - never synced).
enum OpenTab: Hashable, Identifiable, Sendable, Codable {
    case request(UUID, UUID? = nil)
    case environment(UUID)
    case collection(UUID)
    case folder(UUID)
    case workspace(UUID)
    case workspaceVariables(UUID)

    var id: Self { self }

    var requestID: UUID? {
        if case .request(let id, _) = self { id } else { nil }
    }

    /// Whether the tab is a second view of a request (a Duplicate Tab).
    var isRequestDuplicateView: Bool {
        if case .request(_, let view) = self { view != nil } else { false }
    }

    var environmentID: UUID? {
        if case .environment(let id) = self { id } else { nil }
    }

    var collectionID: UUID? {
        if case .collection(let id) = self { id } else { nil }
    }

    var folderID: UUID? {
        if case .folder(let id) = self { id } else { nil }
    }

    var workspaceID: UUID? {
        if case .workspace(let id) = self { id } else { nil }
    }

    var workspaceVariablesID: UUID? {
        if case .workspaceVariables(let id) = self { id } else { nil }
    }
}

extension OpenTab {
    private enum CaseKey: String, CodingKey {
        case request, environment, collection, folder, workspace, workspaceVariables
    }

    /// The synthesized form writes each payload under ordinal keys
    /// (`_0`, `_1`, ...) inside the case's nested container - matched here
    /// so hand-rolled decoding reads exactly what past builds saved.
    private enum PayloadKey: String, CodingKey {
        case first = "_0"
        case view = "_1"
    }
}

extension OpenTab {
    // Hand-written so the Duplicate Tab view id round-trips without losing
    // what past builds saved. The shell matches the synthesized format
    // (case name -> nested payload container), and the request view id
    // rides a second slot only when set: a strip saved without it decodes
    // on either build, and a strip saved with it opened in an older build
    // silently drops the extra slot - the duplicate reads as the primary
    // tab, one tab fewer, no data loss.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        func payload(_ key: CaseKey) throws -> KeyedDecodingContainer<PayloadKey> {
            try container.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
        }
        if container.contains(.request) {
            let nested = try payload(.request)
            let id = try nested.decode(UUID.self, forKey: .first)
            let view = try nested.decodeIfPresent(UUID.self, forKey: .view)
            self = .request(id, view)
            return
        }
        if container.contains(.environment) {
            self = .environment(try payload(.environment).decode(UUID.self, forKey: .first))
            return
        }
        if container.contains(.collection) {
            self = .collection(try payload(.collection).decode(UUID.self, forKey: .first))
            return
        }
        if container.contains(.folder) {
            self = .folder(try payload(.folder).decode(UUID.self, forKey: .first))
            return
        }
        if container.contains(.workspace) {
            self = .workspace(try payload(.workspace).decode(UUID.self, forKey: .first))
            return
        }
        if container.contains(.workspaceVariables) {
            self = .workspaceVariables(
                try payload(.workspaceVariables).decode(UUID.self, forKey: .first)
            )
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognized open tab payload"))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .request(let id, let view):
            var nested = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .request)
            try nested.encode(id, forKey: .first)
            try nested.encodeIfPresent(view, forKey: .view)
        case .environment(let id):
            var nested = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .environment)
            try nested.encode(id, forKey: .first)
        case .collection(let id):
            var nested = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .collection)
            try nested.encode(id, forKey: .first)
        case .folder(let id):
            var nested = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .folder)
            try nested.encode(id, forKey: .first)
        case .workspace(let id):
            var nested = container.nestedContainer(keyedBy: PayloadKey.self, forKey: .workspace)
            try nested.encode(id, forKey: .first)
        case .workspaceVariables(let id):
            var nested = container.nestedContainer(
                keyedBy: PayloadKey.self, forKey: .workspaceVariables)
            try nested.encode(id, forKey: .first)
        }
    }
}
