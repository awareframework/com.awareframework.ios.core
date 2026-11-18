//
//  DbSyncMarkerTests.swift
//  com.awareframework.ios.core.Tests
//
//  Each table of each database has its own sync marker ("<prefix>.<table>:<database>").
//  A marker from 1.6.1 and earlier ("<prefix>.<table>") is moved into it on the first sync.
//

import XCTest
import GRDB
@testable import com_awareframework_ios_core

class DbSyncMarkerTests: XCTestCase {

    let table = "marker_test_table"
    let prefix = "aware.sync.task.last_uploaded_id"
    var legacy: String { "\(prefix).\(table)" }
    func key(_ database: String) -> String { "\(prefix).\(table):\(database)" }
    var defaults: UserDefaults { .standard }

    override func setUp() {
        super.setUp()
        clearAll()
    }

    override func tearDown() {
        clearAll()
        super.tearDown()
    }

    private func clearAll() {
        for k in defaults.dictionaryRepresentation().keys where k.contains(table) {
            defaults.removeObject(forKey: k)
        }
    }

    // MARK: - New installs

    func testFirstSyncCreatesDatabaseMarker() {
        let k = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: 0)
        XCTAssertEqual(k, key("a.sqlite"))
        XCTAssertEqual(defaults.object(forKey: k) as? Int, 0)
        XCTAssertNil(defaults.object(forKey: legacy))
    }

    func testExistingDatabaseMarkerIsUsed() {
        defaults.set(42, forKey: key("a.sqlite"))
        let k = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: 100)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: k), 42)
    }

    // MARK: - Moving a marker from 1.6.1 and earlier

    func testOldMarkerIsMovedAndDeleted() {
        // An app released with 1.6.1: marker 50, rows up to 80.
        defaults.set(50, forKey: legacy)
        let k = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: 80)
        XCTAssertEqual(k, key("a.sqlite"))
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: k), 50)
        XCTAssertNil(defaults.object(forKey: legacy), "the old key is deleted after the move")
    }

    func testOldMarkerEqualToLastIdIsMoved() {
        defaults.set(80, forKey: legacy)
        let k = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: 80)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: k), 80)
    }

    func testOldMarkerIsMovedWhenLastIdIsUnknown() {
        defaults.set(50, forKey: legacy)
        let k = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: nil)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: k), 50)
        XCTAssertNil(defaults.object(forKey: legacy))
    }

    func testOldMarkerIsTakenOverOnlyOnce() {
        defaults.set(50, forKey: legacy)
        let a = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: 80)
        let b = DbSyncUtils.markerKey(for: table, database: "b.sqlite", maxAssignedId: 80)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: a), 50)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: b), 0, "the second database starts from 0")
    }

    func testOldMarkerLargerThanDatabaseIsLeftForItsOwner() {
        // dbPath was renamed: the new database's rows start from 1, the old marker says 5000.
        defaults.set(5000, forKey: legacy)
        let renamed = DbSyncUtils.markerKey(for: table, database: "renamed.sqlite", maxAssignedId: 3)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: renamed), 0)
        XCTAssertEqual(defaults.integer(forKey: legacy), 5000, "the old marker is kept")

        // The database it belongs to can still take it over.
        let original = DbSyncUtils.markerKey(for: table, database: "original.sqlite", maxAssignedId: 6000)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: original), 5000)
        XCTAssertNil(defaults.object(forKey: legacy))
    }

    func testDatabaseMarkerWinsOverOldMarker() {
        // The database moved its marker earlier; an old key written later (for example by an older
        // app version installed for testing) is not read again by this database.
        defaults.set(70, forKey: key("a.sqlite"))
        defaults.set(10, forKey: legacy)
        let k = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: 80)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: k), 70)
    }

    // MARK: - Progress and reset

    func testDatabasesProgressIndependently() {
        let a = DbSyncUtils.markerKey(for: table, database: "a.sqlite", maxAssignedId: 0)
        let b = DbSyncUtils.markerKey(for: table, database: "b.sqlite", maxAssignedId: 0)
        DbSyncUtils.setLastUploadedId(30, forKey: a)
        DbSyncUtils.setLastUploadedId(7, forKey: b)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: a), 30)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: b), 7)
    }

    func testRecreatedDatabaseResetsMarker() {
        // The database file was deleted and created again: rows start from 1, the marker says 500.
        defaults.set(500, forKey: key("a.sqlite"))
        XCTAssertEqual(DbSyncUtils.validatedLastUploadedId(forKey: key("a.sqlite"), maxAssignedId: 10), 0)
        XCTAssertEqual(defaults.integer(forKey: key("a.sqlite")), 0)
    }

    func testValidMarkerIsKept() {
        defaults.set(50, forKey: key("a.sqlite"))
        XCTAssertEqual(DbSyncUtils.validatedLastUploadedId(forKey: key("a.sqlite"), maxAssignedId: 80), 50)
        XCTAssertEqual(DbSyncUtils.validatedLastUploadedId(forKey: key("a.sqlite"), maxAssignedId: nil), 50)
    }

    func testClearRemovesOldAndDatabaseMarkers() {
        defaults.set(5, forKey: legacy)
        _ = DbSyncUtils.markerKey(for: table, database: "renamed.sqlite", maxAssignedId: 1)
        _ = DbSyncUtils.markerKey(for: table, database: "b.sqlite", maxAssignedId: 1)
        DbSyncUtils.clearLastUploadedId(for: table)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.contains(table) }.isEmpty)
    }

    // MARK: - SQLite engine

    private func makeEngine(_ path: String) -> SQLiteEngine {
        let config = Engine.EngineConfig()
        config.path = path
        config.tableName = table
        return SQLiteEngine(config)
    }

    func testDatabaseIdentifierIgnoresExtension() {
        XCTAssertEqual(makeEngine("marker_id_test").databaseIdentifier, "marker_id_test.sqlite")
        XCTAssertEqual(makeEngine("marker_id_test.sqlite").databaseIdentifier, "marker_id_test.sqlite")
    }

    func testMaxAssignedIdSurvivesDeletion() throws {
        let engine = makeEngine("marker_max_\(UUID().uuidString)")
        let queue = try XCTUnwrap(engine.getSQLiteInstance())
        XCTAssertEqual(engine.maxAssignedId(tableName: table), 0, "no table yet")
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE \(table) (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)")
        }
        XCTAssertEqual(engine.maxAssignedId(tableName: table), 0, "table without rows")
        try queue.write { db in
            for v in 1...5 { try db.execute(sql: "INSERT INTO \(table) (v) VALUES (?)", arguments: [v]) }
            try db.execute(sql: "DELETE FROM \(table)")
        }
        XCTAssertEqual(engine.maxAssignedId(tableName: table), 5, "deleted rows still count")
    }
}
