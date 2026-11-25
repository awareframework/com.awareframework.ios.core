import Foundation
import GRDB
import GRDBSQLite

private final class SQLiteSyncStopNotificationObserver: NSObject, @unchecked Sendable {
    static let shared = SQLiteSyncStopNotificationObserver()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStopRequest(_:)),
            name: Notification.Name.Aware.dbSyncStopRequest,
            object: nil
        )
    }

    @objc private func handleStopRequest(_ notification: Notification) {
        let requestID = notification.object as? UUID
        SQLiteEngine.stopAllSyncs {
            NotificationCenter.default.post(
                name: Notification.Name.Aware.dbSyncStopCompletion,
                object: requestID
            )
        }
    }
}

open class SQLiteEngine: Engine {

    var syncHelper: DbSyncHelper?
    private static var databaseQueues: [String: DatabaseQueue] = [:]
    private static let databaseQueuesLock = NSLock()
    private static let retryLimit = 5
    private static let sqliteExtension = ".sqlite"

    public override init(_ config: EngineConfig) {
        super.init(config)
        _ = SQLiteSyncStopNotificationObserver.shared
        guard let path = config.path else {
            print("[Error][SQLiteEngine] database path is nil.")
            return
        }
        let fileURL = Self.fileURL(for: path)
        do {
            _ = try Self.databaseQueue(for: fileURL.path)
        } catch {
            print("[Error][SQLiteEngine] Failed to open database: \(error)")
        }
    }

    // MARK: - Database access

    public var sqliteFileName: String? {
        config.path.map(Self.sqliteFileName(for:))
    }

    public var sqliteFileURL: URL? {
        config.path.map(Self.fileURL(for:))
    }

    public static func sqliteFileName(for path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem: String
        if trimmed.lowercased().hasSuffix(sqliteExtension) {
            stem = String(trimmed.dropLast(sqliteExtension.count))
        } else {
            stem = trimmed
        }
        return "\(stem.isEmpty ? "aware" : stem)\(sqliteExtension)"
    }

    public static func csvFileNameStem(databasePath: String, tableName: String) -> String {
        let databaseStem: String
        let trimmedDatabasePath = databasePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDatabasePath.lowercased().hasSuffix(sqliteExtension) {
            databaseStem = String(trimmedDatabasePath.dropLast(sqliteExtension.count))
        } else {
            databaseStem = trimmedDatabasePath
        }
        return "\(databaseStem.isEmpty ? "aware" : databaseStem)__\(tableName)"
    }

    public func csvFileNameStem(for tableName: String) -> String {
        Self.csvFileNameStem(databasePath: config.path ?? "aware", tableName: tableName)
    }

    /// The database file name (for example `aware_battery.sqlite`), so that `aware_battery`
    /// and `aware_battery.sqlite` identify the same database.
    open override var databaseIdentifier: String {
        Self.sqliteFileName(for: config.path ?? "aware")
    }

