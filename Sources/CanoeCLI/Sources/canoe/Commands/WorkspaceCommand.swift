import Foundation
import CanoeCore

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
