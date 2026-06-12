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

    private func formItems(from request: URLRequest?) -> [String: String] {
        guard let body = request?.httpBody.flatMap({ String(data: $0, encoding: .utf8) }),
              let items = URLComponents(string: "?\(body)")?.queryItems else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

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

    func testAwareServerUploadBuildsInsertRequest() {
        let expectation = XCTestExpectation(description: "Aware Server upload request")
        let tableName = "aware_server_upload_request"
        DbSyncUtils.clearLastUploadedId(for: tableName)
        mockConfig.serverType = .aware_micro
        mockConfig.studyNumber = 1
        mockConfig.studyKey = "microStudyKey"

        let awareServerHelper = DbSyncHelper(
            engine: mockEngine,
            host: "https://aware-micro.example.com",
            tableName: tableName,
            config: mockConfig
        )

        var capturedRequest: URLRequest?
        var capturedBody: [String: Any] = [:]
        awareServerHelper.createURLRequestHandler = { request in
            capturedRequest = request
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return request
        }

        mockEngine.mockData = [
            [
                "id": Int64(1),
                "timestamp": Int64(1000),
                "x": 1.25,
                "y": -2.5,
                "z": 0.0
            ]
        ]
        mockEngine.countResult = 1

        awareServerHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            XCTAssertEqual(capturedRequest?.httpMethod, "POST")
            XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://aware-micro.example.com/api/1/microStudyKey/insert/")
            XCTAssertEqual(capturedRequest?.allowsCellularAccess, true)
            XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(capturedBody["deviceId"] as? String, AwareUtils.getCommonDeviceId())
            XCTAssertEqual(capturedBody["tableName"] as? String, tableName)
            XCTAssertNotNil(capturedBody["timestamp"])
            let data = capturedBody["data"] as? [[String: Any]]
            XCTAssertEqual(data?.count, 1)
            XCTAssertEqual(data?.first?["id"] as? Int64, 1)
            XCTAssertEqual(data?.first?["timestamp"] as? Int64, 1000)
            XCTAssertEqual(data?.first?["x"] as? Double, 1.25)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testAwareServerUploadSuccessUpdatesLastUploadedId() {
        let expectation = XCTestExpectation(description: "Aware Server upload success updates progress")
        let tableName = "aware_server_upload_success"
        DbSyncUtils.clearLastUploadedId(for: tableName)
        mockConfig.serverType = .aware_micro

        let awareServerHelper = DbSyncHelper(
            engine: mockEngine,
            host: "aware-micro.example.com",
            tableName: tableName,
            config: mockConfig
        )

        mockEngine.mockData = [
            ["id": Int64(10), "data": "first"],
            ["id": Int64(11), "data": "second"]
        ]
        mockEngine.countResult = 2

        awareServerHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            XCTAssertEqual(DbSyncUtils.getLastUploadedId(for: tableName), 11)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testAwareMicroUploadBuildsStudyScopedAPIRequest() {
        let expectation = XCTestExpectation(description: "AWARE Micro upload request")
        let tableName = "accelerometer"
        DbSyncUtils.clearLastUploadedId(for: tableName)
        mockConfig.serverType = .aware_micro
        mockConfig.studyNumber = 1
        mockConfig.studyKey = "hjkmKPb7nM"

        let awareMicroHelper = DbSyncHelper(
            engine: mockEngine,
            host: "https://mygps-375110.an.r.appspot.com",
            tableName: tableName,
            config: mockConfig
        )

        var capturedRequest: URLRequest?
        awareMicroHelper.createURLRequestHandler = { request in
            capturedRequest = request
            return request
        }

        mockEngine.mockData = [
            ["id": Int64(1), "deviceId": "device-a", "timestamp": Int64(1000), "x": 1.25]
        ]
        mockEngine.countResult = 1

        awareMicroHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            XCTAssertEqual(capturedRequest?.httpMethod, "POST")
            XCTAssertEqual(
                capturedRequest?.url?.absoluteString,
                "https://mygps-375110.an.r.appspot.com/api/1/hjkmKPb7nM/insert/"
            )
            XCTAssertEqual(
                capturedRequest?.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            let body = capturedRequest?.httpBody
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            XCTAssertEqual(body?["deviceId"] as? String, AwareUtils.getCommonDeviceId())
            XCTAssertEqual(body?["tableName"] as? String, tableName)
            let data = body?["data"] as? [[String: Any]]
            XCTAssertEqual(data?.first?["id"] as? Int64, 1)
            XCTAssertEqual(data?.first?["deviceId"] as? String, "device-a")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testLegacyAwareUploadBuildsWebserviceTableRequest() {
        let expectation = XCTestExpectation(description: "Legacy AWARE upload request")
        let tableName = "locations"
        DbSyncUtils.clearLastUploadedId(for: tableName)
        mockConfig.serverType = .aware
        mockConfig.studyNumber = 2
        mockConfig.studyKey = "M66yzLNZ3h"

        let legacyHelper = DbSyncHelper(
            engine: mockEngine,
            host: "https://legacy.example.com/index.php",
            tableName: tableName,
            config: mockConfig
        )

        var capturedRequest: URLRequest?
        legacyHelper.createURLRequestHandler = { request in
            capturedRequest = request
            return request
        }

        mockEngine.mockData = [
            ["id": Int64(1), "deviceId": "device-a", "timestamp": Int64(1000), "double_latitude": 35.0]
        ]
        mockEngine.countResult = 1

        legacyHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            XCTAssertEqual(capturedRequest?.httpMethod, "POST")
            XCTAssertEqual(
                capturedRequest?.url?.absoluteString,
                "https://legacy.example.com/index.php/webservice/index/2/M66yzLNZ3h/locations/insert"
            )
            XCTAssertEqual(
                capturedRequest?.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            let form = self.formItems(from: capturedRequest)
            XCTAssertEqual(form["device_id"], AwareUtils.getCommonDeviceId())
            XCTAssertNotNil(form["data"])
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testAwareLightUploadOmitsLocalIdFromPayload() {
        let expectation = XCTestExpectation(description: "Aware Light upload omits local ID")
        let tableName = "aware_light_upload_without_id"
        DbSyncUtils.clearLastUploadedId(for: tableName)
        mockConfig.serverType = .aware_light

        let awareLightHelper = DbSyncHelper(
            engine: mockEngine,
            host: "aware-light.example.com",
            tableName: tableName,
            config: mockConfig
        )

        var capturedBody: [String: Any] = [:]
        awareLightHelper.createURLRequestHandler = { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return request
        }

        mockEngine.mockData = [
            ["id": Int64(101), "deviceId": "device-a", "timestamp": Int64(1000), "x": 1.25]
        ]
        mockEngine.countResult = 1

        awareLightHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            let data = capturedBody["data"] as? [[String: Any]]
            XCTAssertEqual(data?.count, 1)
            XCTAssertNil(data?.first?["id"])
            XCTAssertEqual(data?.first?["deviceId"] as? String, "device-a")
            XCTAssertEqual(data?.first?["timestamp"] as? Int64, 1000)
            XCTAssertEqual(DbSyncUtils.getLastUploadedId(for: tableName), 101)
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
