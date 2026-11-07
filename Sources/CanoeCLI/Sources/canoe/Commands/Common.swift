import Foundation
import CanoeCore

func resolvedVars(
    loader: VaultLoader,
    config: VaultConfig?,
    collection: Collection?,
    envFlag: String?,
    extraVars: [String: String]
) -> [String: String] {
    let workspace: Workspace?
    if let cid = collection?.workspaceID {
        workspace = loader.workspaces.first(where: { $0.id == cid })
    } else if let id = config?.activeWorkspaceID {
        workspace = loader.workspaces.first(where: { $0.id == id })
    } else {
        workspace = nil
    }
    let env: EnvironmentProfile?
    if let envFlag {
        env = loader.environment(named: envFlag)
    } else if let id = config?.activeEnvironmentID {
        env = loader.environments.first(where: { $0.id == id })
    } else {
        env = nil
    }
    return VariableResolver.mergedDictionary(
        workspace: workspace, collection: collection, environment: env, overrides: extraVars
    )
}

func requestJSON(_ r: Request) -> [String: Any] {
    return [
        "id": r.id.uuidString, "name": r.name, "method": r.method, "url": r.urlString, "urlTemplate": r.urlString,
        "type": r.type, "authType": r.authType,
        "bodyType": r.bodyType, "bodyContentType": r.bodyContentType, "body": r.bodyText,
        "headers": r.headers.filter(\.isEnabled).map { ["name": $0.name, "value": $0.value] },
        "params": r.params.filter(\.isEnabled).map { ["name": $0.name, "value": $0.value] },
        "formFields": r.formFields.map { ["key": $0.key, "value": $0.value, "kind": $0.kind] }
    ]
}

func resolveRequest(args: ParsedArgs, loader: VaultLoader) -> (Collection, Request)? {
    guard let collRef = flag(args, "collection") else { return nil }
    guard let c = loader.collection(named: collRef) else { return nil }
    guard args.positionals.count > 2, let reqRef = args.positionals[2...].first else { return nil }
    guard let r = loader.findRequest(reqRef, in: c) else { return nil }
    return (c, r)
}