    /// The largest row ID ever assigned in the table. Tables use AUTOINCREMENT, so SQLite keeps this
    /// in `sqlite_sequence` even after rows are deleted. Returns 0 for a table that never had a row,
    /// and `nil` when the database cannot be read.
    open override func maxAssignedId(tableName: String) -> Int64? {
        guard let queue = getSQLiteInstance() else { return nil }
        return try? queue.read { db -> Int64 in
            if try db.tableExists("sqlite_sequence"),
               let seq = try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = ?",
                                            arguments: [tableName]) {
                return seq
            }
            // A table without AUTOINCREMENT, or one that never had a row
            guard try db.tableExists(tableName) else { return 0 }
            return try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM \(tableName)") ?? 0
        }
    }

    public func getSQLiteInstance() -> DatabaseQueue? {
        guard let path = config.path else { return nil }
        do {
            return try Self.databaseQueue(for: Self.fileURL(for: path).path)
        } catch {
            print("[Error][SQLiteEngine] \(error)")
            return nil
        }
    }

    private static func databaseQueue(for path: String) throws -> DatabaseQueue {
        databaseQueuesLock.lock()
        defer { databaseQueuesLock.unlock() }

        if let queue = databaseQueues[path] {
            return queue
        }

        var configuration = Configuration()
        configuration.busyMode = .timeout(10)
        configuration.journalMode = .wal
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        try createParentDirectory(ofDatabaseAt: path)
        let queue = try retryLockedDatabaseWork {
            try DatabaseQueue(path: path, configuration: configuration)
        }
        try retryLockedDatabaseWork {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
        }
        databaseQueues[path] = queue
        return queue
    }

    private static func retryLockedDatabaseWork<T>(_ work: () throws -> T) throws -> T {
        var lastError: Error?
        for attempt in 0..<retryLimit {
            do {
                return try work()
            } catch {
                lastError = error
                guard isDatabaseLocked(error), attempt < retryLimit - 1 else {
                    throw error
                }
                Thread.sleep(forTimeInterval: retryDelay(for: attempt))
            }
        }
        throw lastError
            ?? NSError(domain: "SQLiteEngine", code: Int(ResultCode.SQLITE_BUSY.rawValue))
    }

    private static func isDatabaseLocked(_ error: Error) -> Bool {
        guard let databaseError = error as? DatabaseError else {
            return false
        }
        return databaseError.resultCode.primaryResultCode == .SQLITE_BUSY
    }

    private static func retryDelay(for attempt: Int) -> TimeInterval {
        0.05 * Double(attempt + 1)
    }

    /// Creates the directory that will hold the database file, if it is missing. SQLite does not create
    /// directories, so opening the database fails without it. The Documents directory exists in an app,
    /// but not, for example, when Swift package tests run on the iOS Simulator without a host app.
    static func createParentDirectory(ofDatabaseAt path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func fileURL(for path: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(sqliteFileName(for: path))
    }

    // MARK: - Save

    open override func save(_ data: [any BaseDbModelSQLite], completion: ((Error?) -> Void)?) {
        do {
            guard let url = sqliteFileURL else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "SQLite database path is not configured."
                ])
            }
            let queue = try Self.databaseQueue(for: url.path)
            try Self.retryLockedDatabaseWork {
                try queue.write { db in
                    try db.execute(sql: "PRAGMA busy_timeout = 10000")
                    try db.execute(sql: "PRAGMA foreign_keys = ON")
                    for record in data {
                        try record.insert(db)
                    }
                }
            }
            completion?(nil)
        } catch {
            print("[Error][SQLiteEngine] save failed: \(error)")
            completion?(error)
        }
    }

    // MARK: - Count

    public override func count(filter: String?) -> Int {
        guard let tableName = config.tableName,
            let db = getSQLiteInstance()
        else { return 0 }
        do {
            let sql =
                filter.map { "SELECT count(*) as count FROM \(tableName) WHERE \($0)" }
                ?? "SELECT count(*) as count FROM \(tableName)"
            return try Self.retryLockedDatabaseWork {
                try db.read { db in
                    let row = try Row.fetchOne(db, sql: sql)
                    return (row?["count"] as? Int64).map(Int.init) ?? 0
                }
            }
        } catch {
            print("[Error][SQLiteEngine] count failed: \(error)")
            return 0
        }
    }

    // MARK: - Fetch

    public override func fetch(filter: String? = nil, limit: Int? = nil) -> [[String: Any]]? {
        guard let tableName = config.tableName,
            let db = getSQLiteInstance()
        else { return nil }
        do {
            var sql = "SELECT * FROM \(tableName)"
            if let f = filter { sql += " WHERE \(f)" }
            if !Self.containsOrderBy(filter) { sql += " ORDER BY rowid" }
            if let l = limit { sql += " LIMIT \(l)" }
            return try Self.retryLockedDatabaseWork {
                try db.read { db in
                    let cursor = try Row.fetchCursor(db, sql: sql)
                    var results: [[String: Any]] = []
                    while let row = try cursor.next() {
                        var dict: [String: Any] = [:]
                        for column in row.columnNames { dict[column] = row[column] }
                        results.append(dict)
                    }
                    return results
                }
            }
        } catch {
            print("[Error][SQLiteEngine] fetch failed: \(error)")
            return nil
        }
    }

    /// Upload rows written as JSON straight from the SQLite values, without a dictionary per row.
    /// See `Engine.fetchUploadJSON(afterId:limit:omitting:)`.
    public override func fetchUploadJSON(afterId: Int64, limit: Int, omitting: Set<String>) -> [UploadRowJSON]? {
        var buffer: [UInt8] = []
        guard let spans = appendUploadJSON(afterId: afterId, limit: limit, omitting: omitting, to: &buffer) else {
            return nil
        }
        return spans.map { span in
            UploadRowJSON(id: span.id, json: span.range.map { String(decoding: buffer[$0], as: UTF8.self) })
        }
    }

    /// See `Engine.appendUploadJSON(afterId:limit:omitting:to:)`. The values are read with the SQLite
    /// C API and written as JSON bytes: the column keys are made once per query, numbers are written
    /// without making strings, and a text column that repeats the previous row's value (device ID,
    /// OS, time zone...) reuses its JSON.
    public override func appendUploadJSON(afterId: Int64, limit: Int, omitting: Set<String>,
                                          to out: inout [UInt8]) -> [UploadRowSpan]? {
        guard let tableName = config.tableName,
            let db = getSQLiteInstance()
        else { return nil }
        let sql = "SELECT * FROM \(tableName) WHERE id > ? ORDER BY rowid LIMIT ?"
        var timing = UploadJSONTiming()
        let called = SyncClock.now()
        defer { lastUploadJSONTiming = timing }
        let rollback = out.count
        do {
            return try Self.retryLockedDatabaseWork {
                out.removeSubrange(rollback...)  // a retried attempt starts again
                return try db.read { db -> [UploadRowSpan]? in
                    let entered = SyncClock.now()
                    let cpuStart = SyncClock.threadCPU()
                    timing.queueWait = SyncClock.seconds(entered &- called)
                    var readNanos: UInt64 = 0
                    var encodeNanos: UInt64 = 0
                    defer {
                        timing.read = SyncClock.seconds(readNanos)
                        timing.encode = SyncClock.seconds(encodeNanos)
                        timing.cpu = SyncClock.seconds(SyncClock.threadCPU() &- cpuStart)
                    }
                    var t = SyncClock.now()
                    let statement = try db.makeStatement(sql: sql)
                    let stmt = statement.sqliteStatement
                    let columnCount = Int(sqlite3_column_count(stmt))
                    var keys: [[UInt8]] = []
                    var included: [Bool] = []
                    var idColumn: Int32?
                    for i in 0..<columnCount {
                        let name = sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? ""
                        keys.append(JSONBytes.key(name))
                        included.append(!omitting.contains(name))
                        if name == "id" { idColumn = Int32(i) }
                    }
                    // The previous row's text value and its JSON, per column. A column whose value
                    // changes twice in a row stops being cached.
                    var lastText = [[UInt8]](repeating: [], count: columnCount)
                    var lastJSON = [[UInt8]](repeating: [], count: columnCount)
                    var cacheMisses = [Int](repeating: 0, count: columnCount)
                    var spans: [UploadRowSpan] = []
                    spans.reserveCapacity(max(0, limit))
                    let cursor = try Row.fetchCursor(statement, arguments: [afterId, max(0, limit)])
                    while try cursor.next() != nil {
                        let stepped = SyncClock.now()
                        readNanos += stepped &- t
                        defer {
                            t = SyncClock.now()
                            encodeNanos += t &- stepped
                        }
                        // Rows without an integer id cannot be tracked by the sync marker
                        guard let idColumn, sqlite3_column_type(stmt, idColumn) == SQLITE_INTEGER else { return nil }
                        let rowId = sqlite3_column_int64(stmt, idColumn)
                        let start = out.count
                        var valid = true
                        var first = true
                        out.append(UInt8(ascii: "{"))
                        for i in 0..<columnCount where included[i] {
                            let column = Int32(i)
                            let type = sqlite3_column_type(stmt, column)
                            if type == SQLITE_NULL { continue }  // fetch(filter:limit:) leaves NULL columns out
                            if type == SQLITE_BLOB {
                                valid = false
                                break
                            }
                            if !first { out.append(UInt8(ascii: ",")) }
                            first = false
                            out.append(contentsOf: keys[i])
                            switch type {
                            case SQLITE_INTEGER:
                                JSONBytes.appendInt(sqlite3_column_int64(stmt, column), to: &out)
                            case SQLITE_FLOAT:
                                valid = JSONBytes.appendDouble(sqlite3_column_double(stmt, column), to: &out)
                            default:
                                Self.appendText(stmt, column: column, cacheIndex: i, to: &out, lastText: &lastText,
                                                lastJSON: &lastJSON, cacheMisses: &cacheMisses)
                            }
                            if !valid { break }
                        }
                        if valid {
                            out.append(UInt8(ascii: "}"))
                            spans.append(UploadRowSpan(id: rowId, range: start..<out.count))
                        } else {
                            out.removeSubrange(start...)
                            spans.append(UploadRowSpan(id: rowId, range: nil))
                            break
                        }
                    }
                    return spans
                }
            }
        } catch {
            print("[Error][SQLiteEngine] appendUploadJSON failed: \(error)")
            return nil
        }
    }

    /// A TEXT value as a JSON string. Like GRDB, the text ends at its first NUL byte, and invalid
    /// UTF-8 is repaired (U+FFFD).
    private static func appendText(_ stmt: SQLiteStatement, column: Int32, cacheIndex i: Int, to out: inout [UInt8],
                                   lastText: inout [[UInt8]], lastJSON: inout [[UInt8]], cacheMisses: inout [Int]) {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard let pointer = sqlite3_column_text(stmt, column) else {
            out.append(contentsOf: [UInt8(ascii: "\""), UInt8(ascii: "\"")])
            return
        }
        var bytes = UnsafeBufferPointer(start: pointer, count: count)
        if let nul = bytes.firstIndex(of: 0) { bytes = UnsafeBufferPointer(rebasing: bytes[0..<nul]) }
        let caching = cacheMisses[i] < 2
        if caching, bytes.elementsEqual(lastText[i]), lastJSON[i].isEmpty == false {
            out.append(contentsOf: lastJSON[i])
            cacheMisses[i] = 0
            return
        }
        let start = out.count
        if bytes.contains(where: { $0 >= 0x80 }) {
            JSONBytes.appendString(String(decoding: bytes, as: UTF8.self), to: &out)
        } else {
            JSONBytes.appendString(utf8: bytes, to: &out)
        }
        if caching {
            cacheMisses[i] += lastJSON[i].isEmpty ? 0 : 1
            lastText[i] = Array(bytes)
            lastJSON[i] = Array(out[start...])
        }
    }

    public override func fetch(
        filter: String? = nil, limit: Int? = nil,
        completion: (([[String: Any]]?, Error?) -> Void)?
    ) {
        completion?(fetch(filter: filter, limit: limit), nil)
    }

    /// Whether a `filter` already orders the rows (e.g. `"timestamp >= 0 ORDER BY timestamp DESC"`).
    ///
    /// Without its own `ORDER BY`, `fetch` returns rows in row ID order (`ORDER BY rowid`; `id` is the
    /// rowid). SQL does not define the order of rows without `ORDER BY`. The sync reads
    /// `id > lastUploadedId` with `LIMIT batchSize` and moves its marker, and deletes rows, up to the
    /// last row it read, so it needs the batch to be the lowest IDs in order: in any other order,
    /// rows that were not uploaded would be skipped or deleted. A range search on the rowid already
    /// returns rows in that order, so `ORDER BY rowid` adds no sort.
    static func containsOrderBy(_ filter: String?) -> Bool {
        guard let filter else { return false }
        return filter.range(of: #"\border\s+by\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Remove

    open override func removeAll(completion: ((Error?) -> Void)?) {
        guard let tableName = config.tableName else { return }
        do {
            guard let queue = getSQLiteInstance() else {
                completion?(nil)
                return
            }
            try Self.retryLockedDatabaseWork {
                try queue.write { db in
                    try db.execute(sql: "PRAGMA busy_timeout = 10000")
                    try db.execute(sql: "DELETE FROM \(tableName)")
                }
            }
            completion?(nil)
        } catch {
            print("[Error][SQLiteEngine] removeAll failed: \(error)")
            completion?(error)
        }
    }

    open override func remove(
        filter: String? = nil, limit: Int? = nil, completion: ((Error?) -> Void)?
    ) {
        guard let tableName = config.tableName else { return }
        do {
            guard let queue = getSQLiteInstance() else {
                completion?(nil)
                return
            }
            try Self.retryLockedDatabaseWork {
                try queue.write { db in
                    try db.execute(sql: "PRAGMA busy_timeout = 10000")
                    var sql = "DELETE FROM \(tableName)"
                    if let f = filter { sql += " WHERE \(f)" }
                    if let l = limit { sql += " LIMIT \(l)" }
                    try db.execute(sql: sql)
                }
            }
            completion?(nil)
        } catch {
            print("[Error][SQLiteEngine] remove failed: \(error)")
            completion?(error)
        }
    }

    /// Deletes uploaded rows in small transactions so that sensors can keep writing in between.
    /// Each chunk looks only at the `chunkSize` oldest uploaded rows, so it needs no index on
    /// `timestamp`. A row whose timestamp is newer than the cutoff stays and is checked again later.
    @discardableResult
    open override func removeUploaded(upToId: Int64, olderThan timestamp: Int64?, chunkSize: Int, maxChunks: Int) -> Int {
        guard let tableName = config.tableName, chunkSize > 0, maxChunks > 0,
              let queue = getSQLiteInstance() else { return 0 }
        var sql = "DELETE FROM \(tableName) WHERE id IN "
            + "(SELECT id FROM \(tableName) WHERE id <= ? ORDER BY id LIMIT ?)"
        var arguments: StatementArguments = [upToId, chunkSize]
        if let timestamp = timestamp {
            sql += " AND timestamp < ?"
            arguments += [timestamp]
        }
        var total = 0
        for _ in 0..<maxChunks {
            var deleted = 0
            do {
                try Self.retryLockedDatabaseWork {
                    try queue.write { db in
                        try db.execute(sql: "PRAGMA busy_timeout = 10000")
                        try db.execute(sql: sql, arguments: arguments)
                        deleted = db.changesCount
                    }
                }
            } catch {
                print("[Error][SQLiteEngine] removeUploaded failed: \(error)")
                break
            }
            total += deleted
            // A partial chunk means the oldest uploaded rows are not old enough yet (or none are left)
            if deleted < chunkSize { break }
        }
        return total
    }

    // MARK: - Sync

    /// The bodies of the next `batches` upload requests of this table, without sending anything or
    /// changing anything (see `DbSyncHelper.previewRequests(batches:)`). For checks.
    public func previewUploadRequests(config syncConfig: DbSyncConfig, batches: Int,
                                      host: String = "benchmark.invalid") -> [DbSyncHelper.PreviewRequest] {
        guard let tableName = config.tableName else { return [] }
        let helper = DbSyncHelper(engine: self, host: host, tableName: tableName, config: syncConfig)
        return helper.previewRequests(batches: batches)
    }

    /// Measure how long preparing upload requests of this table takes on this device, without
    /// sending anything or changing anything (see `DbSyncHelper.benchmarkPreparation(batches:)`).
    /// `host` only names the size limit to use: the default host has nothing learned, so the
    /// requests have the size of `config.maxBatchBytes` (or the default).
    public func benchmarkUploadPreparation(config syncConfig: DbSyncConfig, batches: Int,
                                           host: String = "benchmark.invalid") -> [SyncBatchMetrics] {
        guard let tableName = config.tableName else { return [] }
        let helper = DbSyncHelper(engine: self, host: host, tableName: tableName, config: syncConfig)
        return helper.benchmarkPreparation(batches: batches)
    }

    /// The upload of one table of one database. Shared by every engine of that table, so that two
    /// syncs of the same rows never run at the same time.
    final class SyncSlot {
        var helper: DbSyncHelper?
        var running = false
        /// A sync requested while another one was running: it runs once, after the current one
        var pendingConfig: DbSyncConfig?
        var pendingEngine: SQLiteEngine?
        var pendingCompletions: [DbSyncCompletionHandler] = []
    }

    private static var syncSlots: [String: SyncSlot] = [:]
    private static let syncSlotsLock = NSLock()
    private static var isStoppingAllSyncs = false
    private static var stopAllSyncCompletions: [() -> Void] = []

    /// A running sync with no activity for this long is treated as stopped (a request waits at most
    /// 300 s), and the next request starts a new sync instead of waiting for it.
    static let staleSyncInterval: TimeInterval = 330

    /**
     * Upload the rows of this engine's table.
     *
     * Only one sync of a database table runs at a time. When a sync is requested while another
     * one of the same table is running, the running sync is not stopped: stopping it would cancel
     * a request that the server may already have stored, so its rows would be sent again. Instead,
     * the request is remembered and one more sync runs after the current one finishes. Any number
     * of requests made during a sync lead to one more sync, and every completion handler is called
     * when that sync finishes.
     */
    open override func startSync(_ syncConfig: DbSyncConfig) {
        guard config.host != nil, let tableName = config.tableName else {
            print(
                "[Error][SQLiteEngine] host or tableName is nil. path=\(config.path ?? "nil"), host=\(config.host ?? "nil"), tableName=\(config.tableName ?? "nil")"
            )
            return
        }
        let slotKey = "\(databaseIdentifier):\(tableName)"
        Self.syncSlotsLock.lock()
        // A process-wide stop owns the current upload generation. Requests that race with it are
        // discarded just like helpers that were already queued, and a later request can start once
        // every cancellation has finished.
        guard Self.isStoppingAllSyncs == false else {
            Self.syncSlotsLock.unlock()
            return
        }
        let slot = Self.syncSlots[slotKey] ?? SyncSlot()
        Self.syncSlots[slotKey] = slot
        if slot.running {
            let idle = Date().timeIntervalSince1970 - (slot.helper?.lastActivity ?? 0)
            if idle < Self.staleSyncInterval {
                slot.pendingConfig = syncConfig
                slot.pendingEngine = self
                if let completion = syncConfig.completionHandler {
                    slot.pendingCompletions.append(completion)
                }
                Self.syncSlotsLock.unlock()
                if syncConfig.debug {
                    print("[AWARE::Core] A sync of \(slotKey) is running; one more sync runs after it")
                }
                return
            }
            print("[AWARE::Core] The sync of \(slotKey) has not responded for \(Int(idle)) s; starting a new sync")
            slot.helper?.cancel()
            slot.helper = nil
        }
        slot.running = true
        Self.syncSlotsLock.unlock()
        launchSync(slot, syncConfig, completions: syncConfig.completionHandler.map { [$0] } ?? [])
    }

    private func launchSync(_ slot: SyncSlot, _ syncConfig: DbSyncConfig,
                            completions: [DbSyncCompletionHandler]) {
        guard let host = config.host, let tableName = config.tableName else { return }
        let helper = DbSyncHelper(engine: self, host: host, tableName: tableName, config: syncConfig)
        let slotKey = "\(databaseIdentifier):\(tableName)"
        Self.syncSlotsLock.lock()
        guard Self.syncSlots[slotKey] === slot, slot.running, slot.helper == nil else {
            Self.syncSlotsLock.unlock()
            return
        }
        slot.helper = helper
        Self.syncSlotsLock.unlock()
        syncHelper = helper
        let run = {
            helper.run { status, error in
                completions.forEach { $0(status, error) }
                Self.finishSync(slot, helper: helper)
            }
        }
        if let queue = syncConfig.dispatchQueue {
            queue.async { run() }
        } else {
            run()
        }
    }

    /// Called when a sync finishes: runs the remembered request, if any.
    private static func finishSync(_ slot: SyncSlot, helper: DbSyncHelper) {
        syncSlotsLock.lock()
        // A sync that was replaced after it stopped responding no longer owns the slot.
        guard slot.helper === helper else {
            syncSlotsLock.unlock()
            return
        }
        guard let next = slot.pendingConfig, let engine = slot.pendingEngine else {
            slot.running = false
            slot.helper = nil
            syncSlotsLock.unlock()
            return
        }
        let completions = slot.pendingCompletions
        slot.pendingConfig = nil
        slot.pendingEngine = nil
        slot.pendingCompletions = []
        slot.helper = nil
        syncSlotsLock.unlock()
        engine.launchSync(slot, next, completions: completions)
    }

    open override func stopSync() {
        guard let helper = syncHelper else { return }
        helper.cancel()
        if let tableName = config.tableName {
            Self.syncSlotsLock.lock()
            if let slot = Self.syncSlots["\(databaseIdentifier):\(tableName)"], slot.helper === helper {
                slot.running = false
                slot.helper = nil
                slot.pendingConfig = nil
                slot.pendingEngine = nil
                slot.pendingCompletions = []
            }
            Self.syncSlotsLock.unlock()
        }
    }

    /// Stops every SQLite upload currently running in this process and drops uploads queued behind
    /// them. This is used by clients that present one aggregate upload operation for many sensors.
    public static func stopAllSyncs(completion: (() -> Void)? = nil) {
        syncSlotsLock.lock()
        if let completion {
            stopAllSyncCompletions.append(completion)
        }
        if isStoppingAllSyncs {
            syncSlotsLock.unlock()
            return
        }
        isStoppingAllSyncs = true

        var helpers: [DbSyncHelper] = []
        var seenHelpers = Set<ObjectIdentifier>()
        for slot in syncSlots.values {
            if let helper = slot.helper {
                let identifier = ObjectIdentifier(helper)
                if seenHelpers.insert(identifier).inserted {
                    // Make cancellation visible while the slot lock still prevents a racing start.
                    helper.requestCancellation()
                    helpers.append(helper)
                }
            }
            slot.running = false
            slot.helper = nil
            slot.pendingConfig = nil
            slot.pendingEngine = nil
            slot.pendingCompletions = []
        }
        syncSlots.removeAll()
        syncSlotsLock.unlock()

        guard helpers.isEmpty == false else {
            DispatchQueue.main.async { finishStoppingAllSyncs() }
            return
        }

        let group = DispatchGroup()
        helpers.forEach { helper in
            group.enter()
            helper.cancel {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            finishStoppingAllSyncs()
        }
    }

    private static func finishStoppingAllSyncs() {
        syncSlotsLock.lock()
        isStoppingAllSyncs = false
        let completions = stopAllSyncCompletions
        stopAllSyncCompletions = []
        syncSlotsLock.unlock()
        completions.forEach { $0() }
    }

    open override func close() {}

    // MARK: - Schema utilities

    func getAllTableNames(in db: DatabaseQueue) throws -> [String] {
        try db.read { db in
            try String.fetchAll(
                db,
                sql: """
                        SELECT name FROM sqlite_master
                        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                        ORDER BY name
                    """)
        }
    }

    func hasTable(_ tableName: String, in db: DatabaseQueue) throws -> Bool {
        try getAllTableNames(in: db).contains(tableName)
    }

    // MARK: - Moving a table from another database file

    /**
     * Moves a table's rows that were not uploaded yet from the database at `oldPath` into this
     * engine's database, then drops the table in the old database.
     *
     * For a sensor whose default `dbPath` changed: without this, the rows still waiting in the old
     * file would never be uploaded. The table must already exist in this database. Rows keep their
     * order and get new IDs here, after any rows this table already has, so they are uploaded by the
     * next sync. Rows at or below the old database's sync marker were uploaded already and are not
     * moved; the old marker is removed.
     *
     * The copy and the drop are one transaction in this database. If the app stops between the
     * commit here and in the old file, the next call copies the rows again: the server may receive
     * them twice, but none is lost.
     *
     * - Parameters:
     *   - tableName: The table, with the same name in both databases.
     *   - oldPath: The old `dbPath` (for example `"aware"` for `aware.sqlite`).
     * - Returns: The number of rows moved (0 when the old file or table does not exist).
     */
    @discardableResult
    public func moveTable(_ tableName: String, fromDatabaseAt oldPath: String) -> Int {
        guard let path = config.path, let queue = getSQLiteInstance() else { return 0 }
        let oldURL = Self.fileURL(for: oldPath)
        guard Self.sqliteFileName(for: oldPath) != Self.sqliteFileName(for: path),
              FileManager.default.fileExists(atPath: oldURL.path) else { return 0 }

        let oldConfig = EngineConfig()
        oldConfig.path = oldPath
        oldConfig.tableName = tableName
        let old = SQLiteEngine(oldConfig)
        guard let oldQueue = old.getSQLiteInstance(),
              (try? hasTable(tableName, in: oldQueue)) == true else { return 0 }

        // The old database's marker first: it takes over a marker from 1.6.1 or earlier, so that
        // marker cannot be given to this database (whose new row IDs it does not describe)
        let oldMax = old.maxAssignedId(tableName: tableName)
        let oldKey = DbSyncUtils.markerKey(for: tableName, database: old.databaseIdentifier, maxAssignedId: oldMax)
        let uploaded = DbSyncUtils.validatedLastUploadedId(forKey: oldKey, maxAssignedId: oldMax)
        _ = DbSyncUtils.markerKey(for: tableName, database: databaseIdentifier,
                                  maxAssignedId: maxAssignedId(tableName: tableName))

        do {
            let moved = try Self.retryLockedDatabaseWork {
                try queue.writeWithoutTransaction { db -> Int in
                    try db.execute(sql: "PRAGMA busy_timeout = 10000")
                    try db.execute(sql: "ATTACH DATABASE ? AS moved_from", arguments: [oldURL.path])
                    defer { try? db.execute(sql: "DETACH DATABASE moved_from") }
                    var count = 0
                    try db.inTransaction {
                        let columns = { (schema: String) throws -> [String] in
                            try Row.fetchAll(db, sql: "PRAGMA \(schema).table_info(\(tableName))")
                                .compactMap { $0["name"] as? String }
                        }
                        let here = Set(try columns("main"))
                        let shared = try columns("moved_from").filter { $0 != "id" && here.contains($0) }
                        if !shared.isEmpty {
                            let list = shared.map { "\"\($0)\"" }.joined(separator: ", ")
                            try db.execute(
                                sql: "INSERT INTO main.\(tableName) (\(list)) SELECT \(list) FROM moved_from.\(tableName) WHERE id > ? ORDER BY id",
                                arguments: [uploaded])
                            count = db.changesCount
                        }
                        try db.execute(sql: "DROP TABLE moved_from.\(tableName)")
                        return .commit
                    }
                    return count
                }
            }
            UserDefaults.standard.removeObject(forKey: oldKey)
            print("[AWARE::Core] Moved \(moved) rows of \(tableName) from \(old.databaseIdentifier) to \(databaseIdentifier)")
            return moved
        } catch {
            print("[Error][SQLiteEngine] Moving \(tableName) from \(old.databaseIdentifier) failed: \(error)")
            return 0
        }
    }

    public func getAllTableNames() throws -> [String] {
        guard let db = getSQLiteInstance() else {
            return []
        }
        return try getAllTableNames(in: db)
    }

    public func fetchTableSchema(tableName: String) throws -> [SQLiteTableColumn] {
        guard let database = getSQLiteInstance() else {
            return []
        }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
            return rows.compactMap { row -> SQLiteTableColumn? in
                guard let name = row["name"] as? String,
                    let type = row["type"] as? String
                else {
                    return nil
                }
                return SQLiteTableColumn(name: name, type: type)
            }
        }
    }

    public func fetchTableRows(tableName: String) throws -> [[String: Any]] {
        guard let database = getSQLiteInstance() else {
            return []
        }
        return try database.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                .compactMap { $0["name"] as? String }
            let orderClause = columns.contains("id") ? " ORDER BY id ASC" : ""
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(tableName)\(orderClause)")
            return rows.map { row in
                var dict: [String: Any] = [:]
                for column in row.columnNames {
                    dict[column] = row[column]
                }
                return dict
            }
        }
    }

    public func fetchTableSnapshot(tableName: String) throws -> SQLiteTableSnapshot? {
        let rows = try fetchTableRows(tableName: tableName)
        guard rows.isEmpty == false else {
            return nil
        }
        return SQLiteTableSnapshot(
            tableName: tableName,
            exportFileNameStem: csvFileNameStem(for: tableName),
            schema: try fetchTableSchema(tableName: tableName),
            rows: rows
        )
    }

    public func fetchTableSnapshots(tableNames: [String]? = nil) throws -> [SQLiteTableSnapshot] {
        let targetTableNames = try tableNames ?? getAllTableNames()
        return try targetTableNames.compactMap { tableName in
            try fetchTableSnapshot(tableName: tableName)
        }
    }

    public func syncAllTablesToMySQL(
        config: MySQLDirectSyncConfig,
        tableNames: [String]? = nil,
        batchSize: Int = 100
    ) async throws -> MySQLDirectSyncResult {
        let tables = try fetchTableSnapshots(tableNames: tableNames)
        let client = MySQLDirectClient(config: config)
        try await client.connect()
        defer { client.disconnect() }
        return try await client.syncTables(tables, batchSize: batchSize)
    }
}
