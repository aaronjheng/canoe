import Foundation
import CanoeCore

struct ParsedArgs {
    var positionals: [String] = []
    var flags: [String: [String]] = [:]
    var json: Bool = false
}

func parseArgs(_ raw: [String]) -> ParsedArgs {
    var out = ParsedArgs()
    var i = raw.startIndex
    while i < raw.endIndex {
        let a = raw[i]
        if a == "--" {
            out.positionals.append(contentsOf: raw[raw.index(after: i)...])
            break
        } else if a == "--json" {
            out.json = true
        } else if a.hasPrefix("--"), a.contains("=") {
            let parts = a.dropFirst(2).split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                out.flags[String(parts[0]), default: []].append(String(parts[1]))
            }
        } else if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if raw.index(after: i) < raw.endIndex, !raw[raw.index(after: i)].hasPrefix("--") {
                out.flags[key, default: []].append(raw[raw.index(after: i)])
                i = raw.index(after: i)
            } else {
                out.flags[key, default: []].append("true")
            }
        } else if a.hasPrefix("-"), a != "-" {
            out.flags[a, default: []].append("true")
        } else {
            out.positionals.append(a)
        }
        i = raw.index(after: i)
    }
    return out
}

func flag(_ args: ParsedArgs, _ key: String) -> String? { args.flags[key]?.first }
func flagAll(_ args: ParsedArgs, _ key: String) -> [String] { args.flags[key] ?? [] }

func usage() -> String {
    """
    canoe — local-first API client CLI (Canoe vault reader/sender)

    USAGE:
      canoe [--vault <path>] [--json] <command> [args]

    COMMANDS:
      init [target-dir]           Write CANOE_AGENT.md skill file into target-dir (default: cwd)
      workspace list              List workspaces
      collection list             List collections
      collection get <id|name>    Dump one collection as JSON
      collection run <id|name>    Send every request in a collection sequentially
      request list                List requests (requires --collection <id|name>)
      request get <id|name>       Dump one request (requires --collection)
      request send <id|name>      Send one request (requires --collection)
      env list                    List environments
      env get <id|name>           Dump one environment as JSON

    FLAGS:
      --vault <path>     Vault root (or vault/ dir). Default: $CANOE_VAULT /
                         ~/Library/Application Support/Canoe, else iCloud Canoe
      --json             Machine JSON output (for agents). Default for get/run/send.
      --env <id|name>    Environment for variable resolution
      --collection <id|name>  Collection for request commands
      --var key=value    Extra variable override (repeatable)
      --timeout <sec>    Send timeout (default 30)
      --no-cookies       Disable cookie jar

    Lookup accepts UUID or name (exact, then substring).
    Variables resolve {{name}} in order: workspace → collection → environment,
    then --var overrides. Unknown placeholders stay as-is.

    EXAMPLES:
      canoe workspace list --json
      canoe collection list --json
      canoe request list --collection CS --json
      canoe request get "/v1/console/me" --collection CS --env "3 Staging" --json
      canoe request send "/v1/console/me" --collection CS --var cs_base_url=https://example.invalid --json
      canoe collection run CS --env staging --json
      canoe init /tmp/myproj
      CANOE_VAULT=~/.../Canoe canoe env list --json
    """
}

func parseOverrides(_ items: [String]) -> [String: String] {
    var dict: [String: String] = [:]
    for item in items {
        if let eq = item.firstIndex(of: "=") {
            dict[String(item[..<eq])] = String(item[item.index(after: eq)...])
        } else {
            dict[item] = ""
        }
    }
    return dict
}

func fail(_ message: String, json: Bool = false) -> Int32 {
    if json {
        printJSON(["error": message])
    } else {
        fputs("error: \(message)\n", stderr)
    }
    return 1
}

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

// MARK: - Commands

