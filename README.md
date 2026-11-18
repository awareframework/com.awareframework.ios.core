# AWARE: Core

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)

## Overview

`com.awareframework.ios.core` provides the foundational classes and utilities for building sensor modules on the AWARE framework for iOS/watchOS/macOS. It includes:

- Base sensor class (`AwareSensor`) and configuration model (`SensorConfig`)
- SQLite-backed storage engine (`SQLiteEngine`) via GRDB with connection pooling, WAL mode, and retry logic
- HTTP batch sync helper (`DbSyncHelper`) for uploading sensor data to AWARE servers
- Direct MySQL sync client (`MySQLDirectClient`) for TCP-level database sync
- Sensor registry (`SensorManager`) and periodic sync orchestrator (`DbSyncManager`)
- Schema inspection and CSV/snapshot export utilities

## Requirements

- iOS 13 or later
- watchOS 7 or later
- macOS 10.15 or later

## Installation

All AWARE iOS packages are distributed via Swift Package Manager (SwiftPM). Every app needs this core package plus one package per sensor.

| | |
|---|---|
| Requirements | iOS 13+ (also watchOS 7+, macOS 10.15+) |
| Core package | `https://github.com/awareframework/com.awareframework.ios.core.git` |
| Sensor packages | `https://github.com/awareframework/com.awareframework.ios.sensor.<name>.git` (e.g. `locations`, `accelerometer`, `esm`) |
| Product (library) name | Same as the package name, e.g. `com.awareframework.ios.core`, `com.awareframework.ios.sensor.locations` |
| Module to import | Same as the product name, e.g. `import com_awareframework_ios_core`. Swift replaces `.` with `_` in module names |

Sensor packages depend on this core package, so SwiftPM resolves core automatically. Add core explicitly anyway when your code uses its types directly (`DbSyncManager`, `DbSyncConfig`, and so on), and keep all AWARE packages on compatible versions.

### Option 1: Xcode

1. Open `File` → `Add Package Dependencies...`.
2. Enter a package URL from the table above and choose a version rule (e.g. *Up to Next Major Version*).
3. Add the product to your app target.
4. Repeat for each sensor package.

### Option 2: `Package.swift`

To use AWARE from your own Swift package:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyStudy",
    platforms: [.iOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/awareframework/com.awareframework.ios.core.git", from: "1.6.0"),
        .package(url: "https://github.com/awareframework/com.awareframework.ios.sensor.locations.git", from: "1.6.1"),
    ],
    targets: [
        .target(
            name: "MyStudy",
            dependencies: [
                .product(name: "com.awareframework.ios.core", package: "com.awareframework.ios.core"),
                .product(name: "com.awareframework.ios.sensor.locations", package: "com.awareframework.ios.sensor.locations"),
            ]
        ),
    ]
)
```

### Option 3: Command line (existing `.xcodeproj`, without the Xcode UI)

This option is for CI and coding agents. Xcode has no command for adding a package to a `.xcodeproj`, so you need to edit `project.pbxproj` directly. Each package needs four entries. Object IDs must be unique 24-character hexadecimal strings; the IDs below are placeholders.

```text
/* 1. PBXBuildFile section: link the product in the Frameworks build phase */
C0110000000000000000000A /* com.awareframework.ios.core in Frameworks */ = {isa = PBXBuildFile; productRef = C0210000000000000000000A /* com.awareframework.ios.core */; };

/* 2. In the app target's PBXFrameworksBuildPhase `files`, and in the PBXNativeTarget */
files = ( C0110000000000000000000A /* com.awareframework.ios.core in Frameworks */, );
packageProductDependencies = ( C0210000000000000000000A /* com.awareframework.ios.core */, );

/* 3. In the PBXProject object */
packageReferences = ( C0310000000000000000000A /* XCRemoteSwiftPackageReference "com.awareframework.ios.core" */, );

