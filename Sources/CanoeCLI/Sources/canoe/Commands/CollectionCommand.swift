import Foundation
import CanoeCore

func cmdCollectionList(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    if args.json {
        printJSON(["collections": loader.collections.map { c in
            ["id": c.id.uuidString, "name": c.name, "workspaceID": c.workspaceID?.uuidString ?? "",
             "requests": c.requests.count, "folders": c.folders.count]
        }])
        return 0
    }
    for c in loader.collections {
        print("\(c.name)  [\(c.id.uuidString)]  (\(c.requests.count) requests, \(c.folders.count) folders)")
    }
    if loader.collections.isEmpty { print("(no collections found)") }
    return 0
}

/// Read raw collection file for full fidelity (fallback to mapped model).
private func rawCollectionObject(_ c: Collection, loader: VaultLoader) -> [String: Any]? {
    let file = loader.collectionsDir.appendingPathComponent(c.id.uuidString + ".json")
    if FileManager.default.fileExists(atPath: file.path), let data = try? Data(contentsOf: file),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return obj
    }
    return nil
}

func cmdCollectionGet(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard args.positionals.count > 2, let targetRef = args.positionals[2...].first else { return fail("collection get needs <id|name>", json: args.json) }
    guard let c = loader.collection(named: targetRef) else { return fail("collection not found: \(targetRef)", json: args.json) }
    if let obj = rawCollectionObject(c, loader: loader) {
        printJSON(obj)
        return 0
    }
    printJSON(["id": c.id.uuidString, "name": c.name, "workspaceID": c.workspaceID?.uuidString ?? "",
               "requests": c.requests.map(requestJSON), "folders": c.folders.count])
    return 0
}

func cmdCollectionExport(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard args.positionals.count > 2, let targetRef = args.positionals[2...].first else { return fail("collection export needs <id|name>", json: args.json) }
    guard let c = loader.collection(named: targetRef) else { return fail("collection not found: \(targetRef)", json: args.json) }
    let obj: [String: Any]
    if let raw = rawCollectionObject(c, loader: loader) {
        obj = raw
    } else {
        obj = ["id": c.id.uuidString, "name": c.name, "workspaceID": c.workspaceID?.uuidString ?? "",
               "requests": c.requests.map(requestJSON), "folders": c.folders.count]
    }
    if let outPath = flag(args, "output") {
        do {
            let data = try jsonData(obj)
            let url = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
            try data.write(to: url, options: [.atomic])
            print("Wrote \(url.path)")
            return 0
        } catch {
            return fail("cannot write \(outPath): \(error.localizedDescription)", json: args.json)
        }
    }
    printJSON(obj)
    return 0
}

func cmdCollectionRun(args: ParsedArgs, loader: VaultLoader) async -> Int32 {
    guard args.positionals.count > 2, let targetRef = args.positionals[2...].first else { return fail("collection run needs <id|name>", json: args.json) }
    guard let c = loader.collection(named: targetRef) else { return fail("collection not found: \(targetRef)", json: args.json) }
    let extraVars = parseOverrides(flagAll(args, "var"))
    let vars = resolvedVars(loader: loader, config: loader.config, collection: c, envFlag: flag(args, "env"), extraVars: extraVars)
    let timeout = Double(flag(args, "timeout") ?? "30") ?? 30
    let useCookies = !flagBool(args, "no-cookies")
    let dryRun = flagBool(args, "dry-run")
    var results: [Any] = []
    for req in c.requests {
        if dryRun {
            let preview = Sender.shared.preview(request: req, collection: c, vars: vars, timeoutSeconds: timeout, useCookies: useCookies)
            results.append(preview)
            if !args.json {
                print("\(preview["method"] as? String ?? req.method) \(preview["url"] as? String ?? "") (dry-run)")
            }
            continue
        }
        let result = await Sender.shared.send(request: req, collection: c, vars: vars, timeoutSeconds: timeout, useCookies: useCookies)
        var dict: [String: Any] = [
            "request": result.request, "method": result.method, "url": result.url,
            "statusCode": result.statusCode ?? -1, "durationMs": result.durationMs, "body": result.body
        ]
        if let err = result.error { dict["error"] = err }
        results.append(dict)
        if !args.json {
            print("\(result.method) \(result.url) → \(result.statusCode.map(String.init) ?? "ERR") (\(Int(result.durationMs))ms)")
            if let err = result.error { print("  \(err)") }
        }
    }
    if args.json {
        printJSON(["collection": c.name, "results": results])
    }
    return 0
}
