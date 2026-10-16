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
            let exceptions = bypassList
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !exceptions.isEmpty {
                dict["Exceptions"] = exceptions
            }
        }

        return dict.isEmpty ? nil : dict
    }
}
