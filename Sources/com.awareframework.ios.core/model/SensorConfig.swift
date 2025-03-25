//
//  AwareSensorConfig.swift
//  CoreAware
//
//  Created by Yuuki Nishiyama on 2018/03/02.
//

import Foundation

open class SensorConfig{
    
    public var enabled:Bool = false
    public var debug:Bool = false
    public var label:String = ""
    public var deviceId:String = AwareUtils.getCommonDeviceId()
    public var dbEncryptionKey:String? = nil
    public var dbType:DatabaseType = .sqlite
    public var serverType:ServerType = .aware_micro
    public var dbPath:String = "aware"
    public var dbHost:String? = nil
    
    public var dbTableName:String? = nil
    
    public init(){}
    
    public convenience init(_ config:Dictionary<String,Any>){
        self.init()
        self.set(config: config)
    }
    
    open func set(config:Dictionary<String,Any>){
        if let enabled = config["enabled"] as? Bool{
            self.enabled = enabled
        }
        
        if let debug = config["debug"] as? Bool {
            self.debug = debug
        }
        
        if let label = config["label"] as? String {
            self.label = label
        }

        if let deviceId = config["deviceId"] as? String {
            self.deviceId = deviceId
        }
        
        dbEncryptionKey = config["dbEncryptionKey"] as? String

        if let dbType = config["dbType"] as? Int {
            if dbType == 0 {
                self.dbType = .none
            }else if dbType == 1 {
                self.dbType = .sqlite
            }
        }
        
        if let dbType = config["dbType"] as? DatabaseType {
            self.dbType = dbType
        }
        
        if let dbPath = config["dbPath"] as? String {
            self.dbPath = dbPath
        }
        
        if let dbHost = config["dbHost"] as? String {
            self.dbHost = dbHost
        }
        
        if let dbTableName = config["dbTableName"] as? String {
            self.dbTableName = dbTableName
        }
        
    }
    
    public func verify() -> Bool{
        if self.dbTableName == nil {
            print("[Error][SensorConfig] `dbTableName` is required parameter.")
            return false
        }
        return true
    }
}
