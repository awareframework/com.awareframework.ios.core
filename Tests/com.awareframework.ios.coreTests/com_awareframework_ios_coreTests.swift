import XCTest
@testable import com_awareframework_ios_core

import GRDB

class UnitTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testInitializationOnAwareSensor(){
        let sensor = AwareSensor.init()
        XCTAssertEqual(sensor.syncState, false)

        sensor.enable()
        XCTAssertEqual(sensor.syncState, true)

        sensor.disable()
        XCTAssertEqual(sensor.syncState, false)

        let sensor2 = AwareSensor.init()
        sensor2.initializeDbEngine(config: SensorConfig())
        XCTAssertNil(sensor2.dbEngine?.config.encryptionKey)
        XCTAssertEqual(sensor2.dbEngine?.config.path, "aware")
        XCTAssertNil(sensor2.dbEngine?.config.host)
        XCTAssertEqual(sensor2.dbEngine?.config.type, DatabaseType.sqlite)
        
        let config = SensorConfig.init()
        config.dbHost = "sample.server.awareframework.com"
        config.dbPath = "aware_hoge"
        config.dbType = DatabaseType.sqlite
        config.dbEncryptionKey = "testtest"
        sensor.initializeDbEngine(config: config)
        XCTAssertEqual(config.dbHost!, sensor.dbEngine?.config.host!)
        XCTAssertEqual(config.dbPath, sensor.dbEngine?.config.path!)
        XCTAssertEqual(config.dbType, sensor.dbEngine?.config.type)
        XCTAssertEqual(config.dbEncryptionKey!, sensor.dbEngine?.config.encryptionKey!)
    }
    
    func testInitializationOnDbSyncConfig(){
        let config1 = DbSyncConfig.init()
        XCTAssertTrue(config1.removeAfterSync)
        XCTAssertEqual(config1.batchSize, 1000)
        XCTAssertFalse(config1.markAsSynced)
        XCTAssertFalse(config1.skipSyncedData)
        XCTAssertFalse(config1.keepLastData)
        XCTAssertNil(config1.deviceId)
        XCTAssertFalse(config1.debug)
        
        let dict:Dictionary<String,Any> =  [
                     "removeAfterSync":false,
                     "batchSize":200,
                     "markAsSynced":true,
                     "skipSyncedData":true,
                     "keepLastData":true,
                     "deviceId":"hogehogehoge",
                     "debug":true]
        
        let config2 = DbSyncConfig.init(dict)
        XCTAssertFalse(config2.removeAfterSync)
        XCTAssertEqual(config2.batchSize, 200)
        XCTAssertTrue(config2.markAsSynced)
        XCTAssertTrue(config2.skipSyncedData)
        XCTAssertTrue(config2.keepLastData)
        XCTAssertEqual(config2.deviceId, "hogehogehoge")
        XCTAssertTrue(config2.debug)
        
        // test with wrong values
        let dict3:Dictionary<String,Any> =  [
            "removeAfterSync":1234,
            "batchSize":"123",
            "markAsSynced":444,
            "skipSyncedData":23,
            "keepLastData":444,
            "deviceId":123,
            "debug":"hoge"]
        let config3 = DbSyncConfig.init(dict3)
        XCTAssertTrue(config3.removeAfterSync)  // a wrong type keeps the default
        XCTAssertEqual(config3.batchSize, 1000)
        XCTAssertFalse(config3.markAsSynced)
        XCTAssertFalse(config3.skipSyncedData)
        XCTAssertFalse(config3.keepLastData)
        XCTAssertNil(config3.deviceId)
        XCTAssertFalse(config3.debug)
    }
    
    
    func testInitializationOnSetConfig(){
        // DatabaseType based DB Type setting (NONE)
        let config = SensorConfig(["dbType":DatabaseType.none]);
        XCTAssertEqual(config.dbType, DatabaseType.none)
        
        // Int based DB Type setting (NONE)
        config.set(config: ["dbType":0])
        XCTAssertEqual(config.dbType, DatabaseType.none)
        
        
        config.set(config: ["dbType":1])
        XCTAssertEqual(config.dbType, DatabaseType.sqlite)
        
        config.set(config: ["dbType":DatabaseType.sqlite])
        XCTAssertEqual(config.dbType, DatabaseType.sqlite)
    }
    
    func testMethodsOnUtils(){
        ////////////////////////////////
        // URL modification //
        let hostName = "node.awareframework.com"
        
        // test in the ideal condition
        var newUrl = AwareUtils.cleanHostName(hostName)
        XCTAssertEqual(newUrl, hostName)

        // test removing "https://"
        newUrl = AwareUtils.cleanHostName("https://"+hostName)
        XCTAssertEqual(newUrl, hostName)

        // test remove "http://"
        newUrl = AwareUtils.cleanHostName("http://"+hostName)
        XCTAssertEqual(newUrl, hostName)
    }


    
    
    func testSQLiteEngines(){
        // remove old database
        let documentDirFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
        let url = documentDirFileURL.appendingPathComponent("sample.sqlite")
        do {
            try FileManager.default.removeItem(at: url)
        }catch{
            print(error)
        }
        
        let dbType = DatabaseType.sqlite
        print("Setup Engine:", dbType)
        
        let tableName = A.databaseTableName
        
        let engine = Engine.Builder()
            .setTableName(tableName)
            .setType(dbType)
            .setPath("sample")
            .build()
        
        
        print("Setup SQLite Engine Converters:", dbType)
        print("Create a table in SQLite")
        if let e = engine as? SQLiteEngine {
            if let q = e.getSQLiteInstance() {
                try? A.createTable(queue: q)
            }
        }

        engine.save([self.getSmapleData()] as [any BaseDbModelSQLite])
        let results = engine.fetch(filter: nil, limit: nil)
        XCTAssertEqual((results ?? []).count, 1)


        var models: [any BaseDbModelSQLite] = []
        for i in 0..<100 {
            print(i)
            models.append(self.getSmapleData())
        }
        engine.save(models)
        
        let results2 = engine.fetch(filter: nil, limit: nil)
        XCTAssertEqual((results2 ?? []).count, 101)
        
        let results3 = engine.fetch(filter: nil, limit: 30)
        XCTAssertEqual((results3 ?? []).count, 30)
        
        engine.remove(filter: nil, limit: 1)
        let results4 = engine.fetch(filter: nil, limit: nil)
        XCTAssertEqual((results4 ?? []).count, 100)
        
        engine.removeAll()
        let results5 = engine.fetch(filter: nil, limit: nil)
        XCTAssertEqual((results5 ?? []).count, 0)
    }

    func testSQLiteExportFileNaming() {
        XCTAssertEqual(SQLiteEngine.sqliteFileName(for: "aware_accelerometer"), "aware_accelerometer.sqlite")
        XCTAssertEqual(SQLiteEngine.sqliteFileName(for: "aware_accelerometer.sqlite"), "aware_accelerometer.sqlite")
        XCTAssertEqual(SQLiteEngine.sqliteFileName(for: "  "), "aware.sqlite")
        XCTAssertEqual(
            SQLiteEngine.csvFileNameStem(databasePath: "aware_healthkit.sqlite", tableName: "ios_healthkit_heart_rate"),
            "aware_healthkit__ios_healthkit_heart_rate"
        )
        XCTAssertEqual(
            SQLiteEngine.csvFileNameStem(databasePath: "  ", tableName: "ios_screen_brightness"),
            "aware__ios_screen_brightness"
        )
    }
    
    
    func getSmapleData() -> A {
        return A.init( Dictionary<String, Any>() )
    }
    
    struct A:BaseDbModelSQLite{

        var id:Int64?
        var timestamp: Int64 = Int64(Date().timeIntervalSince1970*1000)
        var deviceId: String = AwareUtils.getCommonDeviceId()
        var label: String = ""
        var timezone: Int = AwareUtils.getTimeZone()
        var os: String = "ios"
        var jsonVersion: Int = 1
        
        init(){}
        
        init(_ dict: Dictionary<String, Any>) {
//            if let id = dict["id"] as? Int64{
//                self.id = id
//            }
            if let timestamp = dict["timestamp"] as? Int64 {
                self.timestamp = timestamp
            }
            if let tz = dict["timezone"] as? Int{
                self.timezone = tz
            }
            if let os = dict["os"] as? String {
                self.os = os
            }
            if let jsonVersion = dict["jsonVersion"] as? Int {
                self.jsonVersion = jsonVersion
            }
            if let label = dict["label"] as? String {
                self.label = label
            }
        }
        
        func toDictionary() -> Dictionary<String, Any> {
            let dict = [
                "id":id ?? -1,
                "timestamp":timestamp,
                "deviceId": deviceId,
                "label": label,
                "timezone": timezone,
                "os":os,
                "jsonVersion":jsonVersion] as [String : Any]
            return dict
        }
        
        static func createTable(queue: GRDB.DatabaseQueue) {
            do {
                try queue.write { db in
                    try db.create(table: A.databaseTableName) { t in
                        t.autoIncrementedPrimaryKey("id")
                        t.column("deviceId", .text).notNull()
                        t.column("timestamp", .integer).notNull()
                        t.column("os", .text).notNull()
                        t.column("timezone", .integer).notNull()
                        t.column("label", .text).notNull()
                        t.column("jsonVersion", .integer).notNull()
                    }
                }
            } catch {
                print(error)
            }
        }
        
    }
    
    /// After a batch is uploaded, only that batch is deleted. Rows saved while the request was in
    /// flight (larger IDs) must stay, and the DELETE must run on the system SQLite (no LIMIT clause).
    func testRemoveUploadedCandidatesDeletesOnlyTheUploadedBatch() {
        let sensor = AwareSensor()
        let config = SensorConfig()
        config.dbHost = "node.awareframework.com:1001"
        config.dbType = .sqlite
        config.dbPath = "remove_after_sync_test"
        config.dbTableName = A.databaseTableName
        sensor.initializeDbEngine(config: config)
        guard let engine = sensor.dbEngine as? SQLiteEngine, let queue = engine.getSQLiteInstance() else {
            return XCTFail("SQLite engine is not available")
        }
        A.createTable(queue: queue)
        engine.removeAll()
        engine.save((0..<10).map { _ in self.getSmapleData() } as [any BaseDbModelSQLite])
        let ids = (engine.fetch(filter: nil, limit: nil) ?? []).compactMap { $0["id"] as? Int64 }.sorted()
        XCTAssertEqual(ids.count, 10)

        let helper = DbSyncHelper(engine: engine, host: config.dbHost!, tableName: A.databaseTableName,
                                  config: DbSyncConfig().apply { $0.keepDataAfterSync = 0 })
        // The first 4 rows were uploaded; the other 6 were saved while the request was in flight.
        helper.idOfLastCandidate = ids[3]
        helper.removeUploadedCandidates(lastUploadedId: ids[0] - 1, limit: 1000)

        let remaining = (engine.fetch(filter: nil, limit: nil) ?? []).compactMap { $0["id"] as? Int64 }.sorted()
        XCTAssertEqual(remaining, Array(ids[4...]))

        // Without an uploaded batch nothing is deleted.
        helper.idOfLastCandidate = nil
        helper.removeUploadedCandidates(lastUploadedId: ids[3], limit: 1000)
        XCTAssertEqual(engine.count(filter: nil), 6)
        engine.removeAll()
    }

    func testKeepDataAfterSyncConfig() {
        let config = DbSyncConfig()
        XCTAssertEqual(config.keepDataAfterSync, 86400)  // one day
        XCTAssertEqual(config.keepPeriod, .day)

        config.keepPeriod = .week
        XCTAssertEqual(config.keepDataAfterSync, 604800)
        config.keepDataAfterSync = 90
        XCTAssertNil(config.keepPeriod)  // not one of the periods
        config.keepDataAfterSync = -1  // ignored
        XCTAssertEqual(config.keepDataAfterSync, 90)
        config.keepPeriod = .immediately
        XCTAssertEqual(config.keepDataAfterSync, 0)

        XCTAssertEqual(DbSyncConfig(["keepDataAfterSync": 3600]).keepPeriod, .hour)
        XCTAssertEqual(DbSyncConfig(["keepDataAfterSync": 1.5]).keepDataAfterSync, 1.5)
        XCTAssertEqual(DbSyncConfig(["keepPeriod": "Month"]).keepDataAfterSync, 60 * 60 * 24 * 30)
        XCTAssertEqual(DbSyncConfig(["keepPeriod": "year"]).keepDataAfterSync, 86400)  // unknown name keeps the default
        XCTAssertEqual(DbSyncConfig(["keepDataAfterSync": "3600"]).keepDataAfterSync, 86400)  // wrong type
    }

    /// `copy()` copies every stored property. Each property is first set to a non-default value;
    /// a property added to `DbSyncConfig` without updating this test (and `copy()`) makes it fail.
    func testDbSyncConfigCopy() {
        let original = DbSyncConfig()
        original.removeAfterSync = false
        original.keepDataAfterSync = 123
        original.batchSize = 42
        original.maxBatchBytes = 123_456
        original.maxBatchRows = 77
        original.maxBatchBytesCeiling = 9_999_999
        original.prefetchNextBatch = !DbSyncConfig.defaultPrefetchNextBatch
        original.batchInterval = 0.5
        original.cpuRestRatio = 2
        original.backgroundCpuRestRatio = 5
        original.markAsSynced = true
        original.skipSyncedData = true
        original.keepLastData = true
        original.deviceId = "device-1"
        original.debug = true
        original.debugLevel = .trace
        original.completionHandler = { _, _ in }
        original.progressHandler = { _, _ in }
        original.dispatchQueue = DispatchQueue(label: "copy.test")
        original.backgroundSession = true
        original.compactDataFormat = !DbSyncConfig.defaultCompactDataFormat
        original.serverType = DbSyncConfig.defaultServerType == .aware_micro ? .aware_light : .aware_micro
        original.studyNumber = DbSyncConfig.defaultStudyNumber + 1
        original.studyKey = DbSyncConfig.defaultStudyKey + "-key"
        original.test = true

        let copy = original.copy()
        XCTAssertFalse(copy === original)

        func values(_ c: DbSyncConfig) -> [String: String] {
            Dictionary(uniqueKeysWithValues: Mirror(reflecting: c).children.compactMap { child in
                child.label.map { ($0, String(describing: child.value)) }
            })
        }
        let defaults = values(DbSyncConfig()), originals = values(original), copies = values(copy)
        XCTAssertEqual(originals.count, 25, "a property was added or removed: update copy() and this test")
        for (name, value) in originals {
            XCTAssertNotEqual(value, defaults[name], "\(name) is not set in this test")
            XCTAssertEqual(copies[name], value, "\(name) is not copied by copy()")
        }
        XCTAssertTrue(copy.dispatchQueue === original.dispatchQueue)

        // Changing the copy does not change the original
        copy.batchSize = 7
        copy.completionHandler = nil
        XCTAssertEqual(original.batchSize, 42)
        XCTAssertNotNil(original.completionHandler)
    }

    /// The directory of the database file is created when it is missing, so the database can be opened.
    func testCreateParentDirectoryOfDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aware_dir_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("nested/Documents/a.sqlite").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        try SQLiteEngine.createParentDirectory(ofDatabaseAt: path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("nested/Documents").path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNoThrow(try DatabaseQueue(path: path))

        // An existing directory is left as it is
        XCTAssertNoThrow(try SQLiteEngine.createParentDirectory(ofDatabaseAt: path))
    }

    /// `fetch` returns rows in ID order even when SQLite returns unordered rows in another order.
    /// `PRAGMA reverse_unordered_selects` makes SQLite reverse every SELECT without ORDER BY.
    func testFetchReturnsRowsInIdOrder() throws {
        guard let engine = makeEmptySQLiteEngine("fetch_order_test"), let queue = engine.getSQLiteInstance() else {
            return XCTFail("SQLite engine is not available")
        }
        engine.save((0..<10).map { i in sample(at: Int64(1_000 + i)) } as [any BaseDbModelSQLite])
        let all = ids(engine)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA reverse_unordered_selects = ON") }
        defer {
            try? queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA reverse_unordered_selects = OFF") }
            engine.removeAll()
        }

        // The sync's query: the next batch must be the lowest IDs above the marker, in order
        let batch = (engine.fetch(filter: "id > \(all[1])", limit: 3) ?? []).compactMap { $0["id"] as? Int64 }
        XCTAssertEqual(batch, Array(all[2...4]))
        let first = (engine.fetch(filter: nil, limit: 2) ?? []).compactMap { $0["id"] as? Int64 }
        XCTAssertEqual(first, Array(all[0...1]))

        // A filter with its own ORDER BY keeps it (no second ORDER BY is added)
        let latest = (engine.fetch(filter: "timestamp >= 1003 ORDER BY timestamp DESC", limit: 2) ?? [])
            .compactMap { $0["timestamp"] as? Int64 }
        XCTAssertEqual(latest, [1009, 1008])
        let lowercase = (engine.fetch(filter: "timestamp >= 0 order  by timestamp desc", limit: 1) ?? [])
            .compactMap { $0["timestamp"] as? Int64 }
        XCTAssertEqual(lowercase, [1009])
    }

    func testContainsOrderBy() {
        XCTAssertFalse(SQLiteEngine.containsOrderBy(nil))
        XCTAssertFalse(SQLiteEngine.containsOrderBy("id > 10"))
        XCTAssertFalse(SQLiteEngine.containsOrderBy("label = 'border'"))
        XCTAssertTrue(SQLiteEngine.containsOrderBy("timestamp >= 0 ORDER BY timestamp DESC"))
        XCTAssertTrue(SQLiteEngine.containsOrderBy("id > 0 order\nby id"))
    }

    /// Makes a SQLite engine with an empty table `A` in its own database file.
    private func makeEmptySQLiteEngine(_ dbPath: String) -> SQLiteEngine? {
        let sensor = AwareSensor()
        let config = SensorConfig()
        config.dbHost = "node.awareframework.com:1001"
        config.dbType = .sqlite
        config.dbPath = dbPath
        config.dbTableName = A.databaseTableName
        sensor.initializeDbEngine(config: config)
        guard let engine = sensor.dbEngine as? SQLiteEngine, let queue = engine.getSQLiteInstance() else { return nil }
        A.createTable(queue: queue)
        engine.removeAll()
        return engine
    }

    private func sample(at timestamp: Int64) -> A {
        var a = getSmapleData()
        a.timestamp = timestamp
        return a
    }

    private func ids(_ engine: Engine) -> [Int64] {
        (engine.fetch(filter: nil, limit: nil) ?? []).compactMap { $0["id"] as? Int64 }.sorted()
    }

    /// With the default (keep one day), only uploaded rows older than a day are deleted.
    /// Recent uploaded rows and rows that have not been uploaded (even old ones) stay.
    func testRemoveUploadedCandidatesKeepsRecentData() {
        guard let engine = makeEmptySQLiteEngine("keep_data_after_sync_test") else {
            return XCTFail("SQLite engine is not available")
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let twoDaysAgo = now - 2 * 86_400_000
        let rows: [any BaseDbModelSQLite] = (0..<3).map { _ in sample(at: twoDaysAgo) }  // uploaded, old
            + (0..<3).map { _ in sample(at: now) }                                       // uploaded, recent
            + (0..<2).map { _ in sample(at: twoDaysAgo) }                                // not uploaded, old timestamp
        engine.save(rows)
        let all = ids(engine)
        XCTAssertEqual(all.count, 8)

        let helper = DbSyncHelper(engine: engine, host: "node.awareframework.com:1001",
                                  tableName: A.databaseTableName, config: DbSyncConfig())
        helper.idOfLastCandidate = all[5]  // rows up to the 6th were uploaded
        helper.removeUploadedCandidates(lastUploadedId: all[2], limit: 1000)

        XCTAssertEqual(ids(engine), Array(all[3...]))
        engine.removeAll()
    }

    /// Uploaded rows are deleted a chunk at a time, and no more than `maxChunks` chunks per call.
    func testRemoveUploadedDeletesInChunks() {
        guard let engine = makeEmptySQLiteEngine("remove_uploaded_chunks_test") else {
            return XCTFail("SQLite engine is not available")
        }
        engine.save((0..<12).map { _ in sample(at: 1_000) } as [any BaseDbModelSQLite])
        let all = ids(engine)

        XCTAssertEqual(engine.removeUploaded(upToId: all[11], olderThan: 2_000, chunkSize: 5, maxChunks: 2), 10)
        XCTAssertEqual(ids(engine), Array(all[10...]))
        XCTAssertEqual(engine.removeUploaded(upToId: all[11], olderThan: 2_000, chunkSize: 5, maxChunks: 2), 2)
        XCTAssertEqual(engine.count(filter: nil), 0)
        engine.removeAll()
    }

    func testSyncHelpers () {
        
        
        let sensor = AwareSensor()
        let config = SensorConfig()
        config.dbHost = "node.awareframework.com:1001"
        config.dbType = .sqlite
        config.debug  = true
        config.dbPath = "a"
        config.dbTableName = A.databaseTableName
        
        XCTAssertTrue(config.verify())

        sensor.initializeDbEngine(config: config )
        
        
        guard let query = (sensor.dbEngine as! SQLiteEngine).getSQLiteInstance() else { return  }
        A.createTable(queue: query)
        
        if let engine = sensor.dbEngine {
            var data: [any BaseDbModelSQLite] = []
            for _ in 0..<24 {
                data.append(getSmapleData())
            }
            engine.save(data)
        }
        
        let expectation = XCTestExpectation.init(description: "sync task")
        let helperConfig = DbSyncConfig().apply{setting in
            setting.batchSize = 5
            setting.removeAfterSync = true
            setting.debug = true
            setting.test = true
            setting.compactDataFormat = false
            setting.dispatchQueue = DispatchQueue(label: "com.awareframework.ios.sensor.core.syncTask")
        }
        let helper = DbSyncHelper.init(engine: sensor.dbEngine!,
                                         host: config.dbHost!,
                                    tableName: A.databaseTableName,
                                       config: helperConfig)
        helper.createHttpRequestBodyHandler = { body in
            print(body)
            return body
        }
        
        helper.run(completion: { (status, error) in
            XCTAssertTrue(status)
            XCTAssertNil(error)
            expectation.fulfill()
        })

        self.wait(for: [expectation], timeout: 180)
        
    }

    
    func testDbSyncManager(){
        
        let interval:Double = 0.5
        let expectation = self.expectation(description: "DbSyncNotificationExpectation_" + String(interval))
        
        let syncManager =
            DbSyncManager.Builder()
            .setWifiOnly(false)
            .setWifiOnly(false)
            .setSyncInterval(interval)
            .build()
        
        syncManager.start()
        
        // Observe the sync notification
        NotificationCenter.default.addObserver(forName: Notification.Name.Aware.dbSyncRequest,
                                               object: nil,
                                               queue: .main) { (notification) in
            print(notification)
            expectation.fulfill()
            XCTAssertNoThrow(notification)
        }
        // Wait 60 + 10 second
        wait(for: [expectation], timeout: 60+10)
        
        // test ignoring a wrong interval value
        let syncManager2 = DbSyncManager.Builder().setSyncInterval(-1).build()
        XCTAssertEqual(syncManager2.CONFIG.syncInterval, 1.0)

    }
    
    func testCommonUUID(){
        
        UserDefaults.standard.removeObject(forKey: "com.aware.ios.sensor.core.key.deviceid")
        
        // The key is saved on iCloud
        let uuid = AwareUtils.getCommonDeviceId()
        for _ in 0..<10 {
            if(uuid == AwareUtils.getCommonDeviceId()){
                XCTAssertNoThrow(uuid)
            }else{
                XCTAssertThrowsError(uuid)
            }
        }
    }
    
    func testAwareObjectDefaultValues(){
        let awareObject = A.init()
        XCTAssertGreaterThanOrEqual(awareObject.timestamp,0)
        XCTAssertEqual(awareObject.deviceId, AwareUtils.getCommonDeviceId())
        XCTAssertEqual(awareObject.label, "")
        XCTAssertEqual(awareObject.timezone, AwareUtils.getTimeZone())
        XCTAssertEqual(awareObject.os, "ios")
        
        let dict = awareObject.toDictionary()
        XCTAssertNotNil(dict)
        
        XCTAssertEqual(dict["timestamp"] as! Int64, awareObject.timestamp)
        XCTAssertEqual(dict["deviceId"] as! String, awareObject.deviceId)
        XCTAssertEqual(dict["label"] as! String, awareObject.label)
        XCTAssertEqual(dict["timezone"] as! Int, awareObject.timezone)
        XCTAssertEqual(dict["os"] as! String, awareObject.os)
        XCTAssertEqual(dict["jsonVersion"] as! Int, awareObject.jsonVersion)
         
    }
    
    func testSensorManager(){
        let manager = SensorManager.shared
        let sensor = AwareSensor()
        sensor.id = "sample"
        sensor.start()
        sensor.stop()
        sensor.enable()
        sensor.enable()
        sensor.disable()
        sensor.set(label: "label")
        sensor.sync(force: false)
        manager.addSensor(sensor)
        XCTAssertEqual(sensor, manager.getSensor(with: sensor.id)!)
        XCTAssertEqual(sensor, manager.getSensor(with: sensor)!)
        XCTAssertTrue(manager.isExist(with: "sample"))
        XCTAssertTrue(manager.isExist(with: sensor.classForCoder) )
        manager.removeSensor(id: "sample")
        XCTAssertFalse(manager.isExist(with: "sample"))
        XCTAssertFalse(manager.isExist(with: sensor.classForCoder) )
        XCTAssertEqual(manager.sensors.count, 0)
        XCTAssertNil(manager.getSensor(with: "sample"))
        XCTAssertNil(manager.getSensor(with: sensor))
        XCTAssertNil(manager.getSensors(with: sensor.classForCoder))
        
        let sensor2 = AwareSensor()
        manager.addSensors([sensor,sensor2])
        XCTAssertEqual(manager.sensors.count, 2)
        manager.removeSensors(with: AwareSensor.classForCoder())
        XCTAssertEqual(manager.sensors.count, 0)
        
        manager.startAllSensors()
        manager.stopAllSensors()
    }
}


class SensorTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
        
        for dbName in ["accelerometer.sqlite"] {
            removeDatabases(dbName)
        }
    }

    func removeDatabases(_ dbName:String){
        // remove old database
        let documentDirFileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last!
        let url = documentDirFileURL.appendingPathComponent(dbName)
        do {
            try FileManager.default.removeItem(at: url)
        }catch{
            print(error)
        }
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testSensorInitWithSQLiteEngine(){
        initAndRunSensor(dbType: .sqlite)
    }
    
    func initAndRunSensor(dbType:DatabaseType){
        let sensor = AccelerometerSensor(AccelerometerSensor.Config.init().apply(closure: { config in
            config.frequency = 100
            config.dbType = dbType
            config.debug = true
            config.dbPath = "accelerometer"
            config.dbTableName = AccelerometerDbModelSQLite.databaseTableName
        }))
        
        if let sqliteEngine = sensor.dbEngine as? SQLiteEngine {
            if let queue = sqliteEngine.getSQLiteInstance() {
                AccelerometerDbModelSQLite.createTable(queue: queue)
            }
        }
        
        sensor.start()
        
        let dbExpect = XCTestExpectation.init(description: "sensing test")
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { timer in
            sensor.stop()
//            // XCTAssertEqual((results2 ?? []).count, 200)
            let results = sensor.dbEngine?.fetch(filter: nil, limit: nil)
            XCTAssertGreaterThan((results ?? []).count, 0)
            
            dbExpect.fulfill()
        }
        wait(for: [dbExpect], timeout: 10)
    }
}

