import Foundation
import GRDB

open class SQLiteEngine: Engine {

    var syncHelper: DbSyncHelper?
    private static var databaseQueues: [String: DatabaseQueue] = [:]
    private static let databaseQueuesLock = NSLock()
    private static let retryLimit = 5

    public override init(_ config: EngineConfig) {
        super.init(config)
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

    private static func fileURL(for path: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(path + ".sqlite")
    }

    // MARK: - Save

    open override func save(_ data: [any BaseDbModelSQLite], completion: ((Error?) -> Void)?) {
        do {
            guard let queue = getSQLiteInstance() else {
                completion?(nil)
                return
            }
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

    public override func fetch(
        filter: String? = nil, limit: Int? = nil,
        completion: (([[String: Any]]?, Error?) -> Void)?
    ) {
        completion?(fetch(filter: filter, limit: limit), nil)
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

    // MARK: - Sync

    open override func startSync(_ syncConfig: DbSyncConfig) {
        guard let host = config.host, let tableName = config.tableName else {
            print("[Error][SQLiteEngine] host or tableName is nil.")
            return
        }
        syncHelper?.stop()
        syncHelper = DbSyncHelper(
            engine: self, host: host, tableName: tableName, config: syncConfig)
        let run = { self.syncHelper?.run(completion: syncConfig.completionHandler) }
        if let queue = syncConfig.dispatchQueue {
            queue.async { run() }
        } else {
            run()
        }
    }

    open override func stopSync() {
        syncHelper?.stop()
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
}
