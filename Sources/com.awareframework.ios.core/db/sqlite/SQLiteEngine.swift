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
                        if let result = handler(d) as? PersistableRecord {
                            
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
    
    func elementToDictionary(_ element: Any) -> [String: Any] {
        let mirror = Mirror(reflecting: element)
        var dict: [String: Any] = [:]
        
        for child in mirror.children {
            if let key = child.label {
                dict[key] = child.value
            }
        }
        
        return dict
    }

    public override func fetch(filter: String?=nil, limit:Int?=nil) -> Array<Dictionary<String,Any>>? {
        /// NOTE: table生のsql文を利用するので、transformationを利用する必要は無い
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
                    let enumeratedCursor = cursor.enumerated()
                    var results:Array<Dictionary<String, Any>> = []
                    while let (_, element) = try enumeratedCursor.next() {
                        let elementDict = elementToDictionary(element)
                        results.append(elementDict)
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
    

}

