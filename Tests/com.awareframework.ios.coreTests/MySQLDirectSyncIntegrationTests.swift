import XCTest
@testable import com_awareframework_ios_core

// Integration tests that require a running local MySQL instance.
// To run: set the AWARE_MYSQL_TEST_HOST env var (defaults to 127.0.0.1).
// Setup: brew install mysql && brew services start mysql
//        mysql -u root -e "CREATE DATABASE IF NOT EXISTS aware_test;"
//        mysql -u root -e "CREATE USER IF NOT EXISTS 'aware_test'@'localhost' IDENTIFIED WITH mysql_native_password BY 'aware_test';"
//        mysql -u root -e "GRANT ALL ON aware_test.* TO 'aware_test'@'localhost';"
final class MySQLDirectSyncIntegrationTests: XCTestCase {

    private var client: MySQLDirectClient!

    private var config: MySQLDirectSyncConfig {
        let host = ProcessInfo.processInfo.environment["AWARE_MYSQL_TEST_HOST"] ?? "127.0.0.1"
        return MySQLDirectSyncConfig(
            host: host,
            port: 3306,
            database: "aware_test",
            username: "aware_test",
            password: "aware_test"
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        client = MySQLDirectClient(config: config)
        try await client.connect()
    }

    override func tearDown() async throws {
        client.disconnect()
        client = nil
        try await super.tearDown()
    }

    func testConnectAndDisconnect() async throws {
        // setUp / tearDown already exercise connect/disconnect; reaching here means success.
    }

    func testSyncSingleTableCreatesTableAndInsertsRows() async throws {
        let tableName = "aware_mysql_integration_\(Int(Date().timeIntervalSince1970))"
        let schema: [SQLiteTableColumn] = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
            SQLiteTableColumn(name: "timestamp", type: "INTEGER"),
            SQLiteTableColumn(name: "label", type: "TEXT"),
            SQLiteTableColumn(name: "score", type: "REAL"),
        ]
        let rows: [[String: Any]] = [
            ["id": Int64(1), "timestamp": Int64(1_000_000), "label": "baseline", "score": 1.5],
            ["id": Int64(2), "timestamp": Int64(1_000_001), "label": "followup",  "score": 2.25],
        ]
        let snapshot = SQLiteTableSnapshot(tableName: tableName, schema: schema, rows: rows)

        let inserted = try await client.syncTable(snapshot)

        XCTAssertEqual(inserted, 2)
    }

    func testSyncTableWithSpecialCharactersInStrings() async throws {
        let tableName = "aware_mysql_escape_\(Int(Date().timeIntervalSince1970))"
        let schema: [SQLiteTableColumn] = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
            SQLiteTableColumn(name: "label", type: "TEXT"),
        ]
        let rows: [[String: Any]] = [
            ["id": Int64(1), "label": "O'Reilly\\sensor\nline2"],
        ]
        let snapshot = SQLiteTableSnapshot(tableName: tableName, schema: schema, rows: rows)

        let inserted = try await client.syncTable(snapshot)

