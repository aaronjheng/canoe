import Foundation
import SQLite3

/// The machine-local SQLite store for per-device runtime data that is not
/// worth a JSON file of its own. Lives next to the other machine-local files
/// in Application Support as `canoe.sqlite` - always local, never
/// synced, even when the vault itself lives on iCloud Drive (the same rule
/// as drafts and history). Grows one table per kind of data; the variable
/// overrides table is first (script-written values, see `VariableOverrides`),
/// with drafts / history / console as future tenants.
///
/// One serial actor owns the connection: SQLite is happiest with a single
/// writer, and every call site already debounces (a burst of sends coalesces
/// into one transaction). Like drafts and history, nothing here is precious -
/// a lost store rebuilds by re-running the scripts (a login send re-mints
/// the token), so failures are logged, not bannered.
actor LocalDatabase {
    /// The C API's SQLITE_TRANSIENT: the all-ones pointer sentinel telling
    /// SQLite to copy the bound string immediately.
    private static let transient = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

    /// Schema, versioned via `user_version` for future migrations. History
    /// and drafts rewrite whole tables per save (small rows); console and
    /// response history mirror-sync by row identity so their (potentially
    /// megabyte) bodies only re-write when actually changed.
    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS variable_overrides (
            kind TEXT NOT NULL,
            owner_id TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT,
            row_id TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (kind, owner_id, key)
        );
        CREATE TABLE IF NOT EXISTS history (
            position INTEGER NOT NULL,
            request_id TEXT,
            name TEXT NOT NULL,
            method TEXT NOT NULL,
            url TEXT NOT NULL,
            status_code INTEGER NOT NULL,
            duration REAL NOT NULL,
            error_kind TEXT,
            timestamp REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS console (
            id TEXT PRIMARY KEY,
            date REAL NOT NULL,
            request_name TEXT NOT NULL,
            method TEXT NOT NULL,
            url TEXT NOT NULL,
            request_headers BLOB NOT NULL,
            request_body BLOB,
            request_body_truncated INTEGER NOT NULL,
            status_code INTEGER,
            response_headers BLOB NOT NULL,
            response_body BLOB,
            response_body_truncated INTEGER NOT NULL,
            duration REAL,
            error TEXT,
            http_version TEXT,
            saved_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS response_history (
            request_id TEXT NOT NULL,
            response_id TEXT NOT NULL,
            timestamp REAL NOT NULL,
            payload BLOB NOT NULL,
            saved_at REAL NOT NULL,
            PRIMARY KEY (request_id, response_id)
        );
        CREATE TABLE IF NOT EXISTS drafts (
            kind TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            payload BLOB NOT NULL,
            saved_at REAL NOT NULL,
            PRIMARY KEY (kind, entity_id)
        );
        CREATE TABLE IF NOT EXISTS cookies (
            name TEXT NOT NULL,
            domain TEXT NOT NULL,
            path TEXT NOT NULL,
            value TEXT NOT NULL,
            secure INTEGER NOT NULL,
            http_only INTEGER NOT NULL,
            expires REAL,
            saved_at REAL NOT NULL,
            PRIMARY KEY (name, domain, path)
        );
        CREATE TABLE IF NOT EXISTS vault_deletions (
            path TEXT PRIMARY KEY,
            deleted_at REAL NOT NULL
        );
        PRAGMA user_version = 1;
        """

    struct Failure: Error, LocalizedError {
        let code: Int32
        let message: String

        var errorDescription: String? { message }
        /// Whether the store file itself is unreadable (vs a transient
        /// condition like a full disk): the caller moves such a file aside
        /// and recreates it - nothing here is precious enough to block a send.
        var isCorruption: Bool {
            let primary = code & 0xFF
            return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
        }
    }

    private let fileURL: URL
    private var handle: OpaquePointer?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // No deinit: the store lives for the whole app session (cached in
    // VaultStore), and a nonisolated deinit cannot touch the non-Sendable
    // handle under strict concurrency. Process exit releases it; the WAL is
    // crash-safe and recovers on the next open.

    // MARK: - Lifecycle

    /// Opens the store, creating the file (and its directory) on first use.
    /// A file that cannot even be initialized is moved aside - WAL sidecars
    /// included - and recreated empty.
    func open() throws {
        guard handle == nil else { return }
        do {
            try openHandle()
        } catch let failure as Failure where failure.isCorruption {
            AppLogger.error("Local store unreadable, recreating: \(failure.message)", category: "Vault")
            moveAside()
            try openHandle()
        }
    }

    private func openHandle() throws {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            sqlite3_close_v2(opened)
            throw Failure(code: SQLITE_CANTOPEN, message: message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 5_000)
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            try exec(Self.schemaSQL)
        } catch {
            sqlite3_close_v2(opened)
            handle = nil
            throw error
        }
    }

    /// Renames the store file and its WAL sidecars aside with a timestamp,
    /// leaving the next open to create a fresh database.
    private func moveAside() {
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: fileURL.path + suffix) {
            let aside = URL(fileURLWithPath: "\(fileURL.path).corrupt-\(stamp)\(suffix)")
            try? FileManager.default.moveItem(at: URL(fileURLWithPath: fileURL.path + suffix), to: aside)
        }
    }

    // MARK: - Variable overrides

    /// Loads every override row, rebuilding the in-memory model (scope kind
    /// -> owner id -> key -> entry). A value column of NULL is the unset
    /// mask. Unreadable row ids drop that row, not the load.
    func loadVariableOverrides() throws -> VariableOverrides {
        guard let handle else { return VariableOverrides() }
        var overrides = VariableOverrides()
        let sql = "SELECT kind, owner_id, key, value, row_id FROM variable_overrides"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let kind = columnText(statement, 0),
                let ownerID = columnText(statement, 1),
                let key = columnText(statement, 2),
                let rowIDText = columnText(statement, 4),
                let rowID = UUID(uuidString: rowIDText)
            else { continue }
            let value = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : columnText(statement, 3)
            overrides.scopes[kind, default: [:]][ownerID, default: [:]][key] =
                VariableOverrides.Entry(value: value, rowID: rowID)
        }
        return overrides
    }

    /// Replaces the whole overrides table in one transaction - the store's
    /// rows are the mirror of a small in-memory model, so a rewrite is both
    /// simpler and cheaper than diffing (the JSON mirror did the same).
    func saveVariableOverrides(_ overrides: VariableOverrides) throws {
        guard let handle else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM variable_overrides")
            let sql = """
                INSERT INTO variable_overrides (kind, owner_id, key, value, row_id, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
            }
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            for (kind, owners) in overrides.scopes {
                for (ownerID, entries) in owners {
                    for (key, entry) in entries {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        bindText(statement, 1, kind)
                        bindText(statement, 2, ownerID)
                        bindText(statement, 3, key)
                        if let value = entry.value {
                            bindText(statement, 4, value)
                        } else {
                            sqlite3_bind_null(statement, 4)
                        }
                        bindText(statement, 5, entry.rowID.uuidString)
                        sqlite3_bind_double(statement, 6, now)
                        guard sqlite3_step(statement) == SQLITE_DONE else {
                            throw Failure(
                                code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
                        }
                    }
                }
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - History

    /// Loads up to `limit` entries, newest first - `position 0` mirrors the
    /// in-memory array's order, so persisted order survives exactly. Rows
    /// that fail to map (an unknown method raw value, a null required
    /// column) are skipped individually - row-per-entry replaces the old
    /// `Lossy` array tolerance.
    func loadHistory(limit: Int) throws -> [HistoryEntry] {
        guard let handle else { return [] }
        let sql = """
            SELECT request_id, name, method, url, status_code, duration, error_kind, timestamp
            FROM history ORDER BY position ASC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(
                HistoryEntry(
                    requestID: columnText(statement, 0).flatMap(UUID.init(uuidString:)),
                    name: columnText(statement, 1) ?? "",
                    method: HTTPMethod(rawValue: columnText(statement, 2) ?? "") ?? .get,
                    urlString: columnText(statement, 3) ?? "",
                    statusCode: Int(sqlite3_column_int64(statement, 4)),
                    duration: sqlite3_column_double(statement, 5),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    errorKind: columnText(statement, 6)))
        }
        return entries
    }

    /// Rewrites the history table to exactly the in-memory list (a hundred
    /// small rows - simpler than diffing, same as the old whole-file mirror).
    func saveHistory(_ entries: [HistoryEntry]) throws {
        guard let handle else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM history")
            let sql = """
                INSERT INTO history
                    (position, request_id, name, method, url, status_code, duration,
                     error_kind, timestamp)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            for (position, entry) in entries.enumerated() {
                try run(sql) { statement in
                    sqlite3_bind_int(statement, 1, Int32(position))
                    bindOptionalText(statement, 2, entry.requestID?.uuidString)
                    bindText(statement, 3, entry.name)
                    bindText(statement, 4, entry.method.rawValue)
                    bindText(statement, 5, entry.urlString)
                    sqlite3_bind_int64(statement, 6, Int64(entry.statusCode))
                    sqlite3_bind_double(statement, 7, entry.duration)
                    bindOptionalText(statement, 8, entry.errorKind)
                    sqlite3_bind_double(statement, 9, entry.timestamp.timeIntervalSince1970)
                }
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Console

    /// Loads up to `limit` entries, oldest first (the in-memory log's order:
    /// newest last). Takes the newest `limit` rows and reverses; rowid breaks
    /// date ties in insertion order. A row whose header JSON no longer
    /// decodes is skipped individually.
    func loadConsole(limit: Int) throws -> [ConsoleEntry] {
        guard let handle else { return [] }
        let sql = """
            SELECT date, request_name, method, url, request_headers, request_body,
                   request_body_truncated, status_code, response_headers, response_body,
                   response_body_truncated, duration, error, http_version
            FROM console ORDER BY date DESC, rowid DESC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
        var entries: [ConsoleEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let requestHeaders = columnJSON([HTTPHeader].self, statement, 4),
                let responseHeaders = columnJSON([HTTPHeader].self, statement, 8)
            else { continue }
            let statusCode =
                sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 7))
            entries.append(
                ConsoleEntry(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    requestName: columnText(statement, 1) ?? "",
                    method: columnText(statement, 2) ?? "",
                    url: columnText(statement, 3) ?? "",
                    requestHeaders: requestHeaders,
                    requestBody: columnData(statement, 5),
                    requestBodyTruncated: sqlite3_column_int(statement, 6) != 0,
                    statusCode: statusCode,
                    responseHeaders: responseHeaders,
                    responseBody: columnData(statement, 9),
                    responseBodyTruncated: sqlite3_column_int(statement, 10) != 0,
                    duration: sqlite3_column_type(statement, 11) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 11),
                    error: columnText(statement, 12),
                    httpVersion: columnText(statement, 13)))
        }
        return entries.reversed()
    }

    /// Mirror-syncs the console table to the in-memory log by row identity:
    /// rows the trimmed log no longer carries are deleted, the rest are
    /// upserted - megabyte bodies only re-write when actually changed. Entry
    /// identities are per-session (fresh on every decode), so the first save
    /// after a relaunch syncs the whole table once; sends within a session
    /// write exactly one new row.
    func saveConsole(_ entries: [ConsoleEntry]) throws {
        guard let handle else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            let ids = entries.map(\.id.uuidString)
            if ids.isEmpty {
                try exec("DELETE FROM console")
            } else {
                try run(
                    "DELETE FROM console WHERE id NOT IN (\(placeholders(ids.count)))"
                ) { statement in
                    for (index, id) in ids.enumerated() {
                        bindText(statement, Int32(index + 1), id)
                    }
                }
            }
            let sql = """
                INSERT OR REPLACE INTO console
                    (id, date, request_name, method, url, request_headers, request_body,
                     request_body_truncated, status_code, response_headers, response_body,
                     response_body_truncated, duration, error, http_version, saved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            let now = Date().timeIntervalSince1970
            for entry in entries {
                try run(sql) { statement in
                    bindText(statement, 1, entry.id.uuidString)
                    sqlite3_bind_double(statement, 2, entry.date.timeIntervalSince1970)
                    bindText(statement, 3, entry.requestName)
                    bindText(statement, 4, entry.method)
                    bindText(statement, 5, entry.url)
                    try bindJSON(entry.requestHeaders, into: statement, 6)
                    bindOptionalBlob(statement, 7, entry.requestBody)
                    sqlite3_bind_int(statement, 8, entry.requestBodyTruncated ? 1 : 0)
                    bindOptionalInt(statement, 9, entry.statusCode.map(Int64.init))
                    try bindJSON(entry.responseHeaders, into: statement, 10)
                    bindOptionalBlob(statement, 11, entry.responseBody)
                    sqlite3_bind_int(statement, 12, entry.responseBodyTruncated ? 1 : 0)
                    bindOptionalDouble(statement, 13, entry.duration)
                    bindOptionalText(statement, 14, entry.error)
                    bindOptionalText(statement, 15, entry.httpVersion)
                    sqlite3_bind_double(statement, 16, now)
                }
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Response history

    /// Loads the per-request response histories, newest first within each
    /// request (timestamp DESC, rowid DESC breaks same-second ties in
    /// insertion order), trimmed to `limit` per request. A row whose payload
    /// no longer decodes is skipped individually.
    /// One pending response-history row during load: the timestamp and
    /// insertion order that reconstruct the in-memory array's ordering.
    private struct PendingResponseRow {
        let timestamp: Double
        let rowid: Int64
        let model: ResponseModel
    }

    func loadResponseHistory(limit: Int) throws -> [UUID: [ResponseModel]] {
        guard let handle else { return [:] }
        let sql = "SELECT request_id, payload, timestamp, rowid FROM response_history ORDER BY rowid ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        var rows: [UUID: [PendingResponseRow]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let requestText = columnText(statement, 0),
                let requestID = UUID(uuidString: requestText),
                let payload = columnData(statement, 1),
                let model = try? JSONDecoder.iso.decode(ResponseModel.self, from: payload)
            else { continue }
            rows[requestID, default: []].append(
                PendingResponseRow(
                    timestamp: sqlite3_column_double(statement, 2),
                    rowid: sqlite3_column_int64(statement, 3),
                    model: model))
        }
        return rows.mapValues { rows in
            Array(
                rows
                    .sorted { ($0.timestamp, $0.rowid) > ($1.timestamp, $1.rowid) }
                    .prefix(max(0, limit))
                    .map(\.model))
        }
    }

    /// Mirror-syncs the response-history table by (request, response) row
    /// identity: requests and individual responses dropped by the in-memory
    /// caps are deleted, kept ones are upserted only when changed. Response
    /// identities are per-session, so the first save after a relaunch
    /// rewrites the touched requests' rows once.
    func saveResponseHistory(_ histories: [UUID: [ResponseModel]]) throws {
        guard let handle else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            let requestIDs = histories.keys.map(\.uuidString)
            if requestIDs.isEmpty {
                try exec("DELETE FROM response_history")
            } else {
                try run(
                    "DELETE FROM response_history WHERE request_id NOT IN (\(placeholders(requestIDs.count)))"
                ) { statement in
                    for (index, id) in requestIDs.enumerated() {
                        bindText(statement, Int32(index + 1), id)
                    }
                }
            }
            let now = Date().timeIntervalSince1970
            for (requestID, responses) in histories {
                let responseIDs = responses.map(\.id.uuidString)
                if responseIDs.isEmpty {
                    try run("DELETE FROM response_history WHERE request_id = ?") { statement in
                        bindText(statement, 1, requestID.uuidString)
                    }
                } else {
                    try run(
                        """
                        DELETE FROM response_history
                        WHERE request_id = ? AND response_id NOT IN (\(placeholders(responseIDs.count)))
                        """
                    ) { statement in
                        bindText(statement, 1, requestID.uuidString)
                        for (index, id) in responseIDs.enumerated() {
                            bindText(statement, Int32(index + 2), id)
                        }
                    }
                }
                for response in responses {
                    let payload = try JSONEncoder.iso.encode(response)
                    try run(
                        """
                        INSERT OR REPLACE INTO response_history
                            (request_id, response_id, timestamp, payload, saved_at)
                        VALUES (?, ?, ?, ?, ?)
                        """
                    ) { statement in
                        bindText(statement, 1, requestID.uuidString)
                        bindText(statement, 2, response.id.uuidString)
                        sqlite3_bind_double(statement, 3, response.timestamp.timeIntervalSince1970)
                        bindBlob(statement, 4, payload)
                        sqlite3_bind_double(statement, 5, now)
                    }
                }
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Drafts

    /// Loads every draft row, regrouped into the in-memory draft model. A
    /// payload that no longer decodes drops only its own entry - row-per-
    /// draft replaces the old `Lossy` map tolerance.
    func loadDrafts() throws -> VaultDrafts {
        guard let handle else { return VaultDrafts() }
        let sql = "SELECT kind, entity_id, payload FROM drafts"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        var drafts = VaultDrafts()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let kind = columnText(statement, 0),
                let entityID = columnText(statement, 1),
                let payload = columnData(statement, 2)
            else { continue }
            func decode<T: Decodable>(_ type: T.Type) -> T? {
                try? JSONDecoder.iso.decode(type, from: payload)
            }
            switch kind {
            case "request":
                if let request = decode(Request.self) { drafts.requests[entityID] = request }
            case "environment":
                if let environment = decode(EnvironmentProfile.self) {
                    drafts.environments[entityID] = environment
                }
            case "workspaceVariables":
                if let variables = decode([Variable].self) {
                    drafts.workspaceVariables[entityID] = variables
                }
            case "collectionVariables":
                if let variables = decode([Variable].self) {
                    drafts.collectionVariables[entityID] = variables
                }
            case "collectionAuthorizations":
                if let authorization = decode(Authorization.self) {
                    drafts.collectionAuthorizations[entityID] = authorization
                }
            case "folderAuthorizations":
                if let authorization = decode(Authorization.self) {
                    drafts.folderAuthorizations[entityID] = authorization
                }
            case "unfiledRequests":
                if let request = decode(Request.self) { drafts.unfiledRequests[entityID] = request }
            default:
                continue
            }
        }
        return drafts
    }

    /// Rewrites the drafts table to exactly the in-memory drafts (few rows,
    /// whole-table rewrite matches the old whole-file mirror semantics).
    /// Each draft value rides as its JSON payload, so model evolution costs
    /// one dropped row, not the store.
    func saveDrafts(_ drafts: VaultDrafts) throws {
        guard let handle else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM drafts")
            let sql = """
                INSERT INTO drafts (kind, entity_id, payload, saved_at) VALUES (?, ?, ?, ?)
                """
            let now = Date().timeIntervalSince1970
            func insert<T: Encodable>(_ kind: String, _ values: [String: T]) throws {
                for (entityID, value) in values {
                    let payload = try JSONEncoder.iso.encode(value)
                    try run(sql) { statement in
                        bindText(statement, 1, kind)
                        bindText(statement, 2, entityID)
                        bindBlob(statement, 3, payload)
                        sqlite3_bind_double(statement, 4, now)
                    }
                }
            }
            try insert("request", drafts.requests)
            try insert("environment", drafts.environments)
            try insert("workspaceVariables", drafts.workspaceVariables)
            try insert("collectionVariables", drafts.collectionVariables)
            try insert("collectionAuthorizations", drafts.collectionAuthorizations)
            try insert("folderAuthorizations", drafts.folderAuthorizations)
            try insert("unfiledRequests", drafts.unfiledRequests)
            try exec("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Cookies

    /// Loads every stored cookie, in insertion (name-sorted) order. Expired
    /// ones are swept by the caller on load and on write.
    func loadCookies() throws -> [StoredCookie] {
        guard let handle else { return [] }
        let sql = "SELECT name, domain, path, value, secure, http_only, expires FROM cookies"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        var cookies: [StoredCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            cookies.append(
                StoredCookie(
                    name: columnText(statement, 0) ?? "",
                    value: columnText(statement, 3) ?? "",
                    domain: columnText(statement, 1) ?? "",
                    path: columnText(statement, 2) ?? "",
                    secure: sqlite3_column_int(statement, 4) != 0,
                    httpOnly: sqlite3_column_int(statement, 5) != 0,
                    expires: sqlite3_column_type(statement, 6) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))))
        }
        return cookies
    }

    /// Rewrites the cookie jar to exactly the in-memory list (a handful of
    /// small rows; the jar sweeps expired entries on every write).
    func saveCookies(_ cookies: [StoredCookie]) throws {
        guard let handle else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM cookies")
            let sql = """
                INSERT OR REPLACE INTO cookies
                    (name, domain, path, value, secure, http_only, expires, saved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            let now = Date().timeIntervalSince1970
            for cookie in cookies {
                try run(sql) { statement in
                    bindText(statement, 1, cookie.name)
                    bindText(statement, 2, cookie.domain)
                    bindText(statement, 3, cookie.path)
                    bindText(statement, 4, cookie.value)
                    sqlite3_bind_int(statement, 5, cookie.secure ? 1 : 0)
                    sqlite3_bind_int(statement, 6, cookie.httpOnly ? 1 : 0)
                    bindOptionalDouble(
                        statement, 7, cookie.expires?.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 8, now)
                }
            }
            try exec("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Vault deletion tombstones

    /// One deletion intent per vault-relative path (`collections/<id>.json`).
    /// Consumed by the next location-switch merge: a file absent from the
    /// active side but present on the dormant one is propagated as a
    /// deletion when the tombstone is newer than the dormant copy, and
    /// treated as a restore (then dropped) otherwise.
    func recordVaultDeletion(_ path: String) throws {
        guard let handle else { return }
        try run("INSERT OR REPLACE INTO vault_deletions (path, deleted_at) VALUES (?, ?)") { statement in
            bindText(statement, 1, path)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        }
    }

    func loadVaultDeletions() throws -> [String: Date] {
        guard let handle else { return [:] }
        let sql = "SELECT path, deleted_at FROM vault_deletions"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        var deletions: [String: Date] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = columnText(statement, 0) {
                deletions[path] = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            }
        }
        return deletions
    }

    /// Drops tombstones the merge consumed (deletion propagated, or the
    /// file turned out to be a restore).
    func removeVaultDeletions(_ paths: Set<String>) throws {
        guard let handle, !paths.isEmpty else { return }
        try run(
            "DELETE FROM vault_deletions WHERE path IN (\(placeholders(paths.count)))"
        ) { statement in
            for (index, path) in paths.sorted().enumerated() {
                bindText(statement, Int32(index + 1), path)
            }
        }
    }

    // MARK: - SQLite plumbing

    private func exec(_ sql: String) throws {
        guard let handle else {
            throw Failure(code: SQLITE_MISUSE, message: "local store is not open")
        }
        var failure: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &failure) == SQLITE_OK else {
            let message = failure.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(failure)
            throw Failure(code: sqlite3_extended_errcode(handle), message: message)
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, Self.transient)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text { bindText(statement, index, text) } else { sqlite3_bind_null(statement, index) }
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func bindOptionalDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    /// Copies `data` into the bound BLOB (SQLITE_TRANSIENT), or NULL for nil.
    private func bindOptionalBlob(_ statement: OpaquePointer?, _ index: Int32, _ data: Data?) {
        if let data { bindBlob(statement, index, data) } else { sqlite3_bind_null(statement, index) }
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(data.count), Self.transient)
        }
    }

    /// Encodes `value` and binds it as a BLOB (JSON payload rows).
    private func bindJSON<T: Encodable>(_ value: T, into statement: OpaquePointer?, _ index: Int32) throws {
        bindBlob(statement, index, try JSONEncoder.iso.encode(value))
    }

    /// Prepares, binds, and steps one statement that produces no rows.
    private func run(_ sql: String, bind: (OpaquePointer?) throws -> Void) throws {
        guard let handle else {
            throw Failure(code: SQLITE_MISUSE, message: "local store is not open")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        do {
            try bind(statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw Failure(code: sqlite3_extended_errcode(handle), message: lastErrorMessage())
            }
        } catch {
            sqlite3_reset(statement)
            throw error
        }
    }

    /// `?, ?, ...` - as many placeholders as the NOT IN (...) clause needs.
    private func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: max(0, count)).joined(separator: ", ")
    }

    /// `sqlite3_column_text` hands back an unsigned char pointer; Swift's
    /// `String(cString:)` wants `CChar`, so rebind through a raw pointer.
    /// Nil (SQL NULL) maps to nil.
    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }

    private func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }

    /// Decodes a JSON BLOB column; nil when the column is NULL or the payload
    /// no longer decodes (the caller skips the row).
    private func columnJSON<T: Decodable>(_ type: T.Type, _ statement: OpaquePointer?, _ index: Int32) -> T? {
        guard let data = columnData(statement, index) else { return nil }
        return try? JSONDecoder.iso.decode(type, from: data)
    }

    private func lastErrorMessage() -> String {
        guard let handle else { return "local store is not open" }
        return String(cString: sqlite3_errmsg(handle))
    }
}