/* 4. New sections */
/* Begin XCRemoteSwiftPackageReference section */
C0310000000000000000000A /* XCRemoteSwiftPackageReference "com.awareframework.ios.core" */ = {
    isa = XCRemoteSwiftPackageReference;
    repositoryURL = "https://github.com/awareframework/com.awareframework.ios.core";
    requirement = {
        kind = upToNextMajorVersion;
        minimumVersion = 1.6.0;
    };
};
/* End XCRemoteSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
C0210000000000000000000A /* com.awareframework.ios.core */ = {
    isa = XCSwiftPackageProductDependency;
    package = C0310000000000000000000A /* XCRemoteSwiftPackageReference "com.awareframework.ios.core" */;
    productName = com.awareframework.ios.core;
};
/* End XCSwiftPackageProductDependency section */
```

Repeat entries 1–4 for each sensor package with new IDs. To pin an exact version, use `kind = exactVersion; version = 1.6.0;`.

### Verify the installation

```sh
xcodebuild -resolvePackageDependencies -project MyApp.xcodeproj -scheme MyApp
xcodebuild -project MyApp.xcodeproj -scheme MyApp -sdk iphonesimulator build
```

The first command prints the resolved AWARE packages and their versions. Then confirm that `import com_awareframework_ios_core` compiles.

### Permissions and capabilities

The core package itself requires no Info.plist keys. Sensors that access protected resources do. For example, `com.awareframework.ios.sensor.locations` needs `NSLocationWhenInUseUsageDescription` and `NSLocationAlwaysAndWhenInUseUsageDescription`, plus the `location` background mode (`UIBackgroundModes`) to record in the background. See each sensor's README for the keys it needs, and add only those.

## Architecture

### Key Components

| Component | Description |
|-----------|-------------|
| `AwareSensor` | Base class for all AWARE sensors. Manages DB engine lifecycle and sync notifications. |
| `SensorConfig` | Per-sensor configuration: DB type/path/host, server type, study key, encryption key. |
| `Engine` / `SQLiteEngine` | Abstract storage engine; `SQLiteEngine` is the GRDB-backed SQLite implementation. |
| `DbSyncHelper` | Incremental HTTP batch uploader. Tracks last uploaded ID in `UserDefaults`. |
| `DbSyncConfig` | Sync tuning: batch size, server type, progress/completion handlers, debug level. |
| `MySQLDirectClient` | Direct TCP MySQL client for pushing SQLite snapshots without an HTTP intermediary. |
| `DbSyncManager` | Timer-based periodic sync orchestrator with Wi-Fi / charging-only guards. |
| `SensorManager` | Singleton registry for all active sensors. |
| `BaseDbModelSQLite` | Protocol all sensor data models must conform to (GRDB `PersistableRecord`). |

---

## Example Usage

### 1. Define a data model

```swift
struct AccelerometerData: BaseDbModelSQLite {
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

    static var databaseTableName: String { "accelerometer" }

    static func createTable(queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.create(table: databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .integer)
                t.column("deviceId", .text)
                // ...
            }
        }
    }
    // ...
}
```

### 2. Configure and start a sensor

```swift
let config = SensorConfig()
config.dbTableName = "accelerometer"
config.dbHost      = "your.aware-server.com"
config.serverType  = .aware_micro
config.studyKey    = "my-study-key"

let sensor = MyAccelerometerSensor()
sensor.initializeDbEngine(config: config)
sensor.start()
sensor.enable()   // subscribes to sync broadcast
```

### 3. Configure sync

```swift
let syncConfig = DbSyncConfig()
syncConfig.batchSize        = 500
syncConfig.removeAfterSync  = true
syncConfig.keepPeriod       = .day   // or keepDataAfterSync = 86400 (seconds)
syncConfig.compactDataFormat = false
syncConfig.debug            = true
syncConfig.debugLevel       = .verbose
syncConfig.progressHandler  = { progress, error in
    print("Sync progress: \(Int(progress * 100))%")
}
syncConfig.completionHandler = { success, error in
    print("Sync finished: \(success)")
}
```

### 4. Periodic sync with DbSyncManager

```swift
let syncManager = DbSyncManager.Builder()
    .setSyncInterval(15)        // every 15 minutes
    .setWifiOnly(true)
    .setBatteryOnly(false)
    .addSensors([sensor])
    .build()