        XCTAssertEqual(inserted, 1)
    }

    func testSyncTableWithNullValues() async throws {
        let tableName = "aware_mysql_null_\(Int(Date().timeIntervalSince1970))"
        let schema: [SQLiteTableColumn] = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
            SQLiteTableColumn(name: "label", type: "TEXT"),
        ]
        let rows: [[String: Any]] = [
            ["id": Int64(1), "label": NSNull()],
        ]
        let snapshot = SQLiteTableSnapshot(tableName: tableName, schema: schema, rows: rows)

        let inserted = try await client.syncTable(snapshot)

        XCTAssertEqual(inserted, 1)
    }

    func testSyncEmptyTableReturnsZero() async throws {
        let tableName = "aware_mysql_empty_\(Int(Date().timeIntervalSince1970))"
        let schema: [SQLiteTableColumn] = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
        ]
        let snapshot = SQLiteTableSnapshot(tableName: tableName, schema: schema, rows: [])

        let inserted = try await client.syncTable(snapshot)

        XCTAssertEqual(inserted, 0)
    }

    func testSyncMultipleTables() async throws {
        let ts = Int(Date().timeIntervalSince1970)
        let schema: [SQLiteTableColumn] = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
            SQLiteTableColumn(name: "value", type: "TEXT"),
        ]
        let tables = (1...3).map { i -> SQLiteTableSnapshot in
            SQLiteTableSnapshot(
                tableName: "aware_multi_\(ts)_\(i)",
                schema: schema,
                rows: [["id": Int64(1), "value": "t\(i)"]]
            )
        }

        let result = try await client.syncTables(tables)

        XCTAssertEqual(result.insertedRows, 3)
    }

    func testSyncInsertIgnoreIdempotency() async throws {
        // The `id` column is excluded from INSERT so MySQL auto-generates IDs, preventing
        // cross-device key collisions. As a result, re-syncing the same SQLite rows inserts
        // additional rows on the MySQL side (no duplicate-key guard on the local id value).
        let tableName = "aware_mysql_idempotent_\(Int(Date().timeIntervalSince1970))"
        let schema: [SQLiteTableColumn] = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
            SQLiteTableColumn(name: "label", type: "TEXT"),
        ]
        let rows: [[String: Any]] = [["id": Int64(1), "label": "first"]]
        let snapshot = SQLiteTableSnapshot(tableName: tableName, schema: schema, rows: rows)

        let first  = try await client.syncTable(snapshot)
        let second = try await client.syncTable(snapshot)

        XCTAssertEqual(first,  1)
        XCTAssertEqual(second, 1, "Re-sync inserts again because id is excluded from INSERT and AUTO_INCREMENT assigns new IDs")
    }

    func testSyncLargeBatch() async throws {
        let tableName = "aware_mysql_large_\(Int(Date().timeIntervalSince1970))"
        let schema: [SQLiteTableColumn] = [
            SQLiteTableColumn(name: "id", type: "INTEGER"),
            SQLiteTableColumn(name: "ts", type: "INTEGER"),
            SQLiteTableColumn(name: "val", type: "REAL"),
        ]
        let rows: [[String: Any]] = (1...500).map { i in
            ["id": Int64(i), "ts": Int64(i), "val": Double(i) * 0.1]
        }
        let snapshot = SQLiteTableSnapshot(tableName: tableName, schema: schema, rows: rows)

        let inserted = try await client.syncTable(snapshot, batchSize: 50)

        XCTAssertEqual(inserted, 500)
    }

    // MARK: - Accelerometer sensor tests

    // ios_accelerometer schema mirrors AccelerometerData in the accelerometer sensor package.
    private static let accelerometerSchema: [SQLiteTableColumn] = [
        SQLiteTableColumn(name: "id",          type: "INTEGER"),
        SQLiteTableColumn(name: "deviceId",    type: "TEXT"),
        SQLiteTableColumn(name: "timestamp",   type: "INTEGER"),
        SQLiteTableColumn(name: "label",       type: "TEXT"),
        SQLiteTableColumn(name: "x",           type: "DOUBLE"),
        SQLiteTableColumn(name: "y",           type: "DOUBLE"),
        SQLiteTableColumn(name: "z",           type: "DOUBLE"),
        SQLiteTableColumn(name: "os",          type: "TEXT"),
        SQLiteTableColumn(name: "timezone",    type: "INTEGER"),
        SQLiteTableColumn(name: "jsonVersion", type: "INTEGER"),
    ]

    private func makeAccelerometerRow(
        id: Int64, timestamp: Int64,
        x: Double, y: Double, z: Double,
        label: String = "", deviceId: String = "test-device-001"
    ) -> [String: Any] {
        [
            "id":          id,
            "deviceId":    deviceId,
            "timestamp":   timestamp,
            "label":       label,
            "x":           x,
            "y":           y,
            "z":           z,
            "os":          "iOS",
            "timezone":    Int64(9 * 3600),
            "jsonVersion": Int64(1),
        ]
    }

    func testAccelerometerStaticDevice() async throws {
        // Simulates a device lying flat on a table: gravity on z ≈ 1g, x/y ≈ 0.
        let tableName = "ios_accelerometer_static_\(Int(Date().timeIntervalSince1970))"
        let baseTs: Int64 = 1_750_000_000_000
        let rows: [[String: Any]] = (0..<10).map { i in
            makeAccelerometerRow(
                id: Int64(i + 1),
                timestamp: baseTs + Int64(i) * 100,
                x: Double.random(in: -0.02...0.02),
                y: Double.random(in: -0.02...0.02),
                z: Double.random(in:  0.98...1.02)
            )
        }
        let snapshot = SQLiteTableSnapshot(
            tableName: tableName,
            schema: Self.accelerometerSchema,
            rows: rows
        )

        let inserted = try await client.syncTable(snapshot)

        XCTAssertEqual(inserted, 10)
    }

    func testAccelerometerWalkingMotion() async throws {
        // Simulates walking: sinusoidal x/y sway, z oscillates around 1g at ~2Hz step cadence.
        let tableName = "ios_accelerometer_walking_\(Int(Date().timeIntervalSince1970))"
        let baseTs: Int64 = 1_750_000_000_000
        let sampleHz = 50
        let durationSec = 10
        let totalSamples = sampleHz * durationSec

        let rows: [[String: Any]] = (0..<totalSamples).map { i in
            let t = Double(i) / Double(sampleHz)
            let stepFreq = 2.0 * .pi * 1.8  // ~1.8 Hz cadence
            return makeAccelerometerRow(
                id: Int64(i + 1),
                timestamp: baseTs + Int64(i) * (1000 / Int64(sampleHz)),
                x: 0.3 * sin(stepFreq * t),
                y: 0.2 * cos(stepFreq * t * 0.5),
                z: 1.0 + 0.4 * sin(stepFreq * t + .pi / 4),
                label: "walking"
            )
        }
        let snapshot = SQLiteTableSnapshot(
            tableName: tableName,
            schema: Self.accelerometerSchema,
            rows: rows
        )

        let inserted = try await client.syncTable(snapshot, batchSize: 100)

        XCTAssertEqual(inserted, totalSamples)
    }

    func testAccelerometerMultipleDevices() async throws {
        // Simulates three devices uploading to the same table.
        let tableName = "ios_accelerometer_multidev_\(Int(Date().timeIntervalSince1970))"
        let baseTs: Int64 = 1_750_000_000_000
        let devices = ["device-A", "device-B", "device-C"]
        let rowsPerDevice = 20

        var allRows: [[String: Any]] = []
        for (d, deviceId) in devices.enumerated() {
            for i in 0..<rowsPerDevice {
                allRows.append(makeAccelerometerRow(
                    id: Int64(d * rowsPerDevice + i + 1),
                    timestamp: baseTs + Int64(i) * 200,
                    x: Double.random(in: -1...1),
                    y: Double.random(in: -1...1),
                    z: Double.random(in:  0...2),
                    deviceId: deviceId
                ))
            }
        }
        let snapshot = SQLiteTableSnapshot(
            tableName: tableName,
            schema: Self.accelerometerSchema,
            rows: allRows
        )

        let inserted = try await client.syncTable(snapshot)

        XCTAssertEqual(inserted, devices.count * rowsPerDevice)
    }

    func testAccelerometerSpecialLabelCharacters() async throws {
        // Labels can contain free-form strings entered by researchers (e.g. activity names).
        let tableName = "ios_accelerometer_labels_\(Int(Date().timeIntervalSince1970))"
        let baseTs: Int64 = 1_750_000_000_000
        let labels = ["sitting", "standing", "it's walking", "run\\sprint", "日本語ラベル", "label\nwith\nnewline"]
        let rows: [[String: Any]] = labels.enumerated().map { i, label in
            makeAccelerometerRow(
                id: Int64(i + 1),
                timestamp: baseTs + Int64(i) * 1000,
                x: 0, y: 0, z: 1,
                label: label
            )
        }
        let snapshot = SQLiteTableSnapshot(
            tableName: tableName,
            schema: Self.accelerometerSchema,
            rows: rows
        )

        let inserted = try await client.syncTable(snapshot)

        XCTAssertEqual(inserted, labels.count)
    }

    func testAccelerometerSchemaMatchesCreateTableSQL() {
        let sql = MySQLDirectSQLBuilder.buildCreateTable(
            tableName: "ios_accelerometer",
            schema: Self.accelerometerSchema
        )
        XCTAssertTrue(sql.contains("`id` BIGINT NOT NULL AUTO_INCREMENT"))
        XCTAssertTrue(sql.contains("`deviceId` LONGTEXT"))
        XCTAssertTrue(sql.contains("`timestamp` BIGINT"))
        XCTAssertTrue(sql.contains("`x` DOUBLE"))
        XCTAssertTrue(sql.contains("`y` DOUBLE"))
        XCTAssertTrue(sql.contains("`z` DOUBLE"))
        XCTAssertTrue(sql.contains("`os` LONGTEXT"))
        XCTAssertTrue(sql.contains("`timezone` BIGINT"))
        XCTAssertTrue(sql.contains("`jsonVersion` BIGINT"))
        XCTAssertTrue(sql.contains("CHARACTER SET utf8mb4"))
    }
}
