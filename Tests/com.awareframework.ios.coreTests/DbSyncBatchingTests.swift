//
//  DbSyncBatchingTests.swift
//  com.awareframework.ios.core.Tests
//
//  Requests sized by bytes (maxBatchBytes), the learned per-host limit, pacing between batches,
//  and sync work off the main thread.
//

import XCTest
import Foundation
@testable import com_awareframework_ios_core

/// MockEngine that records whether rows were read on the main thread
private final class ThreadRecordingEngine: MockEngine {
    var fetchesOnMain = 0
    var fetches = 0
    override func fetch(filter: String?, limit: Int?) -> [[String: Any]]? {
        fetches += 1
        if Thread.isMainThread { fetchesOnMain += 1 }
        return super.fetch(filter: filter, limit: limit)
    }
}

final class DbSyncBatchingTests: XCTestCase {

    private var engine: ThreadRecordingEngine!
    private var config: DbSyncConfig!
    private let table = "batching_test"
    private let host = "https://batching.example.com"

    override func setUp() {
        super.setUp()
        DbSyncUtils.clearLastUploadedId(for: table)
        SyncBatchLimit.reset()
        engine = ThreadRecordingEngine()
        config = DbSyncConfig()
        config.test = true
        config.backgroundSession = false
        config.removeAfterSync = false
    }

    override func tearDown() {
        SyncBatchLimit.reset()
        DbSyncUtils.clearLastUploadedId(for: table)
        super.tearDown()
    }

    /// Accelerometer-like rows of about 200 bytes of JSON each
    private func rows(_ n: Int) -> [[String: Any]] {
        (1...n).map { i in
            ["id": Int64(i), "timestamp": Int64(1_795_060_031_991 + i * 10),
             "deviceId": "E2F5B9CE-EB39-498A-BA44-C391175D313C", "label": "",
             "x": 0.0123456789 * Double(i % 97), "y": -0.98765432, "z": 0.00314159 * Double(i % 7)]
        }
    }

    /// Run a sync to the end and return the request bodies it sent
    private func sync(server: ServerType, compact: Bool = false, bodyHandler: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) -> (bodies: [Data], helper: DbSyncHelper) {
        config.serverType = server
        config.compactDataFormat = compact
        let helper = DbSyncHelper(engine: engine, host: host, tableName: table, config: config)
        var bodies: [Data] = []
        let lock = NSLock()
        helper.createURLRequestHandler = { request in
            lock.lock(); bodies.append(request.httpBody ?? Data()); lock.unlock()
            return request
        }
        if bodyHandler { helper.createHttpRequestBodyHandler = { $0 } }
        let done = expectation(description: "sync done")
        helper.run { success, _ in
            XCTAssertTrue(success, file: file, line: line)
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        return (bodies, helper)
    }

    private func jsonRows(_ body: Data) -> [[String: Any]] {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return object?["data"] as? [[String: Any]] ?? []
    }

    private func formRows(_ body: Data) -> [[String: Any]] {
        guard let text = String(data: body, encoding: .utf8),
              let data = URLComponents(string: "?" + text)?.queryItems?.first(where: { $0.name == "data" })?.value,
              let rows = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [[String: Any]] else { return [] }
        return rows
    }

    // MARK: - Size of requests

    func testJSONRequestsFillTheLimitAndSendEveryRowOnce() {
        engine.mockData = rows(3000)
        config.maxBatchBytes = 50_000
        config.batchSize = 500
        let (bodies, helper) = sync(server: .aware_micro)

        XCTAssertGreaterThan(bodies.count, 5)
        for (i, body) in bodies.enumerated() {
            XCTAssertLessThanOrEqual(body.count, 50_000, "request \(i)")
            if i < bodies.count - 1 {
                XCTAssertGreaterThan(body.count, 49_000, "request \(i) should be close to the limit")
            }
        }
        let ids = bodies.flatMap(jsonRows).compactMap { ($0["id"] as? NSNumber)?.int64Value }
        XCTAssertEqual(ids, (1...3000).map(Int64.init), "every row once, in order")
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(forKey: helper.markerKey), 3000)
        // The body has the same fields as before
        let first = try? JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
        XCTAssertEqual(first?["tableName"] as? String, table)
        XCTAssertEqual(first?["deviceId"] as? String, AwareUtils.getCommonDeviceId())
        XCTAssertNotNil(first?["timestamp"])
        XCTAssertEqual(engine.fetchesOnMain, 0, "rows are read off the main thread")
    }

