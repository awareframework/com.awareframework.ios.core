//
//  DbSyncHelperTests.swift
//  com.awareframework.ios.core.Tests
//

import XCTest
import Foundation
@testable import com_awareframework_ios_core

// MARK: - Mock Classes

class MockEngine: Engine {
    var mockData: [[String: Any]] = []
    var countResult: Int = 0
    var removeCallCount: Int = 0

    init() {
        super.init(Engine.EngineConfig())
    }

    override func fetch(filter: String?, limit: Int?) -> [[String: Any]]? {
        var filteredData = mockData
        if let filter = filter, filter.contains("id >") {
            let regex = try! NSRegularExpression(pattern: "id\\s*>\\s*(\\d+)", options: [])
            let nsString = filter as NSString
            let matches = regex.matches(in: filter, options: [], range: NSMakeRange(0, nsString.length))
            if let match = matches.first {
                let range = match.range(at: 1)
                let idString = nsString.substring(with: range)
                if let id = Int64(idString) {
                    filteredData = mockData.filter { item in
                        (item["id"] as? Int64).map { $0 > id } ?? false
                    }
                }
            }
        }
        if let limit = limit {
            return Array(filteredData.prefix(limit))
        }
        return filteredData
    }

    override func count(filter: String?) -> Int {
        if let filter = filter, filter.contains("id >") {
            let regex = try! NSRegularExpression(pattern: "id\\s*>\\s*(\\d+)", options: [])
            let nsString = filter as NSString
            let matches = regex.matches(in: filter, options: [], range: NSMakeRange(0, nsString.length))
            if let match = matches.first {
                let range = match.range(at: 1)
                let idString = nsString.substring(with: range)
                if let id = Int64(idString) {
                    return mockData.filter { item in
                        (item["id"] as? Int64).map { $0 > id } ?? false
                    }.count
                }
            }
        }
        return countResult
    }

    override func remove(filter: String?, limit: Int?, completion: ((Error?) -> Void)?) {
        removeCallCount += 1
        if let filter = filter, filter.contains("id >") {
            let regex = try! NSRegularExpression(pattern: "id\\s*>\\s*(\\d+)", options: [])
            let nsString = filter as NSString
            let matches = regex.matches(in: filter, options: [], range: NSMakeRange(0, nsString.length))
            if let match = matches.first {
                let range = match.range(at: 1)
                let idString = nsString.substring(with: range)
                if let id = Int64(idString) {
                    let prefixLimit = limit ?? Int.max
                    let toRemove = mockData.filter { item in
                        (item["id"] as? Int64).map { $0 > id } ?? false
                    }.prefix(prefixLimit)
                    for item in toRemove {
                        if let idx = mockData.firstIndex(where: { dict in
                            if let a = dict["id"] as? Int64, let b = item["id"] as? Int64 { return a == b }
                            return false
                        }) {
                            mockData.remove(at: idx)
                        }
                    }
                }
            }
        }
        completion?(nil)
    }
}

// MARK: - Test Cases

class DbSyncHelperTests: XCTestCase {

    var syncHelper: DbSyncHelper!
    var mockEngine: MockEngine!
    var mockConfig: DbSyncConfig!

    override func setUp() {
        super.setUp()
        DbSyncUtils.clearLastUploadedId(for: "test_table")
        mockEngine = MockEngine()
        mockConfig = DbSyncConfig()
        mockConfig.test = true
        mockConfig.debug = true
        mockConfig.backgroundSession = false

        syncHelper = DbSyncHelper(
            engine: mockEngine,
            host: "https://test.example.com",
            tableName: "test_table",
            config: mockConfig
        )
    }

    override func tearDown() {
        syncHelper?.stop()
        syncHelper = nil
        mockEngine = nil
        mockConfig = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(syncHelper)
        XCTAssertEqual(syncHelper.host, "https://test.example.com")
        XCTAssertEqual(syncHelper.tableName, "test_table")
        XCTAssertEqual(syncHelper.lastUploadedId, 0)
    }

    // MARK: - Data Processing Tests

    func testGetUploadCandidatesWithData() {
        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1"],
            ["id": Int64(2), "data": "test2"],
            ["id": Int64(3), "data": "test3"]
        ]

