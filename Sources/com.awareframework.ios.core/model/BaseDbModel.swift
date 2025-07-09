//
//  AwareRealmObject.swift
//  aware-core
//
//  Created by Yuuki Nishiyama on 2018/01/01.
//  Copyright © 2018 Yuuki Nishiyama. All rights reserved.
//

import Foundation
import GRDB

public protocol BaseDbModelSQLite: Codable, FetchableRecord, PersistableRecord {
    var id: Int64? {get}
    var timestamp: Int64 { get }
    var deviceId: String { get }
    var label : String { get }
    var timezone: Int { get }
    var os: String { get }
    var jsonVersion: Int { get }
    
    init(_ dict:Dictionary<String, Any>)
    
    func toDictionary() -> Dictionary<String, Any>
    
    static func createTable(queue: DatabaseQueue) throws
    static var databaseTableName: String  { get }
}