    func testFormRequestsMeasureEncodedSize() {
        engine.mockData = rows(1500)
        config.maxBatchBytes = 30_000
        let (bodies, _) = sync(server: .aware)

        for (i, body) in bodies.enumerated() {
            XCTAssertLessThanOrEqual(body.count, 30_000, "request \(i)")
            if i < bodies.count - 1 {
                XCTAssertGreaterThan(body.count, 29_000, "request \(i) should be close to the limit")
            }
        }
        let ids = bodies.flatMap(formRows).compactMap { ($0["id"] as? NSNumber)?.int64Value }
        XCTAssertEqual(ids, (1...1500).map(Int64.init))
    }

    func testCompactFormatAndBodyHandlerStayWithinLimit() {
        engine.mockData = rows(2000)
        config.maxBatchBytes = 40_000
        let compact = sync(server: .aware_micro, compact: true).bodies
        XCTAssertGreaterThan(compact.count, 1)
        compact.forEach { XCTAssertLessThanOrEqual($0.count, 40_000) }

        DbSyncUtils.clearLastUploadedId(for: table)
        let handled = sync(server: .aware_micro, bodyHandler: true).bodies
        handled.forEach { XCTAssertLessThanOrEqual($0.count, 40_000) }
        XCTAssertEqual(handled.flatMap(jsonRows).count, 2000)
    }

    func testMaxBatchRowsCapsRequests() {
        engine.mockData = rows(250)
        config.maxBatchBytes = 10_000_000
        config.maxBatchRows = 100
        let (bodies, _) = sync(server: .aware_micro)
        XCTAssertEqual(bodies.map { jsonRows($0).count }, [100, 100, 50])
    }

    func testRowLargerThanLimitIsSentAlone() {
        var data = rows(3)
        data[1]["label"] = String(repeating: "x", count: 30_000)
        engine.mockData = data
        config.maxBatchBytes = 20_000
        let (bodies, _) = sync(server: .aware_micro)
        XCTAssertEqual(bodies.map { jsonRows($0).count }, [1, 1, 1], "the large row goes alone; the sync goes on")
    }

    func testDefaultLimitByServerType() {
        let micro = DbSyncConfig(); micro.serverType = .aware_micro
        let legacy = DbSyncConfig(); legacy.serverType = .aware
        XCTAssertEqual(SyncBatchLimit.configured(micro), 4_000_000)
        XCTAssertEqual(SyncBatchLimit.configured(legacy), 900_000)
        legacy.maxBatchBytes = 2_000_000
        XCTAssertEqual(SyncBatchLimit.configured(legacy), 2_000_000)
    }

    // MARK: - Learned limit

