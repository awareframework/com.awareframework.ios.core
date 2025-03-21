//
//  RealmEngine.swift
//  CoreAware
//
//  Created by Yuuki Nishiyama on 2018/03/06.
//

import Foundation
import RealmSwift
import CommonCrypto

open class RealmEngine: Engine {

    var syncHelper: RealmDbSyncHelper?
    var realmConfig = Realm.Configuration()
    
    public override init(_ config: EngineConfig) {
        super.init(config)
        
        if self.config.realmObjectType == nil {
            print("[Error][RealmEngine][\(#function)] `realmObjectType` is null. `realmObjectType` is a required parameter for RealmEngine. Please set the parameter when inilizaing this engine.")
        }
        
        if let path = config.path {
            let documentDirFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
            realmConfig.fileURL = documentDirFileURL.appendingPathComponent(path+".realm")
            
            // Show the local-Realm DB path
            // print(realmConfig.fileURL!)
            
            // set the encryption key
            if let encryptionKey = config.encryptionKey {
                //
                // Realm needs 64-byte text as an encryption key.
                // So then, the given key has to be converted a 64-byte text using sha256.
                //
                // Realm supports encrypting the database file on disk with AES-256+SHA2
                // by supplying a 64-byte encryption key when creating a Realm.
                // There is a small performance hit (typically less than 10% slower)
                // when using encrypted Realms.
                // https://realm.io/docs/swift/latest/#encryption
                //
                let bytesKey = encryptionKey.sha256.data(using: .utf8, allowLossyConversion: false)!
                // print(encryptionKey.sha256)
                realmConfig.encryptionKey = bytesKey
            }
            do {
                var _ = try Realm(configuration: realmConfig)
                // TODO: Set Realm DB observer
                // https://realm.io/docs/swift/latest/#notifications
//                let token = realm.observe { (notification, realm) in
//                    switch notification {
//                    case .didChange:
//                        break;
//                    case .refreshRequired:
//                        break;
//                    }
//                }
//                realm.invalidate()
            }catch let error as NSError{
                print("[Error][\(path)]",error)
            }
        }else{
            print("[Error] The database path is `nil`. RealmEngine could not generate RealmEngine instance.")
        }
    }
    
    
    /// Provide a new Realm instance
    /// 
    /// - Returns: A Realm instance
    public func getRealmInstance() -> Realm? {
        do {
            let realm = try Realm(configuration: realmConfig)
            return realm
        }catch let error as NSError{
            print("[Error][\(self.config.type)]",error)
        }
        return nil
    }
    
    open override func save(_ dict: Dictionary<String, Any>, completion:((Error?)->Void)?) {
        self.save([dict], completion:completion)
    }
    
    open override func save(_ data: Array<Dictionary<String, Any>>, completion:((Error?)->Void)?){
        if let handler = super.dictToModelHandler {
            var dataArray:Array<BaseDbModelRealm> = []
            for d in data {
                if let result = handler(d) as? BaseDbModelRealm {
                    // print(AwareObject.className())
                    // result.setAutoIncrementId(self.config.tableName ?? "--")
                    dataArray.append(result)
                }
            }
            self.save(dataArray, completion:completion)
        }
    }
    
    private func save(_ data: Array<BaseDbModelRealm>, completion:((Error?)->Void)?){
        do{
            for d in data {
                d.setAutoIncrementId(tableName: self.config.tableName ?? "--")
                print("\t-->", d.id)
            }
            
            let realm = try Realm(configuration: self.realmConfig)
            realm.beginWrite()
            autoreleasepool{
                realm.add(data)
            }
            try realm.commitWrite()
            if let callback = completion {
                callback(nil)
            }
        }catch{
            print("\(error)")
            if let callback = completion {
                callback(error)
            }
        }
    }
    
