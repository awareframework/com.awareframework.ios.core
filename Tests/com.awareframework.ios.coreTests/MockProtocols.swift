//
//  MockProtocols.swift
//  com.awareframework.ios.core.Tests
//
//  Created by Test Suite on 2025/07/09.
//

import Foundation

// MARK: - Protocol Definitions (these would normally be in the main codebase)

protocol Engine {
    func fetch(filter: String?, limit: Int) -> [[String: Any]]?
    func count(filter: String?) -> Int
    func remove(filter: String?, limit: Int)
}

protocol DbSyncConfig {
    var batchSize: Int { get set }
    var removeAfterSync: Bool { get set }
    var backgroundSession: Bool { get set }
    var debug: Bool { get set }
    var test: Bool { get set }
    var compactDataFormat: Bool { get set }
    var progressHandler: ((Double, Error?) -> Void)? { get set }
    var dispatchQueue: DispatchQueue? { get set }
}

typealias DbSyncCompletionHandler = (Bool, Error?) -> Void

// MARK: - Mock Utilities

class AwareUtils {
    static func getCommonDeviceId() -> String {
        return "test-device-id"
    }
    
    static func getTimeZone() -> Int {
        return TimeZone.current.secondsFromGMT() / 3600
    }
    
    static func cleanHostName(_ host: String) -> String {
        return host.replacingOccurrences(of: "https://", with: "")
                  .replacingOccurrences(of: "http://", with: "")
    }
}
