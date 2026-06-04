import Foundation
import CommonCrypto

public enum DatabaseType {
    case none
    case sqlite
}

public enum ServerType {
    case none
    case aware
    case aware_micro
    case aware_x
    case aware_light
}

public protocol EngineProtocal {
    func save(_ data: [any BaseDbModelSQLite])
    func save(_ data: [any BaseDbModelSQLite], completion: ((Error?) -> Void)?)

    func fetch(filter: String?, limit: Int?) -> [[String: Any]]?
    func fetch(filter: String?, limit: Int?, completion: (([[String: Any]]?, Error?) -> Void)?)

    func count(filter: String?) -> Int

    func remove(filter: String?, limit: Int?)
    func remove(filter: String?, limit: Int?, completion: ((Error?) -> Void)?)

    func removeAll()
    func removeAll(completion: ((Error?) -> Void)?)

    func close()

    func startSync(_ syncConfig: DbSyncConfig)
    func stopSync()
}

open class Engine: EngineProtocal {

    open var config: EngineConfig = EngineConfig()

    public init(_ config: EngineConfig) {
        self.config = config
    }

    open class EngineConfig {
        open var type: DatabaseType = .sqlite
        open var encryptionKey: String?
        open var path: String?
        open var host: String?
        open var tableName: String?
    }

    open class Builder {

        var config: EngineConfig

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

        public func setTableName(_ tableName: String?) -> Builder {
            config.tableName = tableName
            return self
        }

        public func build() -> Engine {
            switch config.type {
            case .none:
                return Engine(EngineConfig())
            case .sqlite:
                return SQLiteEngine(config)
            }
        }
    }

    public func save(_ data: [any BaseDbModelSQLite]) {
        self.save(data, completion: nil)
    }

    open func save(_ data: [any BaseDbModelSQLite], completion: ((Error?) -> Void)?) {}

    open func count(filter: String?) -> Int { 0 }

    open func fetch(filter: String?, limit: Int?) -> [[String: Any]]? { nil }

    open func fetch(filter: String?, limit: Int?, completion: (([[String: Any]]?, Error?) -> Void)?) {}

    public func remove(filter: String?, limit: Int?) {
        self.remove(filter: filter, limit: limit, completion: nil)
    }

    public func remove(filter: String?, limit: Int?, completion: ((Error?) -> Void)?) {}

    public func removeAll() {
        self.removeAll(completion: nil)
    }

    public func removeAll(completion: ((Error?) -> Void)?) {}

    open func startSync(_ syncConfig: DbSyncConfig) {}

    open func stopSync() {}

    open func close() {}
}

// MARK: - String hashing utilities

enum CryptoAlgorithm {
    case SHA1, SHA224, SHA256, SHA384, SHA512

    var digestLength: Int {
        var result: Int32 = 0
        switch self {
        case .SHA1:   result = CC_SHA1_DIGEST_LENGTH
        case .SHA224: result = CC_SHA224_DIGEST_LENGTH
        case .SHA256: result = CC_SHA256_DIGEST_LENGTH
        case .SHA384: result = CC_SHA384_DIGEST_LENGTH
        case .SHA512: result = CC_SHA512_DIGEST_LENGTH
        }
        return Int(result)
    }
}

extension String {
    var sha1:   String { digest(string: self, algorithm: .SHA1)   }
    var sha224: String { digest(string: self, algorithm: .SHA224) }
    var sha256: String { digest(string: self, algorithm: .SHA256) }
    var sha384: String { digest(string: self, algorithm: .SHA384) }
    var sha512: String { digest(string: self, algorithm: .SHA512) }

    func digest(string: String, algorithm: CryptoAlgorithm) -> String {
        let digestLength = algorithm.digestLength
        guard let cdata = string.cString(using: .utf8) else {
            fatalError("Failed to convert string to UTF-8")
        }
        var result = [CUnsignedChar](repeating: 0, count: digestLength)
        switch algorithm {
        case .SHA1:   CC_SHA1(cdata,   CC_LONG(cdata.count - 1), &result)
        case .SHA224: CC_SHA224(cdata, CC_LONG(cdata.count - 1), &result)
        case .SHA256: CC_SHA256(cdata, CC_LONG(cdata.count - 1), &result)
        case .SHA384: CC_SHA384(cdata, CC_LONG(cdata.count - 1), &result)
        case .SHA512: CC_SHA512(cdata, CC_LONG(cdata.count - 1), &result)
        }
        return (0..<digestLength).reduce("") { $0 + String(format: "%02hhx", result[$1]) }
    }
}
