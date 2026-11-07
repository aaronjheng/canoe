import Foundation
import CanoeCore

func cmdVaultInfo(args: ParsedArgs, loader: VaultLoader) -> Int32 {
    let summary = loader.summary()
    if args.json {
        printJSON(summary)
    } else {
        print("Vault: \(loader.vaultDir.path)")
        print("Workspaces: \(loader.workspaces.count)  Collections: \(loader.collections.count)  Environments: \(loader.environments.count)")
        print("Requests: \(loader.collections.reduce(0) { $0 + $1.requests.count })  Folders: \(loader.collections.reduce(0) { $0 + $1.folders.count })")
    }
    return 0
}