extension Notification.Name {
    public static let actionAwareAccelerometer      = Notification.Name(AccelerometerSensor.ACTION_AWARE_ACCELEROMETER)
    public static let actionAwareAccelerometerStart = Notification.Name(AccelerometerSensor.ACTION_AWARE_ACCELEROMETER_START)
    public static let actionAwareAccelerometerStop  = Notification.Name(AccelerometerSensor.ACTION_AWARE_ACCELEROMETER_STOP)
    public static let actionAwareAccelerometerSetLabel  = Notification.Name(AccelerometerSensor.ACTION_AWARE_ACCELEROMETER_SET_LABEL)
    public static let actionAwareAccelerometerSync  = Notification.Name(AccelerometerSensor.ACTION_AWARE_ACCELEROMETER_SYNC)
    public static let actionAwareAccelerometerSyncCompletion  = Notification.Name(AccelerometerSensor.ACTION_AWARE_ACCELEROMETER_SYNC_COMPLETION)
}


extension AccelerometerSensor {
    /// keys ///
    static let ACTION_AWARE_ACCELEROMETER       = "com.awareframework.ios.sensor.accelerometer"
    static let ACTION_AWARE_ACCELEROMETER_START = "com.awareframework.ios.sensor.accelerometer.ACTION_AWARE_ACCELEROMETER_START"
    static let ACTION_AWARE_ACCELEROMETER_STOP  = "com.awareframework.ios.sensor.accelerometer.ACTION_AWARE_ACCELEROMETER_STOP"
    static let ACTION_AWARE_ACCELEROMETER_SYNC  = "com.awareframework.ios.sensor.accelerometer.ACTION_AWARE_ACCELEROMETER_SYNC"
    static let ACTION_AWARE_ACCELEROMETER_SYNC_COMPLETION = "com.awareframework.ios.sensor.accelerometer.ACTION_AWARE_ACCELEROMETER_SYNC_SUCCESS_COMPLETION"
    static let ACTION_AWARE_ACCELEROMETER_SET_LABEL = "com.awareframework.ios.sensor.accelerometer.ACTION_AWARE_ACCELEROMETER_SET_LABEL"
    static var EXTRA_LABEL  = "label"
    static let TAG = "com.awareframework.ios.sensor.accelerometer"
    static let EXTRA_STATUS = "status"
    static let EXTRA_ERROR = "error"
}

