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

func cmdEnvSet(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard args.positionals.count > 3, let ref = args.positionals[2...].first else {
        return fail("env set needs <id|name> KEY=VALUE ...", json: args.json)
    }
    guard let e = loader.environment(named: ref) else { return fail("environment not found: \(ref)", json: args.json) }
    let pairs = Array(args.positionals.dropFirst(3))
    var updates: [String: String] = [:]
    for p in pairs {
        if let eq = p.firstIndex(of: "=") {
            updates[String(p[..<eq])] = String(p[p.index(after: eq)...])
        } else {
            return fail("invalid KEY=VALUE: \(p)", json: args.json)
        }
    }
    if updates.isEmpty { return fail("env set needs at least one KEY=VALUE", json: args.json) }

    let file = loader.environmentFile(forID: e.id)
    do {
        let data = try Data(contentsOf: file)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fail("environment file is not a JSON object", json: args.json)
        }
        var vars = (obj["variables"] as? [[String: Any]]) ?? []
        var changed: [String: String] = [:]
        for (k, v) in updates {
            if let idx = vars.firstIndex(where: { ($0["key"] as? String) == k }) {
                vars[idx]["value"] = v
                vars[idx]["isEnabled"] = true
                // keep existing isSecret / id
            } else {
                vars.append([
                    "id": UUID().uuidString,
                    "key": k,
                    "value": v,
                    "isSecret": false,
                    "isEnabled": true,
                ])
            }
            changed[k] = v
        }
        obj["variables"] = vars
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: file, options: [.atomic])
        if args.json {
            printJSON(["environment": e.name, "updated": changed])
        } else {
            print("Updated \(e.name): \(changed.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))")
        }
        return 0
    } catch let err as NSError where err.domain == "canoe" {
        return fail(err.localizedDescription, json: args.json)
    } catch {
        return fail("failed to update environment file: \(error.localizedDescription)", json: args.json)
    }
}