func cmdInit(args: ParsedArgs, vaultRoot: URL) -> Int32 {
    let target: URL
    if args.positionals.count > 1, !args.positionals[1].isEmpty {
        target = URL(fileURLWithPath: (args.positionals[1] as NSString).expandingTildeInPath, isDirectory: true)
    } else {
        target = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }
    do {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    } catch {
        return fail("cannot create directory \(target.path): \(error.localizedDescription)", json: args.json)
    }
    let out = target.appendingPathComponent("CANOE_AGENT.md")
    let body = """
    # Canoe Agent Skill

    Canoe is a local-first API client. This workspace talks to your Canoe vault via the `canoe` CLI -- no GUI, no login.

    Vault root: `\(vaultRoot.path)`
    Vault dir (`vault/`): `\(vaultRoot.appendingPathComponent("vault", isDirectory: true).path)`
    Override with `--vault <path>` or `$CANOE_VAULT`.

    ## Rules

    - Always pass `--json` and read machine output; do not parse human tables.
    - Lookup accepts a UUID **or** a name (exact, then substring). Check with the `list` command first.
    - Variables resolve `{{name}}` in order: workspace → collection → environment, then `--var key=value` overrides. Pass explicit `--env` instead of guessing the active one.
    - Sending a request is network I/O. Only send when the user asked, or when verifying a change.
    - Pre/post-request scripts are NOT run by this CLI. If a request depends on them (e.g. token minted by a login pre-script), open Canoe.app for that part.
    - Never edit `vault/*.json` by hand. Use the Canoe app for structural edits; use this CLI for read, send, and variable overrides.

    ## Cheatsheet

    ```bash
    canoe collection list --json
    canoe request list --collection "Users" --json
    canoe request get "Get User" --collection "Users" --json
    canoe request send "Get User" --collection "Users" --env staging --var baseUrl=https://staging.api --json
    canoe collection run "Users" --env staging --json
    canoe env list --json
    ```

    ## Workflow

    1. `canoe collection list --json` → pick a collection.
    2. `canoe request list --collection "<name>" --json` → pick a request.
    3. `canoe request get "<request>" --collection "<collection>" --json` → read URL, headers, body, auth.
    4. `canoe request send "<request>" --collection "<collection>" --env <env> --json` → inspect status/body.
    5. Open Canoe.app to review the request as-is.

    Generated by `canoe init`. Re-run `canoe init --vault <path>` to re-point at another vault.
    """
    do {
        try body.write(to: out, atomically: true, encoding: .utf8)
    } catch {
        return fail("cannot write \(out.path): \(error.localizedDescription)", json: args.json)
    }
    print("Wrote \(out.path)")
    print("Vault root: \(vaultRoot.path)")
    print("Next: read CANOE_AGENT.md in your coding agent, then run `canoe collection list --json`.")
    return 0
}

func cmdWorkspaceList(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    if args.json {
        printJSON(["workspaces": loader.workspaces.map { w in
            ["id": w.id.uuidString, "name": w.name, "vars": w.variables.count]
        }])
        return 0
    }
    for w in loader.workspaces {
        print("\(w.name)  [\(w.id.uuidString)]  (\(w.variables.count) vars)")
    }
    if loader.workspaces.isEmpty { print("(no workspaces found at \(loader.vaultDir.path))") }
    return 0
}

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

func cmdCollectionGet(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    guard args.positionals.count > 2, let targetRef = args.positionals[2...].first else { return fail("collection get needs <id|name>", json: args.json) }
    guard let c = loader.collection(named: targetRef) else { return fail("collection not found: \(targetRef)", json: args.json) }
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Re-read raw JSON file if present for full fidelity
        let file = loader.collectionsDir.appendingPathComponent(c.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path), let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            printJSON(obj)
            return 0
        }
        _ = decoder
        printJSON(["id": c.id.uuidString, "name": c.name, "workspaceID": c.workspaceID?.uuidString ?? "",
                   "requests": c.requests.map(requestJSON), "folders": c.folders.count])
        return 0
    } catch {
        return fail("failed to dump collection: \(error.localizedDescription)", json: args.json)
    }
}