class AccelerometerSensor:AwareSensor {
    
    /// config ///
    public var CONFIG = AccelerometerSensor.Config()
    
    ////////////////////////////////////
    var timer:Timer?
    var dataBuffer = Array<AccelerometerDbModelSQLite>()
    
    public class Config:SensorConfig{
        public var frequency:Int    = 5 // Hz
        public var period:Double    = 0 // min
        
        public var threshold: Double = 0
        
        public override init() {
            super.init()
            self.dbPath = "aware_accelerometer"
            self.dbTableName = "accelerometer"
        }
        
        public override func set(config: Dictionary<String, Any>) {
            super.set(config: config)
            if let period = config["period"] as? Double {
                self.period = period
            }
            
            if let threshold = config ["threshold"] as? Double {
                self.threshold = threshold
            }
            
            if let frequency = config["frequency"] as? Int {
                self.frequency = frequency
            }
        }
        
        public func apply(closure: (_ config: AccelerometerSensor.Config ) -> Void) -> Self {
            closure(self)
            return self
        }

    }
    
    public override convenience init() {
        self.init(AccelerometerSensor.Config())
    }
    
    public init(_ config:AccelerometerSensor.Config) {
        super.init()
        self.CONFIG = config
        self.initializeDbEngine(config: config)
        if config.debug {
            print(AccelerometerSensor.TAG,"Accelerometer sensor is created.")
            if !config.verify() {
                print(AccelerometerSensor.TAG, "Invalid configuration")
            }
        }
    }
    
