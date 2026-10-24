import Foundation

/// A cookie value persisted between launches. Machine-local only (never synced).
struct StoredCookie: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    var expires: Date?
}

/// Postman-style cookie jar: responses' `Set-Cookie` headers are stored and
/// sent back to the same domain on later requests. Persisted into the
/// machine-local SQLite store (`canoe.sqlite`), so cookies survive relaunch
/// but never leave the device.
actor CookieStore {
    static let shared = CookieStore()

    /// Own connection to the shared store - `VaultStore` holds another to
    /// the same file; SQLite serializes the two, and the jar's writes are
    /// tiny and debounced.
    private var database: LocalDatabase?
    private var cookies: [StoredCookie] = []
    private var loaded = false

    init() {}

    /// Opens the store once. Nil only when the Application Support root is
    /// unavailable - the jar then degrades to in-memory for the session.
    private func localStore() async -> LocalDatabase? {
        if let database { return database }
        let appSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let newDatabase = LocalDatabase(
            fileURL: appSupport.appendingPathComponent("Canoe", isDirectory: true)
                .appendingPathComponent("canoe.sqlite"))
        do {
            try await newDatabase.open()
            database = newDatabase
            return newDatabase
        } catch {
            AppLogger.error(
                "Failed to open the local store for cookies: \(error)", category: "Vault")
            return nil
        }
    }

    /// Structured cookies matching `url` (the scripts' pm.cookies surface):
    /// name/value/domain/path/secure per cookie, same fit rules as
    /// `cookieHeader(for:)`.
    func cookies(for url: URL) async -> [[String: String]] {
        await loadIfNeeded()
        let host = url.host?.lowercased() ?? ""
        guard !host.isEmpty else { return [] }
        return fittingCookies(for: url, host: host, isSecure: url.scheme?.lowercased() == "https", now: Date())
            .map { cookie in
                [
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": cookie.domain,
                    "path": cookie.path,
                    "secure": cookie.secure ? "true" : "false",
                ]
            }
    }

    /// Cookie header value for `url`, or `nil` when there are no matching
    /// cookies. All cookie state stays inside the actor; callers only receive
    /// a `String`, so nothing non-`Sendable` crosses the actor boundary.
    ///
    /// Matching follows RFC 6265 as far as a client-side jar can: domain
    /// suffix match, path prefix match, secure-only cookies stay off plain
    /// HTTP, and expired cookies never go out (they are also swept from the
    /// jar on load and on write so they cannot accumulate forever).
    func cookieHeader(for url: URL) async -> String? {
        await loadIfNeeded()
        let host = url.host?.lowercased() ?? ""
        guard !host.isEmpty else { return nil }
        let fit = fittingCookies(
            for: url, host: host,
            isSecure: url.scheme?.lowercased() == "https", now: Date())
        guard !fit.isEmpty else { return nil }
        let httpCookies = fit.compactMap { $0.makeHTTPCookie(for: url) }
        return HTTPCookie.requestHeaderFields(with: httpCookies)["Cookie"]
    }

    /// Cookies that fit `url` (domain/path/secure/expiry rules), longest
    /// path first. Shared by the header builder and the scripts' snapshot.
    private func fittingCookies(
        for url: URL, host: String, isSecure: Bool, now: Date
    ) -> [StoredCookie] {
        let requestPath = url.path
        return
            cookies
            .filter { cookie in
                guard cookie.domainMatches(host) else { return false }
                if let expires = cookie.expires, expires <= now { return false }
                if cookie.secure && !isSecure { return false }
                return cookie.pathMatches(requestPath)
            }
            .sorted {
                if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                return $0.name < $1.name
            }
    }

    /// Parses `Set-Cookie` header values and persists the cookies. Accepts
    /// raw header strings (already extracted from `HTTPURLResponse`) so no
    /// non-`Sendable` response object crosses the actor boundary. Expired
    /// cookies already in the jar are swept here so the jar never grows
    /// with dead entries.
    func store(setCookieHeaders: [String], for url: URL) async {
        await loadIfNeeded()
        guard !setCookieHeaders.isEmpty else { return }
        let now = Date()
        cookies.removeAll { $0.expires.map { $0 <= now } ?? false }
        let newCookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": setCookieHeaders.joined(separator: "\n")],
            for: url
        )
        guard !newCookies.isEmpty else { return }
        var next = cookies
        for cookie in newCookies {
            next.removeAll { $0.name == cookie.name && $0.domain.lowercased() == cookie.domain.lowercased() && $0.path == cookie.path }
            next.append(
                StoredCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    path: cookie.path,
                    secure: cookie.isSecure,
                    httpOnly: cookie.isHTTPOnly,
                    expires: cookie.expiresDate
                ))
        }
        cookies = next
        schedulePersistence()
    }

    /// Every stored cookie (for a cookie manager UI).
    func allCookies() async -> [StoredCookie] {
        await loadIfNeeded()
        return cookies
    }

    func deleteCookie(named name: String, domain: String, path: String) async {
        await loadIfNeeded()
        cookies.removeAll {
            $0.name == name && $0.domain.lowercased() == domain.lowercased() && $0.path == path
        }
        schedulePersistence()
    }

    func clearAll() async {
        cookies.removeAll()
        await persist()
    }

    // MARK: - Persistence

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            await self.persist()
        }
    }

    private var persistenceTask: Task<Void, Never>?

    private func persist() async {
        guard let database = await localStore() else { return }
        do {
            try await database.saveCookies(cookies.sorted { $0.name < $1.name })
        } catch {
            // Persistence failure must not fail a send.
            AppLogger.error("Failed to save cookies: \(error)", category: "Vault")
        }
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        // Claim the flag before awaiting: a second call must not re-load
        // while the first is suspended on the store.
        loaded = true
        guard let database = await localStore() else { return }
        var loadedCookies = (try? await database.loadCookies()) ?? []
        // Sweep expired cookies swept in from an old jar: they can never be
        // sent again, so there is no reason to keep them around.
        let now = Date()
        loadedCookies.removeAll { $0.expires.map { $0 <= now } ?? false }
        cookies = loadedCookies
    }
}

extension StoredCookie {
    func domainMatches(_ host: String) -> Bool {
        let lowercasedDomain = domain.lowercased()
        if lowercasedDomain == host { return true }
        if lowercasedDomain.hasPrefix("."), host.hasSuffix(lowercasedDomain.dropFirst()) { return true }
        return false
    }

    /// RFC 6265 path match: the request URI path must equal the cookie path,
    /// or start with it where the cookie path ends with "/" or the next
    /// request-path character is "/". "/" matches everything.
    func pathMatches(_ requestPath: String) -> Bool {
        if path == "/" { return true }
        if requestPath == path { return true }
        guard requestPath.count > path.count, requestPath.hasPrefix(path) else { return false }
        if path.hasSuffix("/") { return true }
        return requestPath[requestPath.index(after: path.endIndex)] == "/"
    }

    func makeHTTPCookie(for url: URL) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .secure: secure,
        ]
        if httpOnly {
            props[HTTPCookiePropertyKey(rawValue: "HTTPOnly")] = true
        }
        if let expires {
            props[.expires] = expires
        }
        return HTTPCookie(properties: props)
    }
}
