import Foundation
import CanoeCore

func cmdRequestList(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard let collRef = flag(args, "collection") else { return fail("request list needs --collection <id|name>", json: args.json) }
    guard let c = loader.collection(named: collRef) else { return fail("collection not found: \(collRef)", json: args.json) }
    if args.json {
        printJSON(["collection": c.name, "requests": c.requests.map(requestJSON)])
        return 0
    }
    for r in c.requests {
        print("\(r.method) \(r.name)   \(r.urlString)")
    }
    return 0
}

func cmdRequestGet(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard flag(args, "collection") != nil else { return fail("request get needs --collection <id|name>", json: args.json) }
    guard let (c, r) = resolveRequest(args: args, loader: loader) else {
        return fail("request not found: \(args.positionals.dropFirst(2).first ?? "") in collection \(flag(args, "collection") ?? "")", json: args.json)
    }
    let extraVars = parseOverrides(flagAll(args, "var"))
    let vars = resolvedVars(loader: loader, config: loader.config, collection: c, envFlag: flag(args, "env"), extraVars: extraVars)
    var out = requestJSON(r)
    out["collection"] = c.name
    out["collectionID"] = c.id.uuidString
    out["resolvedVariables"] = vars
    out["resolvedURL"] = VariableResolver.resolve(r.urlString, with: vars)
    if args.json {
        printJSON(out)
    } else {
        print("\(r.method) \(out["resolvedURL"] as? String ?? r.urlString)")
        print("auth: \(r.authType)   body: \(r.bodyType)")
        print("vars: \(vars.count)")
    }
    return 0
}

func cmdRequestPreview(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard flag(args, "collection") != nil else { return fail("request preview needs --collection <id|name>", json: args.json) }
    guard let (c, r) = resolveRequest(args: args, loader: loader) else {
        return fail("request not found: \(args.positionals.dropFirst(2).first ?? "")", json: args.json)
    }
    let extraVars = parseOverrides(flagAll(args, "var"))
    let vars = resolvedVars(loader: loader, config: loader.config, collection: c, envFlag: flag(args, "env"), extraVars: extraVars)
    let timeout = Double(flag(args, "timeout") ?? "30") ?? 30
    let useCookies = !flagBool(args, "no-cookies")
    let preview = Sender.shared.preview(request: r, collection: c, vars: vars, timeoutSeconds: timeout, useCookies: useCookies)
    var out = preview
    out["resolvedVariables"] = vars
    out["collection"] = c.name
    if args.json {
        printJSON(out)
    } else {
        print("\(out["method"] as? String ?? r.method) \(out["url"] as? String ?? "") (dry-run)")
        if let headers = out["headers"] as? [String: String] {
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
        }
        if let body = out["body"] as? String, !body.isEmpty { print(body.prefix(400)) }
        if let err = out["error"] as? String { print("error: \(err)") }
    }
    return 0
}

func cmdRequestSend(args: ParsedArgs, loader: VaultLoader) async -> Int32 {
    guard flag(args, "collection") != nil else { return fail("request send needs --collection <id|name>", json: args.json) }
    guard let (c, r) = resolveRequest(args: args, loader: loader) else {
        return fail("request not found: \(args.positionals.dropFirst(2).first ?? "")", json: args.json)
    }
    let extraVars = parseOverrides(flagAll(args, "var"))
    let vars = resolvedVars(loader: loader, config: loader.config, collection: c, envFlag: flag(args, "env"), extraVars: extraVars)
    let timeout = Double(flag(args, "timeout") ?? "30") ?? 30
    let useCookies = !flagBool(args, "no-cookies")

    if flagBool(args, "dry-run") {
        let preview = Sender.shared.preview(request: r, collection: c, vars: vars, timeoutSeconds: timeout, useCookies: useCookies)
        var out = preview
        out["resolvedVariables"] = vars
        if args.json {
            printJSON(out)
        } else {
            print("\(out["method"] as? String ?? r.method) \(out["url"] as? String ?? "") (dry-run)")
            if let err = out["error"] as? String { print("error: \(err)") }
        }
        return 0
    }

    let result = await Sender.shared.send(request: r, collection: c, vars: vars, timeoutSeconds: timeout, useCookies: useCookies)
    if args.json {
        var dict: [String: Any] = [
            "request": result.request, "method": result.method, "url": result.url,
            "statusCode": result.statusCode ?? NSNull(), "headers": result.headers,
            "body": result.body, "durationMs": result.durationMs
        ]
        if let err = result.error { dict["error"] = err }
        printJSON(dict)
    } else {
        print("\(result.method) \(result.url)")
        print("→ \(result.statusCode.map(String.init) ?? "ERR") (\(Int(result.durationMs))ms)")
        if let err = result.error { print(err) }
        print(result.body.prefix(500))
    }
    return 0
}