syncManager.start()
// syncManager.stop() to cancel
```

### 5. Direct MySQL sync

```swift
let mysqlConfig = MySQLDirectSyncConfig(
    host: "db.example.com",
    port: 3306,
    database: "aware_data",
    username: "user",
    password: "pass"
)

if let engine = sensor.dbEngine as? SQLiteEngine {
    Task {
        let result = try await engine.syncAllTablesToMySQL(config: mysqlConfig)
        print("Inserted \(result.insertedRows) rows")
    }
}
```

---

## Connecting to a Server

### Upload URL

Each table is uploaded with HTTPS `POST` requests to a URL built from the server type, the host, the study number and the study key:

| `ServerType` | Upload URL | Request body |
|---|---|---|
| `.aware_micro` | `https://{host}/api/{studyNumber}/{studyKey}/insert/` | JSON |
| `.aware_light` | `https://{host}/insert/` (`id` is removed from each row) | JSON |
| `.aware` | `https://{host}/index.php/webservice/index/{studyNumber}/{studyKey}/{tableName}/insert` | form (`device_id`, `data`) |
| `.none` | No remote sync | — |

- `host` is the host name with an optional port, e.g. `aware.example.com` or `localhost:8443`. A leading `http://` or `https://` is removed, and requests always use HTTPS.
- The study key and the table name are percent-encoded in the path.
- TLS certificate validation stays on. Use a certificate the device trusts.

### Setting the host, study number and study key

The **host** is set per sensor, with `SensorConfig.dbHost`. Sync does not start for a sensor whose `dbHost` is `nil`.

Sensor packages build their own `DbSyncConfig` for each table, and the **study number, study key and server type** of that config come from the static defaults on `DbSyncConfig`. Set them once at launch, before starting the sensors:

```swift
import com_awareframework_ios_core
import com_awareframework_ios_sensor_locations

// 1. Study (read by every sensor's sync)
DbSyncConfig.defaultServerType  = .aware_micro
DbSyncConfig.defaultStudyNumber = 1
DbSyncConfig.defaultStudyKey    = "my-study-key"

// 2. Host (per sensor). Setting the same values on the sensor config keeps them consistent.
let locations = LocationsSensor(LocationsSensor.Config().apply { c in
    c.dbHost      = "aware.example.com"
    c.serverType  = .aware_micro
    c.studyNumber = 1
    c.studyKey    = "my-study-key"
})
locations.start()
```

---

## DbSyncManager Reference

`DbSyncManager` triggers sync on a timer. Each tick posts a sync request (`Notification.Name.Aware.dbSyncRequest`) unless a guard below blocks it, and every **enabled** sensor uploads its tables. A sensor is enabled with `sensor.enable()` or `SensorManager.shared.enableAllSensors()`; `start()` alone does not enable sync.

| Setting (`DbSyncManagerConfig`) | Builder method | Default | Description |
|---|---|---|---|
| `syncInterval: Double` | `setSyncInterval(_ minutes:)` | `1.0` | Interval between syncs, in **minutes**. Values ≤ 0 are ignored. |
| `wifiOnly: Bool` | `setWifiOnly(_:)` | `true` | Skip a tick when the connection is cellular or unavailable. |
| `batteryChargingOnly: Bool` | `setBatteryOnly(_:)` | `false` | Skip a tick unless the device is charging or full. |
| `debug: Bool` | — | `false` | Enable debug logging. |
| `debugLevel: DbSyncDebugLevel` | — | `.info` | Log verbosity. |
| `sensors: [AwareSensor]` | `addSensor(_:)`, `addSensors(_:)`, `remove(_:)` | `[]` | Sensors registered with the manager. |

