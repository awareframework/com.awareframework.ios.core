//
//  DbSyncHelperIntegrationTests.swift
//  com.awareframework.ios.core.Tests
//
//  Created by Test Suite on 2025/07/09.
//

import XCTest
import Foundation
@testable import com_awareframework_ios_core

// MARK: - Integration Tests

class DbSyncHelperIntegrationTests: XCTestCase {
    
    var syncHelper: DbSyncHelper!
    var mockEngine: MockEngine!
    var mockConfig: MockDbSyncConfig!
    
    override func setUp() {
        super.setUp()
        
        mockEngine = MockEngine()
        mockConfig = MockDbSyncConfig()
        mockConfig.test = true // Ensure test mode is enabled
        
        syncHelper = DbSyncHelper(
            engine: mockEngine,
            host: "https://api.test.com",
            tableName: "sensor_data",
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
    
    // MARK: - Real-world Scenario Tests
    
    func testLargeDatasetSync() {
        let expectation = XCTestExpectation(description: "Large dataset sync")
        
        // Create large dataset (1000 records)
        mockEngine.mockData = Array(1...1000).map { i in
            [
                "id": Int64(i),
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                "deviceId": "test-device",
                "sensorType": "accelerometer",
                "x": Double.random(in: -10...10),
                "y": Double.random(in: -10...10),
                "z": Double.random(in: -10...10),
                "accuracy": Int.random(in: 0...3)
            ]
        }
        
        mockEngine.countResult = 1000
        mockConfig.batchSize = 100
        
        var progressUpdates: [Double] = []
        mockConfig.progressHandler = { progress, error in
            progressUpdates.append(progress)
        }
        
        syncHelper.run { success, error in
            XCTAssertTrue(success)
            XCTAssertNil(error)
            XCTAssertGreaterThan(progressUpdates.count, 0)
            XCTAssertEqual(progressUpdates.last, 1.0)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 30.0)
    }
    
    func testIncrementalSync() {
        let expectation = XCTestExpectation(description: "Incremental sync")
        
        // Simulate that some data was already synced
        DbSyncUtils.setLastUploadedId(50, "sensor_data")
        
        // Create data with IDs 1-100
        mockEngine.mockData = Array(1...100).map { i in
            [
                "id": Int64(i),
                "data": "sensor_reading_\(i)",
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
            ]
        }
        
        // Only 50 records should be synced (51-100)
        mockEngine.countResult = 50
        mockConfig.batchSize = 25
        
        syncHelper.run { success, error in
            XCTAssertTrue(success)
            // Verify that the last uploaded ID was updated
            let lastId = DbSyncUtils.getLastUploadedId("sensor_data")
            XCTAssertEqual(lastId, 100)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    func testNetworkErrorRecovery() {
        let expectation = XCTestExpectation(description: "Network error recovery")
        
        mockEngine.mockData = [
            ["id": Int64(1), "data": "test1"],
            ["id": Int64(2), "data": "test2"]
        ]
        mockEngine.countResult = 2
        
        // First attempt should fail (simulate by not setting test mode)
        mockConfig.test = false
        
        var firstAttemptCompleted = false
        
        syncHelper.run { success, error in
            if !firstAttemptCompleted {
                firstAttemptCompleted = true
                XCTAssertFalse(success)
                
                // Simulate recovery by enabling test mode and retrying
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.mockConfig.test = true
                    self.syncHelper.run { success, error in
                        XCTAssertTrue(success)
                        expectation.fulfill()
                    }
                }
            }
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    func testConcurrentSyncAttempts() {
        let expectation = XCTestExpectation(description: "Concurrent sync attempts")
        expectation.expectedFulfillmentCount = 3
        
        mockEngine.mockData = Array(1...10).map { i in
            ["id": Int64(i), "data": "test\(i)"]
        }
        mockEngine.countResult = 10
        
        // Start multiple sync attempts simultaneously
        for i in 0..<3 {
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + Double(i) * 0.1) {
                self.syncHelper.run { success, error in
                    XCTAssertTrue(success)
                    expectation.fulfill()
                }
            }
        }
        
        wait(for: [expectation], timeout: 15.0)
    }
    
    func testMemoryManagement() {
        weak var weakSyncHelper: DbSyncHelper?
        
        autoreleasepool {
            let tempEngine = MockEngine()
            let tempConfig = MockDbSyncConfig()
            let tempSyncHelper = DbSyncHelper(
                engine: tempEngine,
                host: "https://test.com",
                tableName: "temp_table",
                config: tempConfig
            )
            
            weakSyncHelper = tempSyncHelper
            XCTAssertNotNil(weakSyncHelper)
        }
        
        // After autoreleasepool, object should be deallocated
        XCTAssertNil(weakSyncHelper)
    }
    
    // MARK: - Performance Tests
    
    func testPerformanceLargeDataset() {
        mockEngine.mockData = Array(1...10000).map { i in
            [
                "id": Int64(i),
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                "data": String(repeating: "x", count: 100) // 100 char string
            ]
        }
        
        measure {
            let candidates = syncHelper.getUploadCandidates(lastUploadedId: 0, limit: 1000)
            XCTAssertEqual(candidates.count, 1000)
        }
    }
    
    func testPerformanceJSONSerialization() {
        let data = Array(1...1000).map { i in
            [
                "id": Int64(i),
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                "x": Double.random(in: -10...10),
                "y": Double.random(in: -10...10),
                "z": Double.random(in: -10...10)
            ]
        }
        
        measure {
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
                let jsonString = String(data: jsonData, encoding: .utf8)
                XCTAssertNotNil(jsonString)
            } catch {
                XCTFail("JSON serialization failed: \(error)")
            }
        }
    }
    
    // MARK: - Edge Cases
    
    func testEmptyTableName() {
        let emptyTableHelper = DbSyncHelper(
            engine: mockEngine,
            host: "https://test.com",
            tableName: "",
            config: mockConfig
        )
        
        let expectation = XCTestExpectation(description: "Empty table name handling")
        
        emptyTableHelper.run { success, error in
            // Should handle gracefully
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testInvalidHost() {
        let invalidHostHelper = DbSyncHelper(
            engine: mockEngine,
            host: "invalid-url",
            tableName: "test",
            config: mockConfig
        )
        
        let expectation = XCTestExpectation(description: "Invalid host handling")
        
        mockEngine.mockData = [["id": Int64(1), "data": "test"]]
        mockConfig.test = false // Allow actual network request to fail
        
        invalidHostHelper.run { success, error in
            XCTAssertFalse(success)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    func testVeryLargeSingleRecord() {
        let expectation = XCTestExpectation(description: "Very large single record")
        
        // Create a record with large data
        let largeData = String(repeating: "x", count: 1024 * 1024) // 1MB string
        mockEngine.mockData = [
            [
                "id": Int64(1),
                "largeField": largeData,
                "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
            ]
        ]
        mockEngine.countResult = 1
        
        syncHelper.run { success, error in
            XCTAssertTrue(success)
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
    
    func testRapidStartStop() {
        let expectation = XCTestExpectation(description: "Rapid start stop")
        
        mockEngine.mockData = Array(1...100).map { i in
            ["id": Int64(i), "data": "test\(i)"]
        }
        
        // Start sync
        syncHelper.run { _, _ in }
        
        // Immediately stop
        syncHelper.stop {
            // Start again
            self.syncHelper.run { success, error in
                XCTAssertTrue(success)
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 10.0)
    }
}

// MARK: - Mock URLSession for Network Testing

class MockURLSession: URLSession {
    var mockResponse: (Data?, URLResponse?, Error?)?
    
    override func dataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        return MockURLSessionDataTask {
            if let mockResponse = self.mockResponse {
                completionHandler(mockResponse.0, mockResponse.1, mockResponse.2)
            }
        }
    }
}

class MockURLSessionDataTask: URLSessionDataTask {
    private let closure: () -> Void
    
    init(closure: @escaping () -> Void) {
        self.closure = closure
    }
    
    override func resume() {
        closure()
    }
    
    override func cancel() {
        // Mock cancel
    }
}