    public override func fetch(filter: String?=nil, limit:Int?=nil ) -> Array<Dictionary<String, Any>>? {

        let results:Array<Object>? = fetchRealmObject(filter: filter, limit: limit)
        
        return results?.map({ obj in
            if let handler = self.modelToDictHandler {
                return handler(obj)
            }
            return [:]
        })
    }
    
    
    public func fetchRealmObject(filter: String?=nil, limit:Int?=nil) -> Array<Object>?{
        do {
            let realm = try Realm(configuration: realmConfig)
            if let objectType = self.config.realmObjectType {
                var results:Results<Object>? = nil
                if let uwFilter = filter {
                    results = realm.objects(objectType).filter(uwFilter)
                } else {
                    results = realm.objects(objectType)
                }
                
                var resultArray: Array<Object> = []
                if let uwResults = results {
                    if let l = limit {
                        // sort objects by id
                        let objects = uwResults.sorted(byKeyPath: "id",
                                                       ascending: true).prefix(l)
                        for o in objects {
                            resultArray.append(o)
                        }
                    }else{
                        for o in uwResults {
                            resultArray.append(o)
                        }
                    }
                    return resultArray
                }else{
                    print("Error: NO modelToDictHandler")
                }
                
            }
        } catch {
            print("\(error)")
        }
        return nil
    }

//    
//    public func fetchRealmObject(filter: String?=nil, limit:Int?=nil,
//                                 completion:(Array<Object>?, Realm?, Error?) -> Void){
//        do {
//            let realm = try Realm(configuration: realmConfig)
//            if let objectType = self.config.realmObjectType {
//                var results:Results<Object>? = nil
//                if let uwFilter = filter {
//                    results = realm.objects(objectType).filter(uwFilter)
//                } else {
//                    results = realm.objects(objectType)
//                }
//                
//                if let uwResults = results {
//                    if let l = limit {
//                        // sort objects by id
//                        let objects = uwResults.sorted(byKeyPath: "id",
//                                                       ascending: true).prefix(l)
//                        var values:Array<Object> = []
//                        for o in objects {
//                            values.append(o)
//                        }
//                        completion(values, realm, nil)
//                        
//                    }else{
//                        var values:Array<Object> = []
//                        for o in uwResults {
//                            values.append(o)
//                        }
//                        completion(values, realm, nil)
//                    }
//                }else{
//                    print("Error: NO modelToDictHandler")
//                }
//                
//            }
//        } catch {
//            print("\(error)")
//        }
//    }
    
    public override func fetch( filter: String?=nil, limit:Int?=nil,
                               completion: ((Array<Dictionary<String, Any>>, Error?) -> Void)?) {
        let results = self.fetch(filter: filter, limit: limit)
        if let uwCompletion = completion, let uwResults = results {
            uwCompletion(uwResults, nil)
        }
    }
    
    open func remove(_ data:Array<Object>, in realm:Realm){
        self.remove(data, in: realm, completion: nil)
    }
    
    open func remove(_ data:Array<Object>, in realm:Realm, completion:((Error?)->Void)?){
        do {
            realm.beginWrite()
            for d in data {
                print("remove", d["id"] ?? -1) 
            }
            realm.delete(data)
            try realm.commitWrite()
            if let callback = completion {
                callback(nil)
            }
        } catch {
            if let callback = completion {
                callback(error)
            }
        }
    }
    
    open override func removeAll(completion:((Error?)->Void)?){
        do{
            let realm = try Realm(configuration: realmConfig)
            try realm.write {
                realm.deleteAll()
            }
            if let callback = completion {
                callback(nil)
            }
        }catch{
            if let callback = completion {
                callback(error)
            }
        }
    }
    
    open override func remove(filter: String?=nil, limit:Int?=nil, completion:((Error?)->Void)?){
        
        if let objectType = super.config.realmObjectType,
           let realm = self.getRealmInstance(){
    
            do {
                var results = realm.objects(objectType)
                if let uwFilter = filter {
                     results = realm.objects(objectType).filter(uwFilter)
                 } else {
                     results = realm.objects(objectType)
                 }
                
                realm.beginWrite()
                
                if let l = limit {
                    for r in results {
                        if let rObj = r as? BaseDbModelRealm {
                            print(rObj.id)
                        }
                    }
                    
                    if results.count < l {
                        realm.delete(results)
                    }else{
//                        print("remove count -> ", results.prefix(l).count)
                        for r in results.sorted(byKeyPath: "id", ascending: true).prefix(l) {
                            if let rObj = r as? BaseDbModelRealm {
                                print("target:", rObj.id)
//                                realm.delete(rObj)
                            }
                        }
                        realm.delete(results.sorted(byKeyPath: "id", ascending: true).prefix(l))
                    }
                }else{
                    realm.delete(results)
                }
                try realm.commitWrite()
                
                if let callback = completion {
                    callback(nil)
                }
            } catch {
                if let callback = completion {
                    callback(error)
                }
            }
        }
    }
    
    open override func startSync(_ syncConfig: DbSyncConfig) {
        if let uwHost    = self.config.host,
           let tableName = self.config.tableName {
            self.syncHelper?.stop()
            self.syncHelper = RealmDbSyncHelper.init(engine: self,
                                                    host:  uwHost,
                                                tableName: tableName ,
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
        self.syncHelper?.stop()
        
    }
    
    open override func close() {
        do{
            let realm = try Realm(configuration: realmConfig)
            realm.invalidate()
        }catch{
            print(error)
        }
    }
}

