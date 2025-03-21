//
//  RealmDbSyncHelper.swift
//  com.awareframework.ios.core
//
//  Created by Yuuki Nishiyama on 2025/03/20.
//
import RealmSwift

open class RealmDbSyncHelper: DbSyncHelper {
    
    var realmEngine:RealmEngine?
    var realmInstance:Realm?
    
    var candidates:Array<Object>?
    
    public override init(engine: Engine, host: String, tableName: String, config: DbSyncConfig) {
        super.init(engine: engine, host: host, tableName: tableName, config: config)
        
        if let realmEngine = engine as? RealmEngine {
            self.realmEngine = realmEngine
            self.realmInstance = realmEngine.getRealmInstance()
        }
    }
    
    open override func getUploadCandidates(lastUploadedId lastUploasedId:Int64, limit:Int) -> Array<Dictionary<String, Any>>{
        let filter = "id > \(lastUploasedId)"
        candidates = self.realmEngine?.fetchRealmObject(filter: filter, limit:limit)
        var dictCandidates:Array<Dictionary<String, Any>> = []
        if let candidates = candidates {
            for c in candidates {
                if let c = c as? BaseDbModelRealm {
                    if let handler = realmEngine?.modelToDictHandler {
                        dictCandidates.append(handler(c))
                    }else{
                        dictCandidates.append(c.toDictionary())
                    }
                }
            }
        }
        return dictCandidates
    }
    
    open override func removeUploadedCandidates(lastUploadedId:Int64, limit:Int) {
        let filter = "id > \(lastUploadedId)"
        realmEngine?.remove(filter: filter, limit: limit)
    }
    
}