    /**
     * Start accelerometer sensor module
     */
    public override func start() {

        // Configure a timer to fetch the data.
        self.timer = Timer(fire: Date(),
                           interval: 1.0/Double(CONFIG.frequency),
                           repeats: true, block: { (timer) in
            // Get the accelerometer data.
           
            let x = 1.0
            let y = 2.0
            let z = 3.0

            let data = AccelerometerDbModelSQLite(x: x, y: y, z: z)
            self.dataBuffer.append(data)
            ////////////////////////////////////////
            ///
            if self.dataBuffer.count < 100 {
                return
            }
            
            let dataArray: [any BaseDbModelSQLite] = Array(self.dataBuffer)
            OperationQueue().addOperation({ () -> Void in
                self.dbEngine?.save(dataArray){ error in
                    if error != nil {
                        if self.CONFIG.debug {
                            print(AccelerometerSensor.TAG, error.debugDescription)
                        }
                        return
                    }
                    // send notification in the main thread
                    DispatchQueue.main.async {
                        self.notificationCenter.post(name: .actionAwareAccelerometer , object: self)
                    }
                }
            })
            
            self.dataBuffer.removeAll()
            
        })
        
        // Add the timer to the current run loop.
        RunLoop.current.add(self.timer!, forMode: RunLoop.Mode.default)
        
        if self.CONFIG.debug { print(AccelerometerSensor.TAG, "Accelerometer sensor active: \(self.CONFIG.frequency) hz") }
        self.notificationCenter.post(name: .actionAwareAccelerometerStart, object: self)
    }
    

