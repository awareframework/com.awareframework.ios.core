//
//  AwareHubTests.swift
//  com.awareframework.ios.core.Tests
//
//  AWARE Hub: the upload requests (URL with the study, JSON body compressed with deflate).
//

import XCTest
import Foundation
import GRDB
@testable import com_awareframework_ios_core

final class AwareHubTests: XCTestCase {

    private let host = "https://Hub.Example.org/"
    private let table = "hub_test"
    private var path = ""

    override func setUp() {
        super.setUp()
        path = "hub_test_\(UUID().uuidString)"
    }

    override func tearDown() {
        DbSyncUtils.clearLastUploadedId(for: table)
        SyncBatchLimit.reset()
        super.tearDown()
    }

    private func makeHelper(serverType: ServerType) throws -> DbSyncHelper {
        let config = Engine.EngineConfig()
        config.path = path
        config.tableName = table
        let engine = SQLiteEngine(config)
        let queue = try XCTUnwrap(engine.getSQLiteInstance())
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE \(table) (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER, label TEXT, x REAL)")
            for i in 0..<300 {
                try db.execute(sql: "INSERT INTO \(table) (timestamp, label, x) VALUES (?, ?, ?)",
                               arguments: [1_700_000_000_000 + i, "C:\\temp\\new, \"q\" +1 日本 \(i)", Double(i) / 7])
            }
        }
        let sync = DbSyncConfig()
        sync.serverType = serverType
        sync.studyNumber = 7
        sync.studyKey = "key 7"
        return DbSyncHelper(engine: engine, host: host, tableName: table, config: sync)
    }

    func testHubRequestIsCompressedJSON() throws {
        let helper = try makeHelper(serverType: .aware_hub)
        let body = try XCTUnwrap(helper.previewRequests(batches: 1).first?.body)
        let request = try XCTUnwrap(helper.buildHTTPRequest(with: body))

        XCTAssertEqual(request.url?.absoluteString.lowercased(), "https://hub.example.org/v1/7/key%207/insert")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "deflate")
        let sent = try XCTUnwrap(request.httpBody)
        XCTAssertLessThan(sent.count, body.count / 3)
        let restored = try (sent as NSData).decompressed(using: .zlib) as Data
        XCTAssertEqual(restored, body)

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        XCTAssertEqual(envelope["tableName"] as? String, table)
        XCTAssertEqual(envelope["deviceId"] as? String, AwareUtils.getCommonDeviceId())
        let rows = try XCTUnwrap(envelope["data"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 300)
        XCTAssertEqual(rows[5]["label"] as? String, "C:\\temp\\new, \"q\" +1 日本 5")

        // For a check against the server (tests of AWARE Hub post it with Content-Encoding: deflate)
        if let dir = ProcessInfo.processInfo.environment["AWARE_DUMP_DIR"] {
            try sent.write(to: URL(fileURLWithPath: dir).appendingPathComponent("hub-request.deflate"))
            try restored.write(to: URL(fileURLWithPath: dir).appendingPathComponent("hub-request.json"))
        }
    }

    func testOtherServersUnchanged() throws {
        let helper = try makeHelper(serverType: .aware)
        let body = Data("device_id=a&data=%5B%5D".utf8)
        let request = try XCTUnwrap(helper.buildHTTPRequest(with: body))
        XCTAssertNil(request.value(forHTTPHeaderField: "Content-Encoding"))
        XCTAssertEqual(request.httpBody, body)
        XCTAssertTrue(request.url?.path.hasPrefix("/index.php/webservice/index/7/") ?? false)
    }

    func testDeflateOfEmptyBody() {
        XCTAssertNil(DbSyncHelper.deflate(Data()))
    }

    func testServerTypeFromConfig() {
        XCTAssertEqual(DbSyncConfig(["serverType": 5]).serverType, .aware_hub)
        let sensor = SensorConfig()
        sensor.set(config: ["serverType": 5])
        XCTAssertEqual(sensor.serverType, .aware_hub)
    }
}
