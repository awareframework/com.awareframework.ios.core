//
//  AwareRealmObject.swift
//  aware-core
//
//  Created by Yuuki Nishiyama on 2018/01/01.
//  Copyright © 2018 Yuuki Nishiyama. All rights reserved.
//

import Foundation
import RealmSwift
import GRDB

open class BaseDbModelRealm: Object {
    @objc dynamic public var id: Int64 = 0
    @objc dynamic public var timestamp: Int64 = Int64(Date().timeIntervalSince1970*1000)
    @objc dynamic public var deviceId: String = AwareUtils.getCommonDeviceId()
    @objc dynamic public var label : String = ""
    @objc dynamic public var timezone: Int = AwareUtils.getTimeZone()
    @objc dynamic public var os: String = "ios"
    @objc dynamic public var jsonVersion: Int = 0
    
    public override static func primaryKey() -> String? {
        return "id"
    }
    
    open func toDictionary() -> Dictionary<String, Any> {
        let dict = ["id": id,
                    "timestamp":timestamp,
                    "deviceId" :deviceId,
                    "label"    :label,
                    "timezone" :timezone,
                    "os"       :os,
                    "jsonVersion":jsonVersion] as [String : Any]
        return dict
    }
    
    public func fromDictionary(_ dict:Dictionary<String, Any>) {
        if let timestamp = dict["timestamp"] as? Int64 { self.timestamp = timestamp }
        if let deviceId  = dict["deviceId"] as? String { self.deviceId = deviceId }
        if let label     = dict["label"] as? String {self.label = label}
        if let timezone  = dict["timezone"] as? Int {self.timezone = timezone}
        if let os        = dict["os"] as? String {self.os = os}
        if let jsonVersion = dict["jsonVersion"] as? Int {self.jsonVersion = jsonVersion}
    }
    
    public func setAutoIncrementId(tableName:String) {
        if self.id == 0 {
            let key = "aware.db.realm.last_id.\(tableName)"
            let lastId:Int = UserDefaults.standard.integer(forKey: key)
            self.id = Int64(lastId + 1);
            UserDefaults.standard.setValue(self.id, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }
    
    public func resetAutoIncrementId(tableName:String){
        let key = "aware.db.realm.last_id.\(tableName)"
        UserDefaults.standard.setValue(0, forKey: key)
        UserDefaults.standard.synchronize()
    }
}

//public struct BaseDbModelSQLite:BaseDbModelSQLiteProtocol {
//    public let timestamp: Int64 = Int64(Date().timeIntervalSince1970*1000)
//    public let deviceId: String = AwareUtils.getCommonDeviceId()
//    public let label : String = ""
//    public let timezone: Int = AwareUtils.getTimeZone()
//    public let os: String = "ios"
//    public let jsonVersion: Int = 0
//    
//    
//    public func toDictionary() -> Dictionary<String, Any> {
//        let dict = [ //"id": id,
//                    "timestamp":timestamp,
//                    "deviceId" :deviceId,
//                    "label"    :label,
//                    "timezone" :timezone,
//                    "os"       :os,
//                    "jsonVersion":jsonVersion] as [String : Any]
//        return dict
//    }
//
//    static var databaseTableName: String {
//        return "BaseDbModelSQLite"
//    }
//    
//    public static func createTable(queue: DatabaseQueue)
//}

public protocol BaseDbModelSQLiteProtocol: Codable, FetchableRecord, PersistableRecord {
    var timestamp: Int64 { get }
    var deviceId: String { get }
    var label : String { get }
    var timezone: Int { get }
    var os: String { get }
    var jsonVersion: Int { get }
    
    init(_ dict:Dictionary<String, Any>)
    
    func toDictionary() -> Dictionary<String, Any>
    
    static func createTable(queue: DatabaseQueue)
    static var databaseTableName: String  { get }
}
