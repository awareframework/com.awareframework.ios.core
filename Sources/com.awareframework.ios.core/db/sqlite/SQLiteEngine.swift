//
//  SQLiteEngine.swift
//  com.awareframework.ios.core
//
//  Created by Yuuki Nishiyama on 2025/03/14.
//

import Foundation
import CommonCrypto
import GRDB

open class SQLiteEngine: Engine {

    var syncHelper:DbSyncHelper?
    
    public override init(_ config: EngineConfig) {
        super.init(config)
        if let path = config.path {
            let documentDirFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
            let fileURL = documentDirFileURL.appendingPathComponent(path+".sqlite")
            do {
                _ = try DatabaseQueue(path: fileURL.absoluteString)
            } catch {
                print(error)
            }
        }else{
            print("[Error][SQLiteEngine] The database path is `nil`. SQLiteEngine could not generate RealmEngine instance.")
        }
    }
    
    
    /// Provide a new Realm instance
    ///
    /// - Returns: A Realm instance
    public func getSQLiteInstance() -> DatabaseQueue? {
        do {
            if let path = config.path {
                let documentDirFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
                let fileURL = documentDirFileURL.appendingPathComponent(path+".sqlite")
                let dbQueue = try DatabaseQueue(path: fileURL.absoluteString)
                return dbQueue
            }
        } catch {
            print("[Error][\(self.config.type)]",error)
        }
        return nil
    }
    
    open override func save(_ dict: Dictionary<String, Any>, completion:((Error?)->Void)?) {
        self.save([dict], completion: completion)
    }
    
    open override func save(_ data: Array<Dictionary<String, Any>>, completion:((Error?)->Void)?){
        if let handler = self.dictToModelHandler {
            do {
                let instance = self.getSQLiteInstance()
                try instance?.write{ db in
                    for d in data {
                        if let result = handler(d) as? (any PersistableRecord) {
                            try result.insert(db)
                        }
                    }
                }
            }catch {
                print(error)
            }
        }else {
            print("[Error][SQLiteEngine] `dictToModelHandler` is a required handler. Please the handler for \(config.tableName ?? "tableName")")
        }
    }
    
    open func save(_ data: Array<any BaseDbModelSQLite>, completion:((Error?)->Void)?){
        do {
            let instance = self.getSQLiteInstance()
            try instance?.write{ db in
                for d in data {
                    try d.insert(db)
                }
            }
            if let completion = completion {
                completion(nil)
            }
        }catch {
            print(error)
        }
    }
    
    public override func count(filter: String?) -> Int {
        let instance = self.getSQLiteInstance()
        if let tableName = self.config.tableName {
            do {
                let queryResult = try instance?.read { db in
                    var sql = "SELECT count(*) as count FROM \(tableName)"
                    if let f = filter {
                        sql = "\(sql) where \(f)"
                    }
                    let cursor = try Row.fetchCursor(db, sql: sql)
                    
                    // convert Row to Dict
                    var result: [String: Any] = [:]
                    while let row = try cursor.next() {
                        var dict: [String: Any] = [:]
                        for column in row.columnNames {
                            dict[column] = row[column]
                        }
                        result = dict
                        break
                    }
                    // return the number of candidates
                    return result["count"] ?? 0
                }
                if let c = queryResult {
                    return Int(c as! Int64)
                }
            }catch {
                print(error)
            }
        }
        return 0
    }


    public override func fetch(filter: String?=nil, limit:Int?=nil) -> Array<Dictionary<String,Any>>? {
        let instance = self.getSQLiteInstance()
        if let tableName = self.config.tableName {
            do {
                let queryResult = try instance?.read { db in
                    var sql = "SELECT * FROM \(tableName)"
                    if let f = filter {
                        sql = "\(sql) where \(f)"
                    }
                    if let l = limit {
                        sql = "\(sql) limit \(l)"
                    }
                    
                    let cursor = try Row.fetchCursor(db, sql: sql)
                    
                    // convert Row to Dict
                    var results: [[String: Any]] = []
                    while let row = try cursor.next() {
                        var dict: [String: Any] = [:]
                        for column in row.columnNames {
                            dict[column] = row[column]
                        }
                        results.append(dict)
                    }
                    
                    return results
                }
                return queryResult
            }catch {
                print(error)
            }
        }
        return nil
    }
    
    public override func fetch(filter: String?=nil, limit:Int?=nil,
                               completion: ((Array<Dictionary<String,Any>>?, Error?) -> Void)?) {
        if let completion = completion {
            let result = fetch(filter: filter, limit: limit)
            completion(result, nil)
        }
    }
    
    
    open override func removeAll(completion:((Error?)->Void)?){
        let instance = self.getSQLiteInstance()
        if let tableName = self.config.tableName {
            do {
                try instance?.write({ db in
                    try db.execute(sql: "delete from \(tableName)")
                })
            }catch {
                print(error)
            }
        }
    }
    
    open override func remove(filter: String?=nil, limit:Int?=nil, completion:((Error?)->Void)?){
        let instance = self.getSQLiteInstance()
        if let tableName = self.config.tableName {
            do {
                try instance?.write({ db in
                    var sql = "delete from \(tableName)"
                    if let f = filter {
                        sql = "\(sql) where \(f)"
                    }
                    if let l = limit {
                        sql = "\(sql) limit \(l)"
                    }
                    try db.execute(sql: sql)
                    
                    if let uwCompletion = completion {
                        uwCompletion(nil)
                    }
                })
            }catch {
                print(error)
            }
        }
       
    }
    
    open override func startSync(_ syncConfig: DbSyncConfig) {
        if let uwHost = self.config.host,
           let tableName = self.config.tableName {
            self.syncHelper?.stop()
                
            self.syncHelper = DbSyncHelper.init(engine: self,
                                                    host:   uwHost,
                                                    tableName:  tableName,
                                                    config: syncConfig)
            
            if let queue = syncConfig.dispatchQueue {
                queue.async {
                    self.syncHelper?.run(completion: syncConfig.completionHandler)
                }
            }else{
                self.syncHelper?.run(completion: syncConfig.completionHandler)
            }
            
        }else{
            print("[Error][\(self.config.tableName ?? "table name is empty")] 'Host Name' or 'Object Type' is nil. Please check the parapmeters.")
        }
    }
    
    open override func stopSync() {
        // print("Please overwrite -cancelSync()")
        self.syncHelper?.stop()
        
    }
    
    open override func close() {

    }
    
    
    func getAllTableNames(in dbQueue: DatabaseQueue) throws -> [String] {
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master 
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
            """)
        }
    }
    
    func hasTable(_ tableName:String, in dbQueue: DatabaseQueue) throws  -> Bool{
        let tables = try getAllTableNames(in: dbQueue)
        return tables.contains { element in
            if element == tableName {
                return true
            }
            return false
        }
    }

}

