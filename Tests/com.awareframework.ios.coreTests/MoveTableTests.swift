//
//  MoveTableTests.swift
//  com.awareframework.ios.core.Tests
//
//  SQLiteEngine.moveTable(_:fromDatabaseAt:): rows not uploaded yet move to the new database file,
//  in order and once; uploaded rows and the old table do not stay behind.
//

import XCTest
import GRDB
@testable import com_awareframework_ios_core

final class MoveTableTests: XCTestCase {

    private let table = "move_table_test"
    private var oldPath = ""
    private var newPath = ""

    override func setUp() {
        super.setUp()
        oldPath = "move_old_\(UUID().uuidString)"
        newPath = "move_new_\(UUID().uuidString)"
    }

    override func tearDown() {
        for path in [oldPath, newPath] {
            UserDefaults.standard.removeObject(
                forKey: DbSyncUtils.databaseKey(for: table, database: SQLiteEngine.sqliteFileName(for: path)))
        }
        UserDefaults.standard.removeObject(forKey: DbSyncUtils.legacyKey(for: table))
        super.tearDown()
    }

    private func engine(_ path: String, rows: Int = 0, extraColumn: Bool = false) throws -> SQLiteEngine {
        let config = Engine.EngineConfig()
        config.path = path
        config.tableName = table
        let engine = SQLiteEngine(config)
        let queue = try XCTUnwrap(engine.getSQLiteInstance())
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS \(table) (id INTEGER PRIMARY KEY AUTOINCREMENT,
                  timestamp INTEGER NOT NULL, deviceId TEXT NOT NULL, x REAL\(extraColumn ? ", extra TEXT" : ""))
                """)
            for i in 0..<rows {
                try db.execute(sql: "INSERT INTO \(table) (timestamp, deviceId, x) VALUES (?, 'dev', ?)",
                               arguments: [1_000 + i, Double(i) / 3])
            }
        }
        return engine
    }

    private func setMarker(_ value: Int64, path: String) {
        DbSyncUtils.setLastUploadedId(
            value, forKey: DbSyncUtils.databaseKey(for: table, database: SQLiteEngine.sqliteFileName(for: path)))
    }

    private func timestamps(_ engine: SQLiteEngine) -> [Int64] {
        (engine.fetch(filter: nil, limit: nil) ?? []).compactMap { $0["timestamp"] as? Int64 }
    }

    func testMovesOnlyRowsNotUploadedAndDropsTheOldTable() throws {
        _ = try engine(oldPath, rows: 10)
        setMarker(4, path: oldPath)                        // rows 1...4 were uploaded
        let new = try engine(newPath, extraColumn: true)    // the new table may have more columns

        XCTAssertEqual(new.moveTable(table, fromDatabaseAt: oldPath), 6)
        XCTAssertEqual(timestamps(new), (1_004..<1_010).map(Int64.init), "rows 5...10, in order")
        let xs = (new.fetch(filter: nil, limit: nil) ?? []).compactMap { $0["x"] as? Double }
        XCTAssertEqual(xs.first, 4.0 / 3, "values unchanged")

        let old = try XCTUnwrap(SQLiteEngine({ let c = Engine.EngineConfig(); c.path = oldPath; return c }())
            .getSQLiteInstance())
        // Asked from SQLite itself: GRDB's tableExists() caches the schema per connection, and the
        // table was dropped through another connection
        let left = try old.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                             arguments: [table]) ?? -1
        }
        XCTAssertEqual(left, 0, "old table dropped")
        XCTAssertNil(UserDefaults.standard.object(
            forKey: DbSyncUtils.databaseKey(for: table, database: SQLiteEngine.sqliteFileName(for: oldPath))),
            "old marker removed")
        XCTAssertEqual(new.moveTable(table, fromDatabaseAt: oldPath), 0, "nothing left to move")
    }

    func testRowsAreAddedAfterRowsAlreadyThere() throws {
        _ = try engine(oldPath, rows: 3)
        let new = try engine(newPath, rows: 2)
        setMarker(2, path: newPath)                         // the new table's rows were uploaded
        XCTAssertEqual(new.moveTable(table, fromDatabaseAt: oldPath), 3)
        let ids = (new.fetch(filter: "id > 2", limit: nil) ?? []).compactMap { $0["id"] as? Int64 }
        XCTAssertEqual(ids, [3, 4, 5], "moved rows come after the new marker, so the next sync sends them")
    }

    /// A marker from 1.6.1 or earlier (table name only) belongs to the old database. If the new
    /// database took it over, it would skip the moved rows, which get new IDs from 1.
    func testOldStyleMarkerDoesNotSkipMovedRows() throws {
        _ = try engine(oldPath, rows: 10)
        UserDefaults.standard.set(3, forKey: DbSyncUtils.legacyKey(for: table))
        let new = try engine(newPath)
        XCTAssertEqual(new.moveTable(table, fromDatabaseAt: oldPath), 7, "rows 4...10")
        let key = DbSyncUtils.markerKey(for: table, database: new.databaseIdentifier,
                                        maxAssignedId: new.maxAssignedId(tableName: table))
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: key), 0, "every moved row is uploaded")
        XCTAssertNil(UserDefaults.standard.object(forKey: DbSyncUtils.legacyKey(for: table)))
    }

    func testNothingToMove() throws {
        let new = try engine(newPath)
        XCTAssertEqual(new.moveTable(table, fromDatabaseAt: "missing_\(UUID().uuidString)"), 0, "no old file")
        _ = try engine(oldPath)
        let other = try XCTUnwrap(SQLiteEngine({ let c = Engine.EngineConfig(); c.path = oldPath; return c }())
            .getSQLiteInstance())
        try other.write { try $0.execute(sql: "DROP TABLE \(table)") }
        XCTAssertEqual(new.moveTable(table, fromDatabaseAt: oldPath), 0, "no old table")
        XCTAssertEqual(new.moveTable(table, fromDatabaseAt: newPath), 0, "same database")
    }
}
