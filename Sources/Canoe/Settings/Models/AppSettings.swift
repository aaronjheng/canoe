import Foundation

/// The app-level configuration schema, persisted as a whole in `settings.json`.
/// UI state (split positions, panel sizes) is deliberately not here — that
/// stays in `UserDefaults`, owned by AppKit.
///
/// `settings.json` is always machine-local, never synced: per-device choices
/// like the vault location must not fight across devices.
struct AppSettings: Codable, Equatable {
    /// `AppAppearance` raw value. The enum mapping lives with the callers so
    /// `Theme` never depends on this area.
    var appearance: Int = 0
    /// Syncs saved vault files via iCloud Drive. Off by default; flipped in
    /// the Sync settings pane, which migrates files on change.
    var iCloudSyncEnabled: Bool = false
    /// Outgoing HTTP/HTTPS proxy applied to every request sent through
    /// URLSession (connectionProxyDictionary).
    var proxy: ProxySettings = ProxySettings()

    init(appearance: Int = 0, iCloudSyncEnabled: Bool = false, proxy: ProxySettings = ProxySettings()) {
        self.appearance = appearance
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.proxy = proxy
    }

    enum CodingKeys: String, CodingKey {
        case appearance
        case iCloudSyncEnabled
        case proxy
    }

    /// Tolerates files written before `iCloudSyncEnabled` or `proxy` existed
    /// so old settings files keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decodeIfPresent(Int.self, forKey: .appearance) ?? 0
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? false
        proxy = try container.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? ProxySettings()
    }
}
