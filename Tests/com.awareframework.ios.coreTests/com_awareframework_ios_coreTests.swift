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
        XCTAssertFalse(config1.removeAfterSync)
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
        XCTAssertFalse(config3.removeAfterSync)
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
        engine.dictToModelHandler = { (data:Dictionary<String, Any>) -> Any in
            let obj = self.getSmapleData()
            return obj
        }
        engine.modelToDictHandler = {(data: Any) -> Dictionary<String, Any> in
            if let d = data as? A {
                return d.toDictionary()
            }
            return Dictionary()
        }
        print("Create a table in SQLite")
        if let e = engine as? SQLiteEngine {
            if let q = e.getSQLiteInstance() {
                A.createTable(queue: q)
            }
        }
        
        engine.save(self.getSmapleData().toDictionary())
        let results = engine.fetch(filter: nil, limit: nil)
        XCTAssertEqual((results ?? []).count, 1)
        
        
        var dicts:Array<Dictionary<String, Any>> = []
        for i in 0..<100 {
            print(i)
            dicts.append(self.getSmapleData().toDictionary())
        }
        engine.save(dicts)
        
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
            engine.dictToModelHandler = {dict in
                let model = A(dict)
                return model
            }
            
            engine.modelToDictHandler = {data in
                return (data as! A).toDictionary()
            }
            
            var data:Array<Dictionary<String, Any>> = []
            for _ in 0..<24 {
                data.append(getSmapleData().toDictionary())
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
        
        sensor.dbEngine?.dictToModelHandler = { dict in
            if sensor.CONFIG.dbType == .sqlite {
                let model = AccelerometerDbModelSQLite(dict)
                return model
            }
            return []
        }
        
        sensor.dbEngine?.modelToDictHandler = {model in
            if let model = model as? AccelerometerDbModelSQLite {
                return model.toDictionary()
            }
            
            return Dictionary<String, Any>()
            
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
    var dataBuffer  = Array<Dictionary<String, Any>>()
    
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
           
            let x = 1
            let y = 2
            let z = 3
            
            let currentTime:Double = Date().timeIntervalSince1970
            
            let data = [
                "timestamp":Int64(currentTime*1000),
                "x":x,
                "y":y,
                "z":z,
            ]
            
            self.dataBuffer.append(data)
            ////////////////////////////////////////
            ///
            if self.dataBuffer.count < 100 {
                return
            }
            
            let dataArray = Array(self.dataBuffer)
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
