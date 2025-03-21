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

import UIKit

public typealias DbSyncCompletionHandler = (_ status:Bool, _ error:Error?) -> Void
public typealias DbSyncProgressHandler = (_ progress:Double, _ error:Error?) -> Void

public class DbSyncConfig {
    
    public var removeAfterSync:Bool = false
    public var batchSize:Int        = 1000
    public var markAsSynced:Bool    = false
    public var skipSyncedData:Bool  = false
    public var keepLastData:Bool    = false
    public var deviceId:String?     = nil
    public var debug:Bool           = false
    public var completionHandler:DbSyncCompletionHandler? = nil
    public var progressHandler:DbSyncProgressHandler? = nil
    public var dispatchQueue:DispatchQueue? = nil
    public var backgroundSession    = true
    public var compactDataFormat    = false
    
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
        
        if let test = config["test"] as? Bool {
            self.test = test
        }
    }
    
    public func apply(closure: (_ config: DbSyncConfig ) -> Void) -> Self {
        closure(self)
        return self
    }
}


