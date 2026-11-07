import Foundation
import CanoeCore

public func runCLI(_ argv: [String]) -> Int32 {
    let args = parseArgs(argv)
    // --help anywhere
    if argv.contains("--help") || argv.contains("-h") || argv.isEmpty || args.positionals.first == nil {
        print(usage())
        return 0
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
    case "vault":
        if subcommand == "info" { return cmdVaultInfo(args: args, loader: loader) }
        print(usage()); return 1
    case "workspace":
        if subcommand == "list" { return cmdWorkspaceList(args: args, loader: loader) }
        print(usage()); return 1
    case "collection":
        switch subcommand {
        case "list": return cmdCollectionList(args: args, loader: loader)
        case "get": return cmdCollectionGet(args: args, loader: loader)
        case "export": return cmdCollectionExport(args: args, loader: loader)
        case "run":
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
        case "preview": return cmdRequestPreview(args: args, loader: loader)
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
        case "set": return cmdEnvSet(args: args, loader: loader)
        default: print(usage()); return 1
        }
    default:
        print(usage())
        return 1
    }
}