    /**
     * Stop accelerometer sensor module
     */
    public override func stop() {
       
        if let timer = self.timer {
            timer.invalidate()
            if self.CONFIG.debug { print(AccelerometerSensor.TAG, "Accelerometer service is terminated...") }
        }
    
    }

    /**
     * Sync accelerometer sensor module
     */
    public override func sync(force: Bool = false) {
        if let engine = self.dbEngine {
            engine.startSync(DbSyncConfig().apply(closure: { config in
                config.serverType = config.serverType
                config.debug = true
                config.batchSize = 100
                config.dispatchQueue = DispatchQueue(label: "com.awareframework.ios.sensor.accelerometer.sync.queue")
                config.completionHandler = { (status, error) in
                    var userInfo: Dictionary<String,Any> = [AccelerometerSensor.EXTRA_STATUS :status]
                    if let e = error {
                        userInfo[AccelerometerSensor.EXTRA_ERROR] = e
                    }
                    self.notificationCenter.post(name: .actionAwareAccelerometerSyncCompletion ,
                                                 object: self,
                                                 userInfo:userInfo)
                }
            }))
            self.notificationCenter.post(name: .actionAwareAccelerometerSync, object: self)
        }
    }
    
    /**
     * Set a label for a data
     */
    public override func set(label:String){
        self.CONFIG.label = label
        self.notificationCenter.post(name: .actionAwareAccelerometerSetLabel, object: self, userInfo: [AccelerometerSensor.EXTRA_LABEL:label])
    }
}


