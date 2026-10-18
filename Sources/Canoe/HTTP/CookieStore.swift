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
/// sent back to the same domain on later requests. Lives in the Canoe vault
/// folder next to `drafts.json` / `history.json`, so cookies survive relaunch
/// but never leave the device.
actor CookieStore {
    static let shared = CookieStore()

    private let url: URL
    private var cookies: [StoredCookie] = []
    private var loaded = false

    private init() {
        let appSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let canoeDir = appSupport.appendingPathComponent("Canoe", isDirectory: true)
        self.url = canoeDir.appendingPathComponent("cookies.json")
    }

    /// Cookie header value for `url`, or `nil` when there are no matching
    /// cookies. All cookie state stays inside the actor; callers only receive
    /// a `String`, so nothing non-`Sendable` crosses the actor boundary.
    ///
    /// Matching follows RFC 6265 as far as a client-side jar can: domain
    /// suffix match, path prefix match, secure-only cookies stay off plain
    /// HTTP, and expired cookies never go out (they are also swept from the
    /// jar on load and on write so they cannot accumulate forever).
    func cookieHeader(for url: URL) -> String? {
        loadIfNeeded()
        let host = url.host?.lowercased() ?? ""
        guard !host.isEmpty else { return nil }
        let now = Date()
        let requestPath = url.path
        let isSecure = url.scheme?.lowercased() == "https"
        let fit = cookies.filter { cookie in
            guard cookie.domainMatches(host) else { return false }
            if let expires = cookie.expires, expires <= now { return false }
            if cookie.secure && !isSecure { return false }
            return cookie.pathMatches(requestPath)
        }
        .sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.name < $1.name
        }
        guard !fit.isEmpty else { return nil }
        let httpCookies = fit.compactMap { $0.makeHTTPCookie(for: url) }
        return HTTPCookie.requestHeaderFields(with: httpCookies)["Cookie"]
    }

    /// Parses `Set-Cookie` header values and persists the cookies. Accepts
    /// raw header strings (already extracted from `HTTPURLResponse`) so no
    /// non-`Sendable` response object crosses the actor boundary. Expired
    /// cookies already in the jar are swept here so the file never grows
    /// with dead entries.
    func store(setCookieHeaders: [String], for url: URL) {
        loadIfNeeded()
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
    func allCookies() -> [StoredCookie] {
        loadIfNeeded()
        return cookies
    }

    func deleteCookie(named name: String, domain: String, path: String) {
        loadIfNeeded()
        cookies.removeAll {
            $0.name == name && $0.domain.lowercased() == domain.lowercased() && $0.path == path
        }
        schedulePersistence()
    }

    func clearAll() {
        cookies.removeAll()
        loaded = false
        try? FileManager.default.removeItem(at: url)
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

    private func persist() {
        do {
            let data = try JSONEncoder().encode(cookies.sorted { $0.name < $1.name })
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // Persistence failure must not fail a send.
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        var cookies = (try? JSONDecoder().decode([StoredCookie].self, from: data)) ?? []
        // Sweep expired cookies swept in from an old jar: they can never be
        // sent again, so there is no reason to keep them around.
        let now = Date()
        cookies.removeAll { $0.expires.map { $0 <= now } ?? false }
        self.cookies = cookies
        loaded = true
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