func cmdCollectionRun(args: ParsedArgs, loader: VaultLoader) async -> Int32 {
    guard args.positionals.count > 2, let targetRef = args.positionals[2...].first else { return fail("collection run needs <id|name>", json: args.json) }
    guard let c = loader.collection(named: targetRef) else { return fail("collection not found: \(targetRef)", json: args.json) }
    let extraVars = parseOverrides(flagAll(args, "var"))
    let vars = resolvedVars(loader: loader, config: loader.config, collection: c, envFlag: flag(args, "env"), extraVars: extraVars)
    let timeout = Double(flag(args, "timeout") ?? "30") ?? 30
    let useCookies = !args.flags.keys.contains("no-cookies")
    var results: [Any] = []
    for req in c.requests {
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

func resolveRequest(args: ParsedArgs, loader: VaultLoader) -> (Collection, Request)? {
    guard let collRef = flag(args, "collection") else { return nil }
    guard let c = loader.collection(named: collRef) else { return nil }
    guard args.positionals.count > 2, let reqRef = args.positionals[2...].first else { return nil }
    guard let r = loader.findRequest(reqRef, in: c) else { return nil }
    return (c, r)
}

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

func cmdRequestSend(args: ParsedArgs, loader: VaultLoader) async -> Int32 {
    guard flag(args, "collection") != nil else { return fail("request send needs --collection <id|name>", json: args.json) }
    guard let (c, r) = resolveRequest(args: args, loader: loader) else {
        return fail("request not found: \(args.positionals.dropFirst(2).first ?? "")", json: args.json)
    }
    let extraVars = parseOverrides(flagAll(args, "var"))
    let vars = resolvedVars(loader: loader, config: loader.config, collection: c, envFlag: flag(args, "env"), extraVars: extraVars)
    let timeout = Double(flag(args, "timeout") ?? "30") ?? 30
    let useCookies = !args.flags.keys.contains("no-cookies")
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
    return result.error != nil && result.statusCode == nil ? 0 : 0
}

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
    for v in e.variables where v.isEnabled { dict[v.key] = v.value }
    if args.json {
        printJSON(["id": e.id.uuidString, "name": e.name, "workspaceID": e.workspaceID?.uuidString ?? "", "variables": dict])
    } else {
        print("\(e.name) (\(dict.count) vars)")
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) { print("  \(k)=\(v)") }
    }
    return 0
}

public func runCLI(_ argv: [String]) -> Int32 {
    let args = parseArgs(argv)
    // --help anywhere
    if argv.contains("--help") || argv.contains("-h") || argv.isEmpty || args.positionals.first == nil {
        print(usage())
        return argv.isEmpty ? 0 : 0
    }
    let vaultRoot = resolveVaultRoot(flag: flag(args, "vault"))

    guard let cmdGroup = args.positionals.first else {
        print(usage())
        return 0
    }

    if cmdGroup == "init" {
        return cmdInit(args: args, vaultRoot: vaultRoot)
    }

    let loader: VaultLoader
    do {
        loader = try VaultLoader(root: vaultRoot)
    } catch {
        return fail("cannot load vault at \(vaultRoot.path): \(error.localizedDescription)", json: args.json)
    }

    let subcommand = args.positionals.count > 1 ? args.positionals[1] : nil

    switch cmdGroup {
    case "workspace":
        if subcommand == "list" { return cmdWorkspaceList(args: args, loader: loader) }
        print(usage()); return 1
    case "collection":
        switch subcommand {
        case "list": return cmdCollectionList(args: args, loader: loader)
        case "get": return cmdCollectionGet(args: args, loader: loader)
        case "run":
            // async wrapper: block on semaphore
            final class Box: @unchecked Sendable { var code: Int32 = 1 }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task {
                box.code = await cmdCollectionRun(args: args, loader: loader)
                sem.signal()
            }
            sem.wait()
            return box.code
        default: print(usage()); return 1
        }
    case "request":
        switch subcommand {
        case "list": return cmdRequestList(args: args, loader: loader)
        case "get": return cmdRequestGet(args: args, loader: loader)
        case "send":
            final class Box: @unchecked Sendable { var code: Int32 = 1 }
            let box = Box()
            let sem = DispatchSemaphore(value: 0)
            Task {
                box.code = await cmdRequestSend(args: args, loader: loader)
                sem.signal()
            }
            sem.wait()
            return box.code
        default: print(usage()); return 1
        }
    case "env":
        switch subcommand {
        case "list": return cmdEnvList(args: args, loader: loader)
        case "get": return cmdEnvGet(args: args, loader: loader)
        default: print(usage()); return 1
        }
    default:
        print(usage())
        return 1
    }
}
