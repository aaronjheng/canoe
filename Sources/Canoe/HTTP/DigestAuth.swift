import CryptoKit
import Foundation

/// Digest access authentication (RFC 2617, plus RFC 7616's SHA-256
/// variants): parses a `WWW-Authenticate: Digest …` challenge, computes the
/// response hash, and renders the `Authorization: Digest …` header. The
/// challenge-response round trip itself lives in `HTTPClient.send` - the
/// first attempt goes out without credentials, the 401's challenge drives
/// the replay.
///
/// `qop=auth` (and the no-qop legacy form) are supported; `auth-int` is
/// declined (it requires hashing the body mid-stream and no core Postman
/// auth helper offers it either).
enum DigestAuth {
    /// Builds the `Authorization` header value for `challenge`, or nil when
    /// the challenge cannot be honored (no nonce, unsupported algorithm or
    /// qop, empty username+password).
    static func responseHeader(
        challenge: String,
        method: String,
        url: URL,
        username: String,
        password: String
    ) -> String? {
        guard !username.isEmpty || !password.isEmpty else { return nil }
        let params = parseChallenge(challenge)
        guard let nonce = params["nonce"], !nonce.isEmpty else { return nil }
        let realm = params["realm"] ?? ""

        // Algorithm: MD5 (default), SHA-256, and their -sess variants.
        // Matched case-insensitively: the RFCs spell them uppercase, but
        // lowercase tokens (`algorithm=md5`) appear in the wild.
        let rawAlgorithm = (params["algorithm"] ?? "MD5").trimmingCharacters(in: .whitespaces)
        guard let algorithm = Algorithm.matching(rawAlgorithm) else { return nil }

        // qop: the server may offer a list ("auth, auth-int"); pick `auth`,
        // declining the challenge when only auth-int is offered.
        let offeredQops = (params["qop"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let qop: String?
        if params["qop"] == nil {
            qop = nil
        } else if offeredQops.contains("auth") {
            qop = "auth"
        } else {
            return nil
        }

        let nc = "00000001"
        let cnonce = randomHex(byteCount: 8)
        let uri: String = {
            var target = url.path.isEmpty ? "/" : url.path
            if let query = url.query {
                target += "?\(query)"
            }
            return target
        }()

        let hash: (String) -> String = algorithm.digest
        // HA1: the -sess variants mix nonce and cnonce into the user hash.
        let baseHA1 = hash("\(username):\(realm):\(password)")
        let ha1 =
            algorithm.isSession
            ? hash("\(baseHA1):\(nonce):\(cnonce)")
            : baseHA1
        let ha2 = hash("\(method):\(uri)")
        // With qop, the chosen qop value appears in the hash twice (RFC
        // 2617 §3.2.2.1): once between nc and cnonce, once before HA2.
        let response =
            qop.map { hash("\(ha1):\(nonce):\(nc):\(cnonce):\($0):\(ha2)") }
            ?? hash("\(ha1):\(nonce):\(ha2)")

        var parts: [String] = [
            "username=\"\(escape(username))\"",
            "realm=\"\(escape(realm))\"",
            "nonce=\"\(escape(nonce))\"",
            "uri=\"\(escape(uri))\"",
        ]
        parts.append("response=\"\(response)\"")
        if let qop {
            parts.append("qop=\(qop)")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\"\(escape(cnonce))\"")
        }
        if let opaque = params["opaque"], !opaque.isEmpty {
            parts.append("opaque=\"\(escape(opaque))\"")
        }
        parts.append("algorithm=\(algorithm.rawValue)")
        return "Digest " + parts.joined(separator: ", ")
    }

    /// Locates the Digest challenge inside a `WWW-Authenticate` header
    /// value. `HTTPURLResponse.value(forHTTPHeaderField:)` merges repeated
    /// headers comma-joined, and servers routinely offer several schemes
    /// ("Basic realm=…, Digest realm=…, nonce=…"), so the prefix check
    /// alone misses Digest when another scheme comes first. The scheme
    /// text is kept (with its leading comma) so `parseChallenge` strips it
    /// as designed; its parser naturally stops at the next scheme (a token
    /// with no `=`).
    static func findChallenge(in headerValue: String) -> String? {
        if headerValue.lowercased().hasPrefix("digest") {
            return headerValue
        }
        if let range = headerValue.range(of: #",\s*digest\s+"#, options: [.regularExpression, .caseInsensitive]) {
            return String(headerValue[range.lowerBound...])
        }
        return nil
    }

    // MARK: - Challenge parsing

    /// `Digest realm="…", nonce="…", qop="auth", opaque="…", algorithm=MD5`
    /// → a lowercased-key dictionary. Values may be quoted (realm and nonce
    /// contain spaces, opaque may contain base64 padding); quoted-pair
    /// escapes (`\"`) are unescaped. Token values (algorithm=MD5) arrive
    /// bare.
    static func parseChallenge(_ challenge: String) -> [String: String] {
        // Strip the scheme ("Digest " / "digest ") - the caller only reaches
        // here for a Digest challenge, and case varies.
        var rest = challenge.trimmingCharacters(in: .whitespaces)
        if let space = rest.firstIndex(of: " ") {
            rest = String(rest[rest.index(after: space)...])
        } else {
            rest = ""
        }

        var params: [String: String] = [:]
        var index = rest.startIndex
        while index < rest.endIndex {
            // Skip separators between pairs.
            while index < rest.endIndex, rest[index] == "," || rest[index] == " " {
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else { break }
            // Key: up to '='.
            var keyEnd = index
            while keyEnd < rest.endIndex, rest[keyEnd] != "=", keyEnd != rest.endIndex {
                keyEnd = rest.index(after: keyEnd)
            }
            guard keyEnd < rest.endIndex, rest[keyEnd] == "=" else { break }
            let key = String(rest[index..<keyEnd]).trimmingCharacters(in: .whitespaces).lowercased()
            index = rest.index(after: keyEnd)
            // Value: quoted string (with \" escapes) or bare token.
            var value = ""
            if index < rest.endIndex, rest[index] == "\"" {
                index = rest.index(after: index)
                var out = ""
                scan: while index < rest.endIndex {
                    let char = rest[index]
                    if char == "\\" {
                        let next = rest.index(after: index)
                        if next < rest.endIndex {
                            out.append(rest[next])
                            index = rest.index(after: next)
                            continue
                        }
                        index = next
                        break scan
                    }
                    if char == "\"" {
                        index = rest.index(after: index)
                        break scan
                    }
                    out.append(char)
                    index = rest.index(after: index)
                }
                value = out
            } else {
                let tokenEnd = rest[index...].firstIndex(of: ",") ?? rest.endIndex
                value = String(rest[index..<tokenEnd]).trimmingCharacters(in: .whitespaces)
                index = tokenEnd
            }
            params[key] = value
        }
        return params
    }

    /// Escapes a header value for quoting (RFC 7616 quoted-pair).
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Algorithms

    private enum Algorithm: String, CaseIterable {
        case md5 = "MD5"
        case md5Sess = "MD5-sess"
        case sha256 = "SHA-256"
        case sha256Sess = "SHA-256-sess"

        static func matching(_ raw: String) -> Algorithm? {
            allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
        }

        var isSession: Bool { self == .md5Sess || self == .sha256Sess }

        func digest(_ input: String) -> String {
            switch self {
            case .md5, .md5Sess:
                Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            case .sha256, .sha256Sess:
                SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
    }
}
