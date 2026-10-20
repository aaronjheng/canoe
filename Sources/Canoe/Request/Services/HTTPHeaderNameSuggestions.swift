import Foundation

/// Catalog of standard HTTP header names for the headers table's key-field
/// completion (Postman suggests common keys while typing there). The table's
/// other bodies (params, form-data, variables) use `{{...}}` suggestions
/// instead, so this list never mixes into them.
enum HTTPHeaderNameSuggestions {
    static let all: [VariableSuggestion] = [
        "Accept": "Media types accepted in the response",
        "Accept-Charset": "Character sets accepted in the response",
        "Accept-Encoding": "Content encodings accepted (gzip, deflate, br)",
        "Accept-Language": "Preferred response languages",
        "Authorization": "Credentials for the request (token, Basic, Bearer)",
        "Cache-Control": "Caching directives along the request/response chain",
        "Connection": "Connection control for this request (keep-alive, close)",
        "Content-Disposition": "Presentation of the payload (inline, attachment, form-data)",
        "Content-Encoding": "Encoding applied to the payload",
        "Content-Language": "Language of the payload",
        "Content-Length": "Payload size in bytes",
        "Content-MD5": "Base64 MD5 digest of the payload",
        "Content-Range": "Byte range this partial payload represents",
        "Content-Type": "Media type of the payload (application/json, multipart/form-data)",
        "Cookie": "Stored cookies sent to the server",
        "Date": "Time the request was created",
        "DNT": "Do-Not-Track preference (1, 0)",
        "Expect": "Server behavior expected before the body is sent (100-continue)",
        "Expires": "Time the payload becomes stale",
        "From": "User agent's email address",
        "Host": "Target host and port of the request",
        "If-Match": "Request proceeds only when the ETag matches",
        "If-Modified-Since": "Request proceeds only when modified after this date",
        "If-None-Match": "Request proceeds only when no ETag matches",
        "If-Range": "Range request applies only when the resource is unchanged",
        "If-Unmodified-Since": "Request proceeds only when unmodified since this date",
        "Last-Modified": "Time the server last changed the resource",
        "Location": "Redirect target or created-resource URI",
        "Max-Forwards": "Hop limit for TRACE/OPTIONS forwarding",
        "Origin": "Scheme/hostname/port the request originates from",
        "Pragma": "Legacy HTTP/1.0 caching directive",
        "Proxy-Authorization": "Credentials for a proxy connection",
        "Range": "Byte range requested from the resource",
        "Referer": "URI of the resource the request came from",
        "Retry-After": "Delay before retrying the request",
        "Server": "Server software that handled the request",
        "TE": "Transfer encodings the user agent accepts",
        "Trailer": "Header names sent after a chunked payload",
        "Transfer-Encoding": "Encoding applied for transfer (chunked)",
        "Upgrade": "Protocol upgrade request (h2c, TLS)",
        "User-Agent": "Software making the request",
        "Via": "Proxies and gateways the request passed through",
        "Warning": "Warnings about the payload",
        "WWW-Authenticate": "Authentication method the server supports",
        "X-API-Key": "API key supplied by the provider",
        "X-HTTP-Method-Override": "Treats the request as the given method",
        "X-Request-ID": "Identifier to trace the request through services",
        "X-Requested-With": "Marks XMLHttpRequest calls",
    ]
    .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    .map { name, summary in
        VariableSuggestion(
            name: name,
            scopeKind: nil,
            scopeName: nil,
            isSecret: false,
            summary: summary
        )
    }
}
