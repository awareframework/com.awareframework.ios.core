/// Configuration class for database synchronization.
///
/// This class provides various configuration options for synchronizing data with a database.
/// It includes options for batch size, debug mode, and completion handlers.
///
/// - Properties:
///   - removeAfterSync: A boolean indicating whether to remove data after synchronization. Default is `true`.
///   - batchSize: An integer specifying the number of records to sync in each batch. Default is `1000`.
///   - markAsSynced: A boolean indicating whether to mark data as synced after synchronization. Default is `false`.
///   - skipSyncedData: A boolean indicating whether to skip already synced data. Default is `false`.
///   - keepLastData: A boolean indicating whether to keep the last data after synchronization. Default is `false`.
///   - deviceId: An optional string representing the device ID.
///   - debug: A boolean indicating whether to enable debug mode. Default is `false`.
///   - completionHandler: An optional completion handler to be called after synchronization.
///   - progressHandler: An optional progress handler to be called during synchronization.
///   - dispatchQueue: An optional dispatch queue for synchronization tasks.
///   - backgroundSession: A boolean indicating whether to use a background session for synchronization. Default is `true`.
///   - compactDataFormat: A boolean indicating whether to use a compact data format for synchronization. Default is `true`.
///
/// - Methods:
///   - init(): Initializes a new instance of `DbSyncConfig` with default values.
///   - init(_:): Initializes a new instance of `DbSyncConfig` with a given configuration dictionary.
///   - set(config:): Sets the configuration properties from a given dictionary.
///   - apply(closure:): Applies a closure to the configuration instance and returns the instance.
//
//  DbSyncConfig.swift
//  com.aware.ios.sensor.core
//
//  Created by Yuuki Nishiyama on 2018/10/18.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public typealias DbSyncCompletionHandler = (_ status:Bool, _ error:Error?) -> Void
public typealias DbSyncProgressHandler = (_ progress:Double, _ error:Error?) -> Void

/// Debug level for synchronization logging
public enum DbSyncDebugLevel: Int, CaseIterable {
    case none = 0      // No debug output
    case error = 1     // Only errors and critical messages
    case warning = 2   // Errors, warnings, and important status
    case info = 3      // Basic flow information
    case verbose = 4   // Detailed method flow and data
    case trace = 5     // All debug information including internal details
    
    /// Human readable description
    public var description: String {
        switch self {
        case .none: return "None"
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
        case .verbose: return "Verbose"
        case .trace: return "Trace"
        }
    }
}

public class DbSyncConfig {
    
    public var removeAfterSync:Bool = false
    public var batchSize:Int        = 1000
    public var markAsSynced:Bool    = false
    public var skipSyncedData:Bool  = false
    public var keepLastData:Bool    = false
    public var deviceId:String?     = nil
    public var debug:Bool           = false
    public var debugLevel:DbSyncDebugLevel = .info  // Default to info level
    public var completionHandler:DbSyncCompletionHandler? = nil
    public var progressHandler:DbSyncProgressHandler? = nil
    public var dispatchQueue:DispatchQueue? = nil
    public var backgroundSession    = true
    public var compactDataFormat    = false
    public var serverType:ServerType = .aware
    
    public var test = false
    
    public init() {
        
    }
    
    public init(_ config:Dictionary<String, Any>){
        set(config: config)
    }
    
    public func set(config: Dictionary<String, Any>){
        if let removeAfterSync = config["removeAfterSync"] as? Bool{
            self.removeAfterSync = removeAfterSync
        }
        
        if let batchSize = config["batchSize"] as? Int {
            self.batchSize = batchSize
        }
        
        if let markAsSynced = config["markAsSynced"] as? Bool {
            self.markAsSynced = markAsSynced
        }
        
        if let skipSyncedData = config["skipSyncedData"] as? Bool {
            self.skipSyncedData = skipSyncedData
        }
        
        if let keepLastData = config["keepLastData"] as? Bool {
            self.keepLastData = keepLastData
        }
        
        self.deviceId = config["deviceId"] as? String
        
        if let debug = config["debug"] as? Bool {
            self.debug = debug
        }
        
        if let debugLevel = config["debugLevel"] as? Int {
            if let level = DbSyncDebugLevel(rawValue: debugLevel) {
                self.debugLevel = level
            }
        } else if let debugLevelString = config["debugLevel"] as? String {
            switch debugLevelString.lowercased() {
            case "none", "0": self.debugLevel = .none
            case "error", "1": self.debugLevel = .error
            case "warning", "2": self.debugLevel = .warning
            case "info", "3": self.debugLevel = .info
            case "verbose", "4": self.debugLevel = .verbose
            case "trace", "5": self.debugLevel = .trace
            default: break
            }
        }
        
        if let test = config["test"] as? Bool {
            self.test = test
        }
        
        if let serverType = config["serverType"] as? Int {
            if serverType == 0 {
                self.serverType = .none
            } else if serverType == 1 {
                self.serverType = .aware
            } else if serverType == 2 {
                self.serverType = .aware_micro
            } else if serverType == 3 {
                self.serverType = .aware_x
            } else if serverType == 4 {
                self.serverType = .aware_light
            } else {
                self.serverType = .aware
            }
        }
    }
    
    public func apply(closure: (_ config: DbSyncConfig ) -> Void) -> Self {
        closure(self)
        return self
    }
}


