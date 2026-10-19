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
    /// App-wide send defaults (Postman's General settings): the request
    /// timeout and the response size limit. A request can override the
    /// timeout in its own Settings tab.
    var general: GeneralSettings = GeneralSettings()

    init(
        appearance: Int = 0,
        iCloudSyncEnabled: Bool = false,
        proxy: ProxySettings = ProxySettings(),
        general: GeneralSettings = GeneralSettings()
    ) {
        self.appearance = appearance
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.proxy = proxy
        self.general = general
    }

    enum CodingKeys: String, CodingKey {
        case appearance
        case iCloudSyncEnabled
        case proxy
        case general
    }

    /// Tolerates files written before `iCloudSyncEnabled` or `proxy` existed
    /// so old settings files keep loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decodeIfPresent(Int.self, forKey: .appearance) ?? 0
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? false
        proxy = try container.decodeIfPresent(ProxySettings.self, forKey: .proxy) ?? ProxySettings()
        general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
    }
}

/// Requests defaults mirrored from Postman's General settings. Both values
/// use 0 as "unlimited".
struct GeneralSettings: Codable, Equatable, Sendable {
    /// Seconds a request may idle between bytes before it is cut. When the
    /// request's own Settings tab also names a timeout, that value wins.
    /// 0 = no limit (approximated by a 24 h session bound).
    var requestTimeoutSeconds: Int = 0

    /// MB limit on one buffered response body (the viewer and the response
    /// history retain it, so growth must stay bounded). 0 = no limit.
    var maxResponseSizeMB: Int = 50
}
