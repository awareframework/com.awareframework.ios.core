//
//  Engine.swift
//  CoreAware
//
//  Created by Yuuki Nishiyama on 2018/03/02.
//

import Foundation
import CommonCrypto


public typealias DictToModelHandler = (_ dict:Dictionary<String, Any>) -> Any
public typealias ModelToDictHandler = (Any) -> Dictionary<String,Any>
//public typealias TargetTableFormatTransformationHandler = (_ tableName:String) -> Any

public enum DatabaseType {
    case NONE
    case SQLite
    // case CSV
}

public protocol EngineProtocal {
    
    func save(_ dict:Dictionary<String, Any>)
    func save(_ dict:Dictionary<String, Any>, completion:((Error?)->Void)? )
    func save(_ data:Array<Dictionary<String, Any>>)
    func save(_ data:Array<Dictionary<String, Any>>, completion:((Error?)->Void)?)
    
    func fetch(filter:String?, limit:Int?) -> Array<Dictionary<String,Any>>?
    func fetch(filter:String?, limit:Int?, completion:((Array<Dictionary<String,Any>>?, Error?)->Void)?)

    func remove(filter:String?, limit: Int?)
    func remove(filter:String?, limit: Int?, completion:((Error?)->Void)?)
   
    func removeAll()
    func removeAll(completion:((Error?)->Void)?)
    
    func close()
    
    func startSync(_ syncConfig:DbSyncConfig)
    func stopSync()
}

open class Engine: EngineProtocal {

    open var dictToModelHandler:DictToModelHandler?
    open var modelToDictHandler:ModelToDictHandler?
    
    open var config:EngineConfig = EngineConfig()
    
    public init(_ config: EngineConfig){
        self.config = config
    }
    
    open class EngineConfig{
        open var type: DatabaseType = DatabaseType.SQLite
        open var encryptionKey:String?
        open var path:String?
        open var host:String?
        open var tableName:String?
    }
    
    open class Builder {
        
        var config:EngineConfig
        
        public init() {
            config = EngineConfig()
        }
        
        public func setType(_ type: DatabaseType) -> Builder {
            config.type = type
            return self
        }
        
        public func setEncryptionKey(_ key: String?) -> Builder {
            config.encryptionKey = key
            return self
        }
        
        public func setPath(_ path: String?) -> Builder {
            config.path = path
            return self
        }
        
        public func setHost(_ host: String?) -> Builder {
            config.host = host
            return self
        }
        
        public func setTableName(_ tableName: String?)-> Builder {
            config.tableName = tableName
            return self
        }
        
        
        public func build() -> Engine {
            switch config.type {
            case DatabaseType.NONE:
                return Engine.init(EngineConfig())
            case DatabaseType.SQLite:
                return SQLiteEngine.init(self.config)
            }
        }
    }
    
    open func getDefaultEngine() -> Engine {
        return Builder().build()
    }
    
    public func save(_ dict: Dictionary<String, Any>) {
        self.save(dict, completion:nil)
    }
    
    public func save(_ data: Array<Dictionary<String, Any>>) {
        self.save(data, completion:nil)
    }
    
    open func save(_ dict: Dictionary<String, Any>,completion:((Error?)->Void)?){
        // print("Please orverwrite -save(objects)")
    }
    
    open func save(_ data: Array<Dictionary<String, Any>>,completion:((Error?)->Void)?){
        // print("Please orverwrite -save(objects)")
    }
    
    
    public func fetch(filter: String?, limit: Int?) -> Array<Dictionary<String,Any>>? {
        return nil
    }
    
    public func fetch(filter: String?, limit: Int?, completion: ((Array<Dictionary<String,Any>>?, Error?) -> Void)?) {
        
    }
    
    public func remove(filter: String?, limit: Int?) {
        self.remove(filter: filter, limit: limit, completion: nil)
    }
    
    public func remove( filter: String?, limit: Int?, completion: ((Error?) -> Void)?) {
        
    }
    
    public func removeAll() {
        self.removeAll(completion: nil)
    }
    
    public func removeAll(completion: ((Error?) -> Void)?) {
        
    }
    
    open func startSync(_ syncConfig:DbSyncConfig){
        // print("Please overwrite -startSync(tableName:objectType:syncConfig)")
    }
    
    open func stopSync() {
        // print("Please orverwirte -stopSync()")
    }
    
    open func close() {
        // print("Please orverwirte -close()")
    }
    
}


enum CryptoAlgorithm {
    case SHA1, SHA224, SHA256, SHA384, SHA512
    
    var digestLength: Int {
        var result: Int32 = 0
        switch self {
        case .SHA1:     result = CC_SHA1_DIGEST_LENGTH
        case .SHA224:   result = CC_SHA224_DIGEST_LENGTH
        case .SHA256:   result = CC_SHA256_DIGEST_LENGTH
        case .SHA384:   result = CC_SHA384_DIGEST_LENGTH
        case .SHA512:   result = CC_SHA512_DIGEST_LENGTH
        }
        return Int(result)
    }
}

extension String {
    var sha1:   String { return digest(string: self, algorithm: .SHA1) }
    var sha224: String { return digest(string: self, algorithm: .SHA224) }
    var sha256: String { return digest(string: self, algorithm: .SHA256) }
    var sha384: String { return digest(string: self, algorithm: .SHA384) }
    var sha512: String { return digest(string: self, algorithm: .SHA512) }
    
    func digest(string: String, algorithm: CryptoAlgorithm) -> String {
        var result: [CUnsignedChar]
        let digestLength = Int(algorithm.digestLength)
        if let cdata = string.cString(using: String.Encoding.utf8) {
            result = Array(repeating: 0, count: digestLength)
            switch algorithm {
            case .SHA1:     CC_SHA1(cdata, CC_LONG(cdata.count-1), &result)
            case .SHA224:   CC_SHA224(cdata, CC_LONG(cdata.count-1), &result)
            case .SHA256:   CC_SHA256(cdata, CC_LONG(cdata.count-1), &result)
            case .SHA384:   CC_SHA384(cdata, CC_LONG(cdata.count-1), &result)
            case .SHA512:   CC_SHA512(cdata, CC_LONG(cdata.count-1), &result)
            }
        } else {
            fatalError("Nil returned when processing input strings as UTF8")
        }
        return (0..<digestLength).reduce("") { $0 + String(format: "%02hhx", result[$1])}
    }
}