        let candidates = syncHelper.getUploadCandidates(lastUploadedId: 0, limit: 2)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0]["id"] as? Int64, 1)
        XCTAssertEqual(candidates[1]["id"] as? Int64, 2)
    }

    func testGetUploadCandidatesWithFilter() {
        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1"],
            ["id": Int64(2), "data": "test2"],
            ["id": Int64(3), "data": "test3"]
        ]

        let candidates = syncHelper.getUploadCandidates(lastUploadedId: 1, limit: 5)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0]["id"] as? Int64, 2)
        XCTAssertEqual(candidates[1]["id"] as? Int64, 3)
    }

    func testGetUploadCandidatesEmpty() {
        mockEngine.mockData = []

        let candidates = syncHelper.getUploadCandidates(lastUploadedId: 0, limit: 10)

        XCTAssertEqual(candidates.count, 0)
    }

    // MARK: - Upload Tests

    func testUploadWithEmptyData() {
        let expectation = XCTestExpectation(description: "Upload completion with empty data")

        syncHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testUploadWithData() {
        let expectation = XCTestExpectation(description: "Upload completion with data")

        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1", "timestamp": Int64(Date().timeIntervalSince1970)],
            ["id": Int64(2), "data": "test2", "timestamp": Int64(Date().timeIntervalSince1970)]
        ]
        mockEngine.countResult = 2
        mockConfig.batchSize = 10

        syncHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testUploadBatchProcessing() {
        let expectation = XCTestExpectation(description: "Batch processing")

        mockEngine.mockData = Array(1...150).map { i in
            ["id": Int64(i), "data": "test\(i)", "timestamp": Int64(Date().timeIntervalSince1970)]
        }
        mockEngine.countResult = 150
        mockConfig.batchSize = 50

        var completionCallCount = 0
        syncHelper.run { success, error in
            completionCallCount += 1
            XCTAssertTrue(success)
            if completionCallCount == 1 {
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // MARK: - Progress Tests

    func testProgressCallback() {
        let expectation = XCTestExpectation(description: "Progress callback")
        var progressValues: [Double] = []

        mockConfig.progressHandler = { progress, error in
            progressValues.append(progress)
            if progress >= 1.0 {
                expectation.fulfill()
            }
        }

        mockEngine.mockData = []
        mockEngine.countResult = 0

        syncHelper.run { _, _ in }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertTrue(progressValues.contains(1.0))
    }

    // MARK: - Error Handling Tests

    func testMultipleConcurrentRuns() {
        let expectation = XCTestExpectation(description: "Concurrent runs handled")
        expectation.expectedFulfillmentCount = 2

        syncHelper.run { success, error in
            XCTAssertTrue(success)
            expectation.fulfill()
        }

        syncHelper.run { success, error in
            XCTAssertTrue(success)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    func testStopFunctionality() {
        let expectation = XCTestExpectation(description: "Stop functionality")

        mockEngine.mockData = Array(1...100).map { i in
            ["id": Int64(i), "data": "test\(i)"]
        }

        syncHelper.run { _, _ in }

        syncHelper.stop {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Data Removal Tests

    func testDataRemovalAfterSync() {
        let expectation = XCTestExpectation(description: "Data removal after sync")

        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1"]
        ]
        mockEngine.countResult = 1
        mockConfig.removeAfterSync = true

        syncHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertGreaterThan(self.mockEngine.removeCallCount, 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testNoDataRemovalWhenDisabled() {
        let expectation = XCTestExpectation(description: "No data removal when disabled")

        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1"]
        ]
        mockEngine.countResult = 1
        mockConfig.removeAfterSync = false

        syncHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertEqual(self.mockEngine.removeCallCount, 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - HTTP Request Handler Tests

    func testHTTPRequestBodyHandler() {
        let expectation = XCTestExpectation(description: "HTTP request body handler")

        var handlerCalled = false
        syncHelper.createHttpRequestBodyHandler = { requestBody in
            handlerCalled = true
            return requestBody + "&custom_param=test"
        }

        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1"]
        ]

        syncHelper.run { _, _ in
            XCTAssertTrue(handlerCalled)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testURLRequestHandler() {
        let expectation = XCTestExpectation(description: "URL request handler")

        var handlerCalled = false
        syncHelper.createURLRequestHandler = { request in
            handlerCalled = true
            var modifiedRequest = request
            modifiedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return modifiedRequest
        }

        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1"]
        ]

        syncHelper.run { _, _ in
            XCTAssertTrue(handlerCalled)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Compact Data Format Tests

    func testCompactDataFormat() {
        let expectation = XCTestExpectation(description: "Compact data format")

        mockConfig.compactDataFormat = true
        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1", "os": "iOS", "deviceId": "device1"],
            ["id": Int64(2), "data": "test2", "os": "iOS", "deviceId": "device1"]
        ]

        syncHelper.run { success, error in
            XCTAssertTrue(success)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }
}

// MARK: - DbSyncUtils Tests

class DbSyncUtilsTests: XCTestCase {

    let testTableName = "test_table"
    let testId: Int64 = 12345

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "aware.sync.task.last_uploaded_id.\(testTableName)")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "aware.sync.task.last_uploaded_id.\(testTableName)")
        super.tearDown()
    }

    func testSetAndGetLastUploadedId() {
        DbSyncUtils.setLastUploadedId(testId, for: testTableName)
        let retrievedId = DbSyncUtils.getLastUploadedId(for: testTableName)
        XCTAssertEqual(retrievedId, testId)
    }

    func testGetLastUploadedIdWithNoStoredValue() {
        let retrievedId = DbSyncUtils.getLastUploadedId(for: "non_existent_table")
        XCTAssertEqual(retrievedId, 0)
    }

    func testUpdateLastUploadedId() {
        DbSyncUtils.setLastUploadedId(100, for: testTableName)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(for: testTableName), 100)

        DbSyncUtils.setLastUploadedId(200, for: testTableName)
        XCTAssertEqual(DbSyncUtils.getLastUploadedId(for: testTableName), 200)
    }
}
