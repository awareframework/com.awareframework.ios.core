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

Integrate this framework via Swift Package Manager (SwiftPM).

1. Open **Package Dependencies** in Xcode:
   `File` → `Add Package Dependencies...`

2. Enter the repository URL:
   `https://github.com/awareframework/com.awareframework.ios.core.git`

3. Add the package to your target.

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

## Usage

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

## Server Types

| `ServerType` | Endpoint pattern |
|---|---|
| `.aware` | Legacy AWARE PHP server (`/index.php/webservice/…`) |
| `.aware_micro` | AWARE Micro server (`/api/{studyNumber}/{studyKey}/insert/`) |
| `.aware_light` | AWARE Light server (`/insert/`), strips `id` from payload |
| `.none` | No remote sync |

---

## DbSyncConfig Reference

| Property | Type | Default | Description |
|---|---|---|---|
| `batchSize` | `Int` | `1000` | Records per upload batch |
| `removeAfterSync` | `Bool` | `false` | Delete local records after successful upload |
| `compactDataFormat` | `Bool` | `false` | Aggregate columns into arrays to reduce payload size |
| `backgroundSession` | `Bool` | `false` | Use `URLSessionConfiguration.background` |
| `serverType` | `ServerType` | `.aware_micro` | Target server protocol |
| `studyNumber` | `Int` | `1` | Study number embedded in upload URL |
| `studyKey` | `String` | `""` | Study key embedded in upload URL |
| `debug` | `Bool` | `false` | Enable debug logging |
| `debugLevel` | `DbSyncDebugLevel` | `.info` | Log verbosity: `.none` `.error` `.warning` `.info` `.verbose` `.trace` |
| `test` | `Bool` | `false` | Skip real network calls (unit test mode) |
| `progressHandler` | closure | `nil` | Called with `(Double, Error?)` during upload |
| `completionHandler` | closure | `nil` | Called with `(Bool, Error?)` on finish |
| `dispatchQueue` | `DispatchQueue?` | `nil` | Queue on which to run next-batch calls |

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

## Author

Yuuki Nishiyama (The University of Tokyo), nishiyama@csis.u-tokyo.ac.jp

## License

Copyright (c) 2025 AWARE Mobile Context Instrumentation Middleware/Framework (http://www.awareframework.com)

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