    func testTooLargeHalvesAndIsRemembered() {
        let c = DbSyncConfig(); c.serverType = .aware_micro
        XCTAssertEqual(SyncBatchLimit.current(host: "h1", config: c), 4_000_000)
        XCTAssertEqual(SyncBatchLimit.recordTooLarge(host: "h1", bodyBytes: 4_000_000), 2_000_000)
        SyncBatchLimit.recordTooLarge(host: "h1", bodyBytes: 2_000_000)
        XCTAssertEqual(SyncBatchLimit.current(host: "h1", config: c), 1_000_000, "4 MB -> 2 MB -> 1 MB")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: SyncBatchLimit.keyPrefix + "h1"), 1_000_000, "saved")
        XCTAssertEqual(SyncBatchLimit.current(host: "other", config: c), 4_000_000, "per host")
        // Successes do not raise a limit learned from 413
        for _ in 0..<100 { SyncBatchLimit.recordSuccess(host: "h1") }
        XCTAssertEqual(SyncBatchLimit.current(host: "h1", config: c), 1_000_000)
        SyncBatchLimit.recordTooLarge(host: "h1", bodyBytes: 10)
        XCTAssertEqual(SyncBatchLimit.current(host: "h1", config: c), SyncBatchLimit.minimumBytes, "never below the minimum")
    }

    func testTimeoutLimitGrowsBack() {
        let c = DbSyncConfig(); c.serverType = .aware_micro
        SyncBatchLimit.recordTimeout(host: "t", bodyBytes: 4_000_000)
        XCTAssertEqual(SyncBatchLimit.current(host: "t", config: c), 2_000_000)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: SyncBatchLimit.keyPrefix + "t"), 0, "not saved")
        for _ in 0..<SyncBatchLimit.growAfterSuccesses { SyncBatchLimit.recordSuccess(host: "t") }
        XCTAssertEqual(SyncBatchLimit.current(host: "t", config: c), 3_000_000)
        for _ in 0..<(SyncBatchLimit.growAfterSuccesses * 3) { SyncBatchLimit.recordSuccess(host: "t") }
        XCTAssertEqual(SyncBatchLimit.current(host: "t", config: c), 4_000_000, "not above the configured limit")
    }

    // MARK: - Pacing

    func testRestIsProportionalToWork() {
        let c = DbSyncConfig()
        XCTAssertEqual(SyncPacing.rest(workSeconds: 0.2, config: c, background: false, thermal: .nominal, lowPower: false), 0.2, accuracy: 1e-9)
        XCTAssertEqual(SyncPacing.rest(workSeconds: 0.2, config: c, background: true, thermal: .nominal, lowPower: false), 0.6, accuracy: 1e-9)
        XCTAssertEqual(SyncPacing.rest(workSeconds: 0.2, config: c, background: false, thermal: .nominal, lowPower: true), 0.4, accuracy: 1e-9)
        XCTAssertEqual(SyncPacing.rest(workSeconds: 0.2, config: c, background: false, thermal: .serious, lowPower: false), 5)
        XCTAssertEqual(SyncPacing.rest(workSeconds: 0.2, config: c, background: false, thermal: .critical, lowPower: false), 30)
        XCTAssertEqual(SyncPacing.rest(workSeconds: 1000, config: c, background: true, thermal: .nominal, lowPower: false), 120, "capped")
        c.batchInterval = 0.1
        XCTAssertEqual(SyncPacing.rest(workSeconds: 0.01, config: c, background: false, thermal: .nominal, lowPower: false), 0.1, accuracy: 1e-9,
                       "batchInterval is the shortest rest (1.6 behaviour)")
        c.cpuRestRatio = 0
        c.batchInterval = 0
        XCTAssertEqual(SyncPacing.rest(workSeconds: 0.5, config: c, background: false, thermal: .nominal, lowPower: false), 0)
    }

    func testDefaultsAndDictionary() {
        let c = DbSyncConfig()
        XCTAssertNil(c.maxBatchBytes)
        XCTAssertEqual(c.maxBatchRows, 20000)
        XCTAssertEqual(c.batchInterval, 0)
        XCTAssertEqual(c.cpuRestRatio, 1)
        XCTAssertEqual(c.backgroundCpuRestRatio, 3)
        let d = DbSyncConfig(["maxBatchBytes": 1234567, "maxBatchRows": 500, "batchInterval": 0.25,
                              "cpuRestRatio": 2.0, "backgroundCpuRestRatio": 4.0])
        XCTAssertEqual(d.maxBatchBytes, 1234567)
        XCTAssertEqual(d.maxBatchRows, 500)
        XCTAssertEqual(d.batchInterval, 0.25)
        XCTAssertEqual(d.cpuRestRatio, 2)
        XCTAssertEqual(d.backgroundCpuRestRatio, 4)
    }
}