struct AccelerometerDbModelSQLite: Codable, BaseDbModelSQLite {

    var id: Int64?
    var timestamp: Int64
    var deviceId: String
    var label: String
    var timezone: Int
    var os: String
    var jsonVersion: Int
    var x: Double
    var y: Double
    var z: Double
    
    init(x:Double, y:Double, z:Double){
        self.timestamp = Int64(Date().timeIntervalSince1970*1000)
        self.timezone = AwareUtils.getTimeZone()
        self.os = "ios"
        self.jsonVersion = 0
        self.label = ""
        self.deviceId = AwareUtils.getCommonDeviceId()
        self.x = x
        self.y = y
        self.z = z
    }
    
    init(_ dict: Dictionary<String, Any>) {
        self.timestamp = dict["timestamp"] as? Int64 ?? 0
        self.timezone = dict["timezone"] as? Int ?? 0
        self.os = dict["os"] as? String ?? ""
        self.jsonVersion = dict["jsonVersion"] as? Int ?? -1
        self.label = dict["label"] as? String ?? ""
        self.x = dict["x"] as? Double ?? 0
        self.y = dict["y"] as? Double ?? 0
        self.z = dict["z"] as? Double ?? 0
        self.deviceId = dict["deviceId"] as? String ?? ""
    }
    
    func toDictionary() -> Dictionary<String, Any> {
        return [
            "id": self.id ?? -1,
            "timestamp":timestamp,
            "deviceId":deviceId,
            "label":label,
            "timezone": timezone,
            "os":os,
            "jsonVersion":jsonVersion,
            "x":x,
            "y":y,
            "z":z
        ]
    }
    
    static func createTable(queue: DatabaseQueue){
        do {
            try queue.write { db in
                try db.create(table: AccelerometerDbModelSQLite.databaseTableName) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("deviceId", .text).notNull()
                    t.column("timestamp", .integer).notNull()
                    t.column("os", .text).notNull()
                    t.column("timezone", .integer).notNull()
                    t.column("label", .text).notNull()
                    t.column("jsonVersion", .integer).notNull()
                    t.column("x", .double).notNull()
                    t.column("y", .double).notNull()
                    t.column("z", .double).notNull()
                }
            }
        } catch {
            print(error)
        }
    }
    
    // 独自のテーブル名を指定
    static var databaseTableName: String {
        return "accelerometer"
    }
}