| Method | Description |
|---|---|
| `start()` | Starts the timer. The first sync happens after one interval, not immediately. |
| `stop()` | Stops the timer. |
| `sync(_ force: Bool = false)` | Requests a sync now. `force: true` ignores `wifiOnly` and `batteryChargingOnly`. |

```swift
let syncManager = DbSyncManager.Builder()
    .setSyncInterval(30)     // every 30 minutes
    .setWifiOnly(true)
    .build()
SensorManager.shared.addSensor(locations)
SensorManager.shared.enableAllSensors()   // subscribe the sensors to sync requests
syncManager.start()

// Upload immediately, regardless of the network type
SensorManager.shared.syncAllSensors(force: true)
```

---

## DbSyncConfig Reference

Per-table upload settings, used by `DbSyncHelper`.

| Setting | Default | Description |
|---|---|---|
| `serverType: ServerType` | `DbSyncConfig.defaultServerType` (`.aware_micro`) | Server protocol; selects the upload URL (see [Upload URL](#upload-url)). |
| `studyNumber: Int` | `DbSyncConfig.defaultStudyNumber` (`1`) | Study number in the upload URL. |
| `studyKey: String` | `DbSyncConfig.defaultStudyKey` (`""`) | Study key in the upload URL. |
| `batchSize: Int` | `1000` | Rows per upload request. Larger backlogs are sent in several requests in one sync. |
| `removeAfterSync: Bool` | `true` | Delete uploaded rows from the local database once they are older than `keepDataAfterSync`. Rows that have not been uploaded are never deleted. Set `false` to keep every row. |
| `keepDataAfterSync: TimeInterval` | `86400` (one day) | Seconds to keep uploaded rows on the device, counted from each row's `timestamp`. `0` deletes them right after upload. Negative values are ignored. Dictionary key: `"keepDataAfterSync"`. |
| `keepPeriod: DbSyncConfig.KeepPeriod?` | `.day` | `keepDataAfterSync` as a period: `.immediately` (0), `.hour`, `.day`, `.week`, `.month` (30 days). Setting it sets `keepDataAfterSync`; reading it gives `nil` for other values. Dictionary key: `"keepPeriod"` (e.g. `"week"`). |
| `compactDataFormat: Bool` | `DbSyncConfig.defaultCompactDataFormat` (`false`) | Send columns as arrays, and omit `os`, `jsonVersion`, `deviceId` and `timezone`, to reduce payload size. |
| `backgroundSession: Bool` | `false` | Use a background `URLSession` (`URLSessionConfiguration.background`). |
| `debug: Bool` | `false` | Enable debug logging. |
| `debugLevel: DbSyncDebugLevel` | `.info` | Log verbosity: `.none`, `.error`, `.warning`, `.info`, `.verbose`, `.trace`. |
| `progressHandler: (Double, Error?) -> Void` | `nil` | Called during upload with progress from 0.0 to 1.0. |
| `completionHandler: (Bool, Error?) -> Void` | `nil` | Called when the sync of the table finishes. |
| `dispatchQueue: DispatchQueue?` | `nil` | Queue on which the next batch is scheduled. |
| `test: Bool` | `false` | Skip network calls and treat each batch as uploaded (unit tests only). |
| `markAsSynced`, `skipSyncedData`, `keepLastData: Bool` | `false` | Reserved. `DbSyncHelper` does not currently use them. Use `removeAfterSync` to delete uploaded rows. |
| `deviceId: String?` | `nil` | Reserved. Rows carry the device ID from `SensorConfig.deviceId`. |

`copy()` returns a new `DbSyncConfig` with the same values (handlers and the queue are shared). A sensor that uploads several tables should start each table's config from `syncConfig.copy()` and then change only what differs per table, such as `completionHandler` and `dispatchQueue`, so that no setting is lost.

All settings can also be given as a dictionary with `DbSyncConfig(_:)` or `set(config:)`, e.g. `["batchSize": 500, "studyKey": "my-study-key"]`.

---

## Sync Guarantees

`DbSyncHelper` uploads each table incrementally:

1. **Progress is tracked by row ID.** Every table of every database stores the ID of the last row uploaded successfully in `UserDefaults` (see [Sync markers](#sync-markers)). A sync sends rows with `id` greater than that value, in batches of `batchSize`, in ID order.
2. **Only HTTP 2xx counts as success.** The last uploaded ID advances (and, with `removeAfterSync`, uploaded rows older than `keepDataAfterSync` are deleted) only after the server answers with a 2xx status.
3. **Failed rows are retried.** On a non-2xx status, a network error, or a timeout (30 s per request), the last uploaded ID does not change and the sync of that table stops. The same rows are sent again at the next sync. Nothing is lost while the server is down, and the backlog is sent in batches once it is back.
4. **Uploaded rows are not sent again.** Rows at or below the last uploaded ID are never selected again, whether or not they are kept locally.
5. **Delivery is at least once.** If the server stores a batch but the response does not reach the app (for example, the app is killed while waiting), that batch is sent again at the next sync. Servers should tolerate duplicates, for example by ignoring rows with the same `timestamp` and device ID.
6. **One sync per table at a time.** When a sync is requested while another sync of the same table of the same database is running (for example, `DbSyncManager.sync()` followed by `sensor.sync(force: true)`), the running sync is not stopped. Stopping it would cancel a request that the server may already have stored, and its rows would be sent again. Instead, one more sync runs after the current one, however many requests were made meanwhile, and every completion handler is called. A sync with no activity for 330 s is treated as stopped, and the next request starts a new one.

The last uploaded ID survives app restarts. Deleting the app resets it.

### Removing uploaded rows

With `removeAfterSync`, each successful batch is followed by a cleanup of uploaded rows (`id` at or below the last uploaded ID) whose `timestamp` is older than now minus `keepDataAfterSync`. Rows saved while a request is in flight have larger IDs and are never deleted before they are uploaded. Rows are deleted oldest first, 5,000 per transaction and at most 50,000 per batch, so sensors can keep writing and a large backlog of old rows (for example, after updating from a version that did not delete) is cleared over several syncs instead of in one long transaction. Because the cutoff uses each row's `timestamp`, a device clock that jumps forward deletes uploaded rows earlier; rows that have not been uploaded are not affected.

### Sync markers

Each table of each database has its own marker. The key names the table and the database file, separated by a colon; the value is the ID of the last row uploaded (an integer):

```
aware.sync.task.last_uploaded_id.<tableName>:<database>
aware.sync.task.last_uploaded_id.ios_battery:aware_battery.sqlite            => 5230
aware.sync.task.last_uploaded_id.ios_battery_charge:aware_battery.sqlite     => 41
aware.sync.task.last_uploaded_id.ios_locations:aware_locations.sqlite        => 1532
```

`<database>` is the database file name: `dbPath` with `.sqlite` added when it is missing, so `aware_battery` and `aware_battery.sqlite` are the same database. Two databases with the same table name (for example, one database per study) keep separate markers.

Row IDs use AUTOINCREMENT and are never reused, even after rows are deleted. A marker larger than the largest ID the table ever assigned means that the database file was deleted and created again; the marker is then reset to 0, so the new rows are sent.

#### Markers from 1.6.1 and earlier

Up to 1.6.1 the key held only the table name (`aware.sync.task.last_uploaded_id.<tableName>`), so databases with the same table name shared one marker. On the first sync of each database, such a key is merged into the new format:

| Situation at the first sync of a database | Result |
|---|---|
| An old marker exists, and it is not larger than any row ID this database ever assigned | Its value is moved into `<tableName>:<database>`, and the old key is deleted. Upload continues where it stopped |
| An old marker exists, but it is larger than any row ID this database ever assigned | The old marker belongs to another database (for example, `dbPath` was renamed). This database starts from 0, and the old key is left for the database it belongs to |
| No old marker | This database starts from 0 |

Because the old key is deleted when it is moved, it is taken over by exactly one database. When two databases shared one marker before, the one that syncs first takes it over and the other starts from 0. Each move is logged (`[AWARE::Core] Moved sync marker ...`).

When it is unclear which database a marker belongs to, the smaller value is chosen: rows may be sent again (servers should drop duplicates, as above), but no row is skipped. An app version from 1.6.1 or earlier installed again over a newer one (possible with TestFlight or development builds, not from the App Store) no longer finds the old key and sends its rows again.

---

## SQLiteEngine Utilities

### Schema inspection

```swift
let tableNames = try engine.getAllTableNames()
let schema     = try engine.fetchTableSchema(tableName: "accelerometer")
let rows       = try engine.fetchTableRows(tableName: "accelerometer")
```

### Snapshots for export / MySQL push

```swift
// Single table
let snapshot = try engine.fetchTableSnapshot(tableName: "accelerometer")

// All tables
let snapshots = try engine.fetchTableSnapshots()

// Snapshot includes exportFileNameStem for CSV naming:
// "<dbPath>__<tableName>"
```

---

## DbSyncHelper — Sync Control

```swift
// Graceful stop (waits up to 30 s for in-flight requests)
syncHelper.stopGracefully(timeout: 30) { completed in }

// Immediate cancel
syncHelper.stopImmediately { }

// Query state
let state    = syncHelper.getCurrentSyncState()  // "idle" | "active" | ...
let progress = syncHelper.getCurrentProgress()    // 0.0–1.0
let stats    = syncHelper.getSyncStatistics()     // [String: Any]
```

---

## SensorManager

```swift
SensorManager.shared.addSensor(sensor)
SensorManager.shared.startAllSensors()
SensorManager.shared.syncAllSensors(force: true)
SensorManager.shared.stopAllSensors()
```

---

## BaseDbModelSQLite Fields

Every sensor data record must expose:

| Field | Type | Description |
|---|---|---|
| `id` | `Int64?` | Auto-increment primary key |
| `timestamp` | `Int64` | Unix epoch milliseconds |
| `deviceId` | `String` | Persistent device identifier |
| `label` | `String` | User-defined label |
| `timezone` | `Int` | Hours offset from UTC |
| `os` | `String` | Platform string |
| `jsonVersion` | `Int` | Schema version |

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.3.0 | SQLite ORM / query engine |
| [SwiftyJSON](https://github.com/SwiftyJSON/SwiftyJSON) | 5.0.2 | JSON parsing for server responses |
| [Reachability.swift](https://github.com/ashleymills/Reachability.swift) | 5.2.4 | Network reachability (iOS only) |

---

## Related Links

- [URLSession | Apple Developer Documentation](https://developer.apple.com/documentation/foundation/urlsession)
- [URLSessionConfiguration | Apple Developer Documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration)
- [Network | Apple Developer Documentation](https://developer.apple.com/documentation/network)
- [CryptoKit | Apple Developer Documentation](https://developer.apple.com/documentation/cryptokit)
- [Security | Apple Developer Documentation](https://developer.apple.com/documentation/security)
- [UIDevice | Apple Developer Documentation](https://developer.apple.com/documentation/uikit/uidevice)

---

## Author

Yuuki Nishiyama (The University of Tokyo), nishiyama@csis.u-tokyo.ac.jp

## License

Copyright (c) 2025 AWARE Mobile Context Instrumentation Middleware/Framework (http://www.awareframework.com)

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
