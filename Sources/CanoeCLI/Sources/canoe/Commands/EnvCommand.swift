import Foundation
import CanoeCore

func cmdEnvList(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    if args.json {
        printJSON(["environments": loader.environments.map { e in
            ["id": e.id.uuidString, "name": e.name, "vars": e.variables.count]
        }])
        return 0
    }
    for e in loader.environments {
        print("\(e.name)  [\(e.id.uuidString)]  (\(e.variables.count) vars)")
    }
    if loader.environments.isEmpty { print("(no environments found)") }
    return 0
}

func cmdEnvGet(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard args.positionals.count > 2, let ref = args.positionals[2...].first else { return fail("env get needs <id|name>", json: args.json) }
    guard let e = loader.environment(named: ref) else { return fail("environment not found: \(ref)", json: args.json) }
    var dict: [String: String] = [:]
    var secrets: [String: Bool] = [:]
    for v in e.variables where v.isEnabled {
        dict[v.key] = v.value
        secrets[v.key] = v.isSecret
    }
    if args.json {
        printJSON(["id": e.id.uuidString, "name": e.name, "workspaceID": e.workspaceID?.uuidString ?? "", "variables": dict, "secrets": secrets])
    } else {
        print("\(e.name) (\(dict.count) vars)")
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) { print("  \(k)=\(v)") }
    }
    return 0
}
