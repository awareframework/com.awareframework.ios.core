import XCTest
import GRDB
@testable import com_awareframework_ios_core

final class MySQLDirectSyncTests: XCTestCase {

    func testConfigRequiresHostDatabaseAndUsername() {
        XCTAssertFalse(MySQLDirectSyncConfig().isConfigured)
        XCTAssertFalse(MySQLDirectSyncConfig(host: "db.example.com", database: "aware", username: "").isConfigured)
        XCTAssertFalse(MySQLDirectSyncConfig(host: " ", database: "aware", username: "aware").isConfigured)
        XCTAssertTrue(MySQLDirectSyncConfig(host: "db.example.com", database: "aware", username: "aware").isConfigured)
    }

    func testCreateTableSQLMapsSQLiteTypesAndEscapesIdentifiers() {
        let sql = MySQLDirectSQLBuilder.buildCreateTable(
            tableName: "aware`events",
            schema: [
                SQLiteTableColumn(name: "id", type: "INTEGER"),
                SQLiteTableColumn(name: "timestamp", type: "INTEGER"),
                SQLiteTableColumn(name: "score", type: "REAL"),
                SQLiteTableColumn(name: "payload", type: "BLOB"),
                SQLiteTableColumn(name: "label`name", type: "TEXT")
            ]
        )

        XCTAssertEqual(
            sql,
            "CREATE TABLE IF NOT EXISTS `aware``events` (`id` BIGINT NOT NULL AUTO_INCREMENT, `timestamp` BIGINT, `score` DOUBLE, `payload` LONGBLOB, `label``name` LONGTEXT, PRIMARY KEY (`id`)) CHARACTER SET utf8mb4"
        )
    }

    func testCreateTableSQLMatchesAwareLightTableShape() {
        let schema = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
            SQLiteTableColumn(name: "deviceId", type: "TEXT"),
            SQLiteTableColumn(name: "timestamp", type: "INTEGER"),
            SQLiteTableColumn(name: "label", type: "TEXT"),
            SQLiteTableColumn(name: "moving", type: "BOOLEAN"),
            SQLiteTableColumn(name: "x", type: "DOUBLE")
        ]

        let sql = MySQLDirectSQLBuilder.buildCreateTable(
            tableName: "aware_light_motion",
            schema: schema
        )

        XCTAssertEqual(
            sql,
            "CREATE TABLE IF NOT EXISTS `aware_light_motion` (`id` BIGINT NOT NULL AUTO_INCREMENT, `deviceId` LONGTEXT, `timestamp` BIGINT, `label` LONGTEXT, `moving` TINYINT(1), `x` DOUBLE, PRIMARY KEY (`id`)) CHARACTER SET utf8mb4"
        )
        for column in schema.map(\.name) {
            XCTAssertTrue(sql.contains("`\(column)`"))
        }
        XCTAssertTrue(sql.contains("AUTO_INCREMENT"))
    }

    func testInsertSQLEscapesValuesPreservesColumnOrderAndOmitsLocalId() {
        let sql = MySQLDirectSQLBuilder.buildInsert(
            tableName: "aware_events",
            columns: ["id", "label", "note", "payload", "missing"],
            rows: [
                [
                    "id": Int64(1),
                    "label": "O'Reilly\\sensor",
                    "note": "line1\nline2\r\0\u{001A}",
                    "payload": Data([0x00, 0x0F, 0xA0])
                ],
                [
                    "id": Int64(2),
                    "label": NSNull(),
                    "note": "ok",
                    "payload": Data()
                ]
            ]
        )

        XCTAssertEqual(
            sql,
            "INSERT IGNORE INTO `aware_events` (`label`, `note`, `payload`, `missing`) VALUES ('O\\'Reilly\\\\sensor', 'line1\\nline2\\r\\0\\Z', 0x000fa0, NULL), (NULL, 'ok', 0x, NULL)"
        )
        XCTAssertFalse(sql.contains("`id`"))
    }

    func testFetchTableSnapshotContainsSchemaRowsAndExportStemForDirectUpload() throws {
        let databasePath = "mysql_direct_sync_tests_\(UUID().uuidString)"
        let tableName = "aware_mysql_direct_upload"
        let engine = try makeSQLiteEngine(databasePath: databasePath)
        let queue = try XCTUnwrap(engine.getSQLiteInstance())

        try queue.write { db in
            try db.create(table: tableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("timestamp", .integer).notNull()
                table.column("label", .text)
                table.column("score", .double)
            }
            try db.execute(
                sql: "INSERT INTO \(tableName) (timestamp, label, score) VALUES (?, ?, ?)",
                arguments: [1000, "baseline", 1.5]
            )
            try db.execute(
                sql: "INSERT INTO \(tableName) (timestamp, label, score) VALUES (?, ?, ?)",
                arguments: [1001, "followup", 2.25]
            )
        }

        let snapshot = try XCTUnwrap(engine.fetchTableSnapshot(tableName: tableName))

        XCTAssertEqual(snapshot.tableName, tableName)
        XCTAssertEqual(snapshot.exportFileNameStem, "\(databasePath)__\(tableName)")
        XCTAssertEqual(snapshot.schema.map(\.name), ["id", "timestamp", "label", "score"])
        XCTAssertEqual(snapshot.schema.map(\.type), ["INTEGER", "INTEGER", "TEXT", "DOUBLE"])
        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(snapshot.rows[0]["id"] as? Int64, 1)
        XCTAssertEqual(snapshot.rows[0]["label"] as? String, "baseline")
        XCTAssertEqual(snapshot.rows[1]["score"] as? Double, 2.25)
    }

    private func makeSQLiteEngine(databasePath: String) throws -> SQLiteEngine {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(SQLiteEngine.sqliteFileName(for: databasePath))
        try? FileManager.default.removeItem(at: url)

        let config = Engine.EngineConfig()
        config.type = .sqlite
        config.path = databasePath
        return SQLiteEngine(config)
    }
}
