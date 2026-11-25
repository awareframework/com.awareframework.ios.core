//
//  UploadJSONTests.swift
//  com.awareframework.ios.core.Tests
//
//  Rows written as JSON straight from SQLite (Engine.fetchUploadJSON) carry the same values as the
//  rows fetch(filter:limit:) returns, and a sync with them sends every row once.
//

import XCTest
import Foundation
import GRDB
@testable import com_awareframework_ios_core

final class UploadJSONTests: XCTestCase {

    private let table = "upload_json_test"
    private var path = ""

    override func setUp() {
        super.setUp()
        path = "upload_json_\(UUID().uuidString)"
        DbSyncUtils.clearLastUploadedId(for: table)
        SyncBatchLimit.reset()
    }

    override func tearDown() {
        SyncBatchLimit.reset()
        DbSyncUtils.clearLastUploadedId(for: table)
        super.tearDown()
    }

    private func makeEngine(rows: [[DatabaseValueConvertible?]]) throws -> SQLiteEngine {
        let config = Engine.EngineConfig()
        config.path = path
        config.tableName = table
        let engine = SQLiteEngine(config)
        let queue = try XCTUnwrap(engine.getSQLiteInstance())
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE \(table) (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER,
                  deviceId TEXT, label TEXT, x REAL, y REAL, extra BLOB)
                """)
            for row in rows {
                try db.execute(sql: "INSERT INTO \(table) (timestamp, deviceId, label, x, y, extra) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: StatementArguments(row))
            }
        }
        return engine
    }

    private func object(_ json: String?) -> [String: Any]? {
        guard let json else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    /// Doubles compared bit for bit, other values by their JSON
    private func assertSameValues(_ a: [String: Any], _ b: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(a.keys), Set(b.keys), file: file, line: line)
        for (key, value) in a {
            let other = b[key]
            if let d = value as? Double, let e = (other as? NSNumber)?.doubleValue {
                XCTAssertEqual(d.bitPattern, e.bitPattern, "\(key): \(d) vs \(e)", file: file, line: line)
            } else {
                XCTAssertEqual("\(value)", "\(other ?? "nil")", key, file: file, line: line)
            }
        }
    }

    func testSameValuesAsFetch() throws {
        let tricky = "quote \" backslash \\ slash / newline \n tab \t ctrl \u{01} 日本語 😀"
        let engine = try makeEngine(rows: [
            [1_795_060_031_991, "dev", "", 0.1 + 0.2, -0.98765432, nil],
            [1_795_060_032_001, "dev", tricky, 1795060031991.123, 5.0, nil],
            [1_795_060_032_011, "dev", nil, 1e-300, 0.12345678901234567, nil],   // NULL label
            [Int64.max, "dev", "x", -0.0, 1e20, nil],
        ])
        let fetched = try XCTUnwrap(engine.fetch(filter: "id > 0", limit: 10))
        let encoded = try XCTUnwrap(engine.fetchUploadJSON(afterId: 0, limit: 10, omitting: []))
        XCTAssertEqual(encoded.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(fetched.count, encoded.count)
        for (row, enc) in zip(fetched, encoded) {
            let fromJSON = try XCTUnwrap(object(enc.json), enc.json ?? "nil")
            // What the old path sends: the fetched row through JSONSerialization
            let old = try XCTUnwrap(object(String(data: JSONSerialization.data(withJSONObject: row), encoding: .utf8)))
            assertSameValues(old, fromJSON)
        }
        XCTAssertNil(object(encoded[2].json)?["label"], "NULL columns are left out, as fetch does")
        XCTAssertEqual(object(encoded[1].json)?["label"] as? String, tricky)
    }

    func testOmittingAndLimit() throws {
        let engine = try makeEngine(rows: (1...5).map { [$0, "dev", "", 0.5, 0.25, nil] })
        let encoded = try XCTUnwrap(engine.fetchUploadJSON(afterId: 2, limit: 2, omitting: ["id"]))
        XCTAssertEqual(encoded.map(\.id), [3, 4], "ids after afterId, in order, at most limit")
        XCTAssertNil(object(encoded[0].json)?["id"])
    }

    func testRowsJSONCannotHoldAreMarked() throws {
        let engine = try makeEngine(rows: [
            [1, "dev", "", 0.5, 0.25, nil],
            [2, "dev", "", 0.5, 0.25, Data([0, 1, 2])],     // BLOB
            [3, "dev", "", 0.5, 0.25, nil],
        ])
        let encoded = try XCTUnwrap(engine.fetchUploadJSON(afterId: 0, limit: 10, omitting: []))
        XCTAssertNotNil(encoded[0].json)
        XCTAssertNil(encoded[1].json, "a BLOB cannot be written as JSON")
        XCTAssertEqual(encoded.count, 2, "reading stops at the row JSON cannot hold")
    }

    /// A sync over SQLite with the fast path sends every row once, the same values as the rows hold
    /// Sizes are measured 100 rows at a time on the fast path: requests still fill the limit and
    /// carry every row once, for JSON and for the URL-encoded form of the legacy AWARE server
    func testGroupedSizeCheckFillsTheLimit() throws {
        for server in [ServerType.aware_micro, .aware] {
            path = "upload_json_\(UUID().uuidString)"
            let engine = try makeEngine(rows: (1...3000).map { i in
                [1_795_060_031_991 + i * 10, "dev", "it's \"x\" \(i)", 0.0123456789 * Double(i % 97), -0.98765432, nil]
            })
            let config = DbSyncConfig()
            config.serverType = server
            config.maxBatchBytes = 40_000
            let metrics = engine.benchmarkUploadPreparation(config: config, batches: 1000)
            XCTAssertEqual(metrics.map(\.rows).reduce(0, +), 3000, "\(server): every row")
            for (i, m) in metrics.enumerated() {
                XCTAssertLessThanOrEqual(m.bodyBytes, 40_000, "\(server) request \(i)")
                if i < metrics.count - 1 {
                    XCTAssertGreaterThan(m.bodyBytes, 38_000, "\(server) request \(i) should be close to the limit")
                }
            }
            XCTAssertGreaterThan(metrics[0].phases.dbRead + metrics[0].phases.jsonEncode, 0)
        }
    }

    /// The benchmark sends nothing and changes nothing
    func testBenchmarkChangesNothing() throws {
        let engine = try makeEngine(rows: (1...500).map { i in [1_795_060_031_991 + i, "dev", "", 0.1, 0.2, nil] })
        let config = DbSyncConfig()
        config.maxBatchBytes = 10_000
        let key = DbSyncUtils.markerKey(for: table, database: engine.databaseIdentifier,
                                        maxAssignedId: engine.maxAssignedId(tableName: table))
        let before = DbSyncUtils.getLastUploadedId(forKey: key)
        let metrics = engine.benchmarkUploadPreparation(config: config, batches: 3)
        XCTAssertEqual(metrics.count, 3)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: key), before, "marker unchanged")
        XCTAssertEqual(engine.count(filter: nil), 500, "rows unchanged")
    }

    func testSyncSendsEveryRowOnce() throws {
        let engine = try makeEngine(rows: (1...3000).map { i in
            [1_795_060_031_991 + i * 10, "dev", "", 0.0123456789 * Double(i % 97), -0.98765432, nil]
        })
        let config = DbSyncConfig()
        config.test = true
        config.backgroundSession = false
        config.removeAfterSync = false
        config.serverType = .aware_micro
        config.maxBatchBytes = 40_000
        let helper = DbSyncHelper(engine: engine, host: "https://upload-json.example.com", tableName: table, config: config)
        var bodies: [Data] = []
        let lock = NSLock()
        helper.createURLRequestHandler = { request in
            lock.lock(); bodies.append(request.httpBody ?? Data()); lock.unlock()
            return request
        }
        let done = expectation(description: "sync done")
        helper.run { success, _ in
            XCTAssertTrue(success)
            done.fulfill()
        }
        wait(for: [done], timeout: 60)

        XCTAssertGreaterThan(bodies.count, 5)
        bodies.forEach { XCTAssertLessThanOrEqual($0.count, 40_000) }
        let rows = bodies.flatMap { body -> [[String: Any]] in
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            return object?["data"] as? [[String: Any]] ?? []
        }
        XCTAssertEqual(rows.compactMap { ($0["id"] as? NSNumber)?.int64Value }, (1...3000).map(Int64.init))
        // The numbers as sent, read with Double(String): JSONSerialization's parser can be off by an
        // ulp or two, while the text itself is exact
        let regex = try NSRegularExpression(pattern: #""x":([-0-9.eE+]+)"#)
        let sentX = bodies.flatMap { body -> [Double] in
            let text = String(decoding: body, as: UTF8.self)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).flatMap { Double(text[$0]) }
            }
        }
        let storedX = try XCTUnwrap(engine.fetch(filter: "id > 0", limit: nil)).compactMap { $0["x"] as? Double }
        XCTAssertEqual(sentX.count, 3000)
        XCTAssertEqual(sentX.map(\.bitPattern), storedX.map(\.bitPattern), "every number exactly as stored")
    }
}
