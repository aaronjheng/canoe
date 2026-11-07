import Foundation

public func defaultVaultRoot() -> URL {
    if let v = ProcessInfo.processInfo.environment["CANOE_VAULT"], !v.isEmpty {
        return URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
    }
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        let local = appSupport.appendingPathComponent("Canoe", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("vault", isDirectory: true).path) {
            return local
        }
        // Legacy flat layout also counts as local root.
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("workspaces", isDirectory: true).path) {
            return local
        }
    }
    let icloud = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Canoe", isDirectory: true)
    if FileManager.default.fileExists(atPath: icloud.appendingPathComponent("vault", isDirectory: true).path) {
        return icloud
    }
    if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        return appSupport.appendingPathComponent("Canoe", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Canoe", isDirectory: true)
}

public func resolveVaultRoot(flag: String?) -> URL {
    if let flag, !flag.isEmpty {
        let path = (flag as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: path, isDirectory: true)
        if url.lastPathComponent == "vault" { url = url.deletingLastPathComponent() }
        return url
    }
    return defaultVaultRoot()
}
