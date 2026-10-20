import Foundation

/// HTTP/HTTPS proxy configuration applied to every outgoing request through
/// URLSession's `connectionProxyDictionary`. Machine-local only (never synced).
struct ProxySettings: Codable, Equatable, Sendable {
    /// Whether the proxy is enabled at all. Off means direct connections.
    var enabled: Bool = false

    /// HTTP proxy host (e.g. `127.0.0.1`). Empty means no HTTP proxy.
    var httpHost: String = ""
    /// HTTP proxy port. `0` means the default.
    var httpPort: Int = 8080

    /// HTTPS proxy host. Empty means no HTTPS proxy.
    var httpsHost: String = ""
    /// HTTPS proxy port. `0` means the default.
    var httpsPort: Int = 8080

    /// Optional proxy authentication (Basic). Left blank when the proxy
    /// does not require credentials.
    var username: String = ""
    var password: String = ""

    /// Comma-separated hosts that bypass the proxy (e.g. `localhost,.example.com`).
    /// A leading dot matches subdomains, matching URLSession's exception
    /// semantics.
    var bypassList: String = ""

    /// The `connectionProxyDictionary` this configuration translates to.
    /// Nil when disabled, meaning "no proxy" for URLSession.
    var connectionProxyDictionary: [String: Any]? {
        guard enabled else { return nil }
        var dict: [String: Any] = [:]

        if !httpHost.isEmpty {
            dict["HTTPEnable"] = 1
            dict["HTTPProxy"] = httpHost
            if httpPort > 0 { dict["HTTPPort"] = httpPort }
        }
        if !httpsHost.isEmpty {
            dict["HTTPSEnable"] = 1
            dict["HTTPSProxy"] = httpsHost
            if httpsPort > 0 { dict["HTTPSPort"] = httpsPort }
        }

        if !username.isEmpty {
            dict["HTTPProxyUser"] = username
            dict["HTTPProxyPassword"] = password
            dict["HTTPSProxyUser"] = username
            dict["HTTPSProxyPassword"] = password
        }

        if !bypassList.isEmpty {
            let exceptions =
                bypassList
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !exceptions.isEmpty {
                dict["Exceptions"] = exceptions
            }
        }

        return dict.isEmpty ? nil : dict
    }

    /// Declared because the decoding initializer below suppresses the
    /// synthesized memberwise one (same rule as `VaultDrafts`).
    init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, httpHost, httpPort, httpsHost, httpsPort, username, password, bypassList
    }

    /// Tolerant like every vault model: a key this build does not know
    /// (a file written by a newer release, or before a field existed) - or
    /// one field with a wrong type - decodes as that property's default
    /// instead of failing the whole file. The synthesized decoder would
    /// throw, `SettingsStore.load` would fall back to the default
    /// `AppSettings`, and the next save would overwrite the user's
    /// appearance, sync flag, and proxy with defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        httpHost = (try? container.decodeIfPresent(String.self, forKey: .httpHost)) ?? ""
        httpPort = (try? container.decodeIfPresent(Int.self, forKey: .httpPort)) ?? 8080
        httpsHost = (try? container.decodeIfPresent(String.self, forKey: .httpsHost)) ?? ""
        httpsPort = (try? container.decodeIfPresent(Int.self, forKey: .httpsPort)) ?? 8080
        username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
        password = (try? container.decodeIfPresent(String.self, forKey: .password)) ?? ""
        bypassList = (try? container.decodeIfPresent(String.self, forKey: .bypassList)) ?? ""
    }
}
