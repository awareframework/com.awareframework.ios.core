//
//  SQLiteEngineSyncSlotTests.swift
//  com.awareframework.ios.core.Tests
//
//  Only one sync of a database table runs at a time; requests made during a sync lead to one
//  more sync after it, instead of stopping it.
//

import XCTest
import GRDB
@testable import com_awareframework_ios_core

class SQLiteEngineSyncSlotTests: XCTestCase {

    let table = "slot_test_table"

    override func setUp() {
        super.setUp()
        DbSyncUtils.clearLastUploadedId(for: table)
    }

    override func tearDown() {
        DbSyncUtils.clearLastUploadedId(for: table)
        super.tearDown()
    }

    private func makeEngine(_ path: String, table: String? = nil) throws -> SQLiteEngine {
        let config = Engine.EngineConfig()
        config.path = path
        config.host = "localhost"
        config.tableName = table ?? self.table
        let engine = SQLiteEngine(config)
        let queue = try XCTUnwrap(engine.getSQLiteInstance())
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS \(config.tableName!) (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER, deviceId TEXT)
                """)
            for i in 1...3 {
                try db.execute(sql: "INSERT INTO \(config.tableName!) (timestamp, deviceId) VALUES (?, 'd')",
                               arguments: [i])
            }
        }
        return engine
    }

    /// A sync config that runs without network access, on the given queue
    private func syncConfig(_ queue: DispatchQueue, _ completion: @escaping DbSyncCompletionHandler) -> DbSyncConfig {
        let c = DbSyncConfig()
        c.test = true
        c.dispatchQueue = queue
        c.completionHandler = completion
        return c
    }

    func testRequestsDuringASyncRunOnceAfterIt() throws {
        let engine = try makeEngine("slot_\(UUID().uuidString)")
        let queue = DispatchQueue(label: "slot.test")
        queue.suspend()  // keep the first sync "running" until the other requests are made

        var order: [String] = []
        let lock = NSLock()
        let done = expectation(description: "all completions")
        done.expectedFulfillmentCount = 3
        func handler(_ name: String) -> DbSyncCompletionHandler {
            { status, _ in
                XCTAssertTrue(status)
                lock.lock(); order.append(name); lock.unlock()
                done.fulfill()
            }
        }
        engine.startSync(syncConfig(queue, handler("first")))
        let firstHelper = engine.syncHelper
        engine.startSync(syncConfig(queue, handler("second")))
        engine.startSync(syncConfig(queue, handler("third")))
        XCTAssertTrue(engine.syncHelper === firstHelper, "the running sync is not replaced")

        queue.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(order.first, "first")
        XCTAssertEqual(Set(order.dropFirst()), ["second", "third"])
        XCTAssertFalse(engine.syncHelper === firstHelper, "one more sync ran after the first")
    }

    func testEnginesOfTheSameTableShareTheSlot() throws {
        let path = "slot_shared_\(UUID().uuidString)"
        let a = try makeEngine(path)
        let b = try makeEngine(path)  // another engine of the same database table
        let queue = DispatchQueue(label: "slot.shared")
        queue.suspend()
        let done = expectation(description: "both completions")
        done.expectedFulfillmentCount = 2
        a.startSync(syncConfig(queue) { _, _ in done.fulfill() })
        b.startSync(syncConfig(queue) { _, _ in done.fulfill() })
        XCTAssertNil(b.syncHelper, "the second engine waits for the running sync")
        queue.resume()
        wait(for: [done], timeout: 10)
    }

    func testDifferentTablesDoNotWait() throws {
        let path = "slot_tables_\(UUID().uuidString)"
        let a = try makeEngine(path)
        let b = try makeEngine(path, table: "slot_test_table_other")
        defer { DbSyncUtils.clearLastUploadedId(for: "slot_test_table_other") }
        let queue = DispatchQueue(label: "slot.tables")
        queue.suspend()
        let done = expectation(description: "both completions")
        done.expectedFulfillmentCount = 2
        a.startSync(syncConfig(queue) { _, _ in done.fulfill() })
        b.startSync(syncConfig(queue) { _, _ in done.fulfill() })
        XCTAssertNotNil(b.syncHelper, "another table starts its own sync")
        queue.resume()
        wait(for: [done], timeout: 10)
    }

    func testStoppedSyncIsReplaced() throws {
        let engine = try makeEngine("slot_stale_\(UUID().uuidString)")
        let queue = DispatchQueue(label: "slot.stale")
        queue.suspend()
        engine.startSync(syncConfig(queue) { _, _ in })
        let stuck = try XCTUnwrap(engine.syncHelper)
        // No activity for longer than the limit: treated as stopped.
        stuck.lastActivity = Date().timeIntervalSince1970 - SQLiteEngine.staleSyncInterval - 1

        let done = expectation(description: "new sync completes")
        let other = DispatchQueue(label: "slot.stale.other")
        engine.startSync(syncConfig(other) { status, _ in
            XCTAssertTrue(status)
            done.fulfill()
        })
        XCTAssertFalse(engine.syncHelper === stuck, "a new sync replaces the stopped one")
        wait(for: [done], timeout: 10)
        queue.resume()
    }

    func testStopSyncFreesTheSlot() throws {
        let engine = try makeEngine("slot_stop_\(UUID().uuidString)")
        let queue = DispatchQueue(label: "slot.stop")
        queue.suspend()
        engine.startSync(syncConfig(queue) { _, _ in })
        engine.stopSync()
        let done = expectation(description: "sync after stop")
        engine.startSync(syncConfig(DispatchQueue(label: "slot.stop.other")) { _, _ in done.fulfill() })
        wait(for: [done], timeout: 10)
        queue.resume()
    }
}
