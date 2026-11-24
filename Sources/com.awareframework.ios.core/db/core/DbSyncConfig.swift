/// Configuration class for database synchronization.
///
/// This class provides various configuration options for synchronizing data with a database.
/// It includes options for batch size, debug mode, and completion handlers.
///
/// - Properties:
///   - removeAfterSync: A boolean indicating whether to remove data after synchronization. Default is `true`.
///   - keepDataAfterSync: Seconds to keep uploaded data on the device before `removeAfterSync` deletes it. Default is one day (`86400`).
///   - keepPeriod: `keepDataAfterSync` as a period (`.immediately`, `.hour`, `.day`, `.week`, `.month`).
///   - batchSize: Rows read from the database at a time while a request is built. Default is `1000`.
///     (Up to 1.6, it was the number of rows per request. A request now holds as many rows as fit
///     in `maxBatchBytes`, up to `maxBatchRows`.)
///   - maxBatchBytes: Largest request body in bytes. `nil` (default) is 4 MB for every server type
///     (up to 1.7: 900 KB for servers other than AWARE Micro). A host that answers 413 gets a smaller
///     limit, which is remembered. See `SyncBatchLimit`.
///   - maxBatchBytesCeiling: Largest size `maxBatchBytes` may grow to after requests in a row that were
///     full and fast (see `SyncBatchLimit`). `nil` (default): 8 MB for every server type.
///   - maxBatchRows: Largest number of rows per request. Default is `20000`.
///   - prefetchNextBatch: Choose and build the next request while the current one is in flight, so the
///     server and the device work at the same time. Default is `true`.
///   - batchInterval: Shortest rest between requests, in seconds. Default is `0`. (1.6 waited 0.1 s.)
///   - cpuRestRatio: Rest between requests, as a multiple of the CPU time the last request took to
///     prepare, while the app is in the foreground. Default is `1` (the sync uses at most about half
///     of a CPU core). See `SyncPacing`.
///   - backgroundCpuRestRatio: The same while the app is in the background. Default is `3`.
///   - markAsSynced: A boolean indicating whether to mark data as synced after synchronization. Default is `false`.
///   - skipSyncedData: A boolean indicating whether to skip already synced data. Default is `false`.
///   - keepLastData: A boolean indicating whether to keep the last data after synchronization. Default is `false`.
///   - deviceId: An optional string representing the device ID.
///   - debug: A boolean indicating whether to enable debug mode. Default is `false`.
///   - completionHandler: An optional completion handler to be called after synchronization.
///   - progressHandler: An optional progress handler to be called during synchronization.
///   - dispatchQueue: An optional dispatch queue for synchronization tasks.
///   - backgroundSession: A boolean indicating whether to use a background session for synchronization. Default is `false`.
///   - compactDataFormat: A boolean indicating whether to use a compact data format for synchronization. Default is `true`.
///
/// - Methods:
///   - init(): Initializes a new instance of `DbSyncConfig` with default values.
///   - init(_:): Initializes a new instance of `DbSyncConfig` with a given configuration dictionary.
///   - set(config:): Sets the configuration properties from a given dictionary.
///   - apply(closure:): Applies a closure to the configuration instance and returns the instance.
//
//  DbSyncConfig.swift
//  com.aware.ios.sensor.core
//
//  Created by Yuuki Nishiyama on 2018/10/18.
//

import Foundation

#if canImport(UIKit)
    import UIKit
#endif

public typealias DbSyncCompletionHandler = (_ status: Bool, _ error: Error?) -> Void
public typealias DbSyncProgressHandler = (_ progress: Double, _ error: Error?) -> Void

/// Debug level for synchronization logging
public enum DbSyncDebugLevel: Int, CaseIterable {
    case none = 0  // No debug output
    case error = 1  // Only errors and critical messages
    case warning = 2  // Errors, warnings, and important status
    case info = 3  // Basic flow information
    case verbose = 4  // Detailed method flow and data
    case trace = 5  // All debug information including internal details

    /// Human readable description
    public var description: String {
        switch self {
        case .none: return "None"
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
        case .verbose: return "Verbose"
        case .trace: return "Trace"
        }
    }
}

public class DbSyncConfig {
    public static var defaultServerType: ServerType = .aware_micro
    public static var defaultStudyNumber: Int = 1
    public static var defaultStudyKey: String = ""
    public static var defaultCompactDataFormat: Bool = false
    /// App-wide defaults for new configs (sensors create their configs themselves)
    public static var defaultMaxBatchBytes: Int? = nil
    public static var defaultMaxBatchBytesCeiling: Int? = nil
    public static var defaultMaxBatchRows: Int = 20000
    public static var defaultCpuRestRatio: Double = 1
    public static var defaultPrefetchNextBatch: Bool = true

    public var removeAfterSync: Bool = true

    /// Periods that can be used for `keepDataAfterSync`.
    public enum KeepPeriod: String, CaseIterable {
        case immediately  // delete right after upload
        case hour
        case day
        case week
        case month  // 30 days

        public var seconds: TimeInterval {
            switch self {
            case .immediately: return 0
            case .hour: return 60 * 60
            case .day: return 60 * 60 * 24
            case .week: return 60 * 60 * 24 * 7
            case .month: return 60 * 60 * 24 * 30
            }
        }
    }

    /// Seconds to keep uploaded rows on the device before `removeAfterSync` deletes them,
    /// counted from each row's `timestamp`. `0` deletes them right after upload.
    /// Rows that have not been uploaded are never deleted. Negative values are ignored.
    public var keepDataAfterSync: TimeInterval = KeepPeriod.day.seconds {
        didSet {
            if keepDataAfterSync < 0 || !keepDataAfterSync.isFinite {
                print("[AWARE::Core][Illegal Parameter] keepDataAfterSync must be 0 or more seconds. "
                      + "'\(keepDataAfterSync)' is ignored.")
                keepDataAfterSync = oldValue
            }
        }
    }

    /// `keepDataAfterSync` as a period. Setting it sets `keepDataAfterSync`; reading it returns the
    /// matching period, or `nil` when `keepDataAfterSync` is not one of them.
    public var keepPeriod: KeepPeriod? {
        get { KeepPeriod.allCases.first { $0.seconds == keepDataAfterSync } }
        set { if let period = newValue { keepDataAfterSync = period.seconds } }
    }
    public var batchSize: Int = 1000
    public var maxBatchBytes: Int? = DbSyncConfig.defaultMaxBatchBytes
    public var maxBatchBytesCeiling: Int? = DbSyncConfig.defaultMaxBatchBytesCeiling
    public var maxBatchRows: Int = DbSyncConfig.defaultMaxBatchRows
    public var prefetchNextBatch: Bool = DbSyncConfig.defaultPrefetchNextBatch
    public var batchInterval: TimeInterval = 0
    public var cpuRestRatio: Double = DbSyncConfig.defaultCpuRestRatio
    public var backgroundCpuRestRatio: Double = 3
    public var markAsSynced: Bool = false
    public var skipSyncedData: Bool = false
    public var keepLastData: Bool = false
    public var deviceId: String? = nil
    public var debug: Bool = false
    public var debugLevel: DbSyncDebugLevel = .info  // Default to info level
    public var completionHandler: DbSyncCompletionHandler? = nil
    public var progressHandler: DbSyncProgressHandler? = nil
    public var dispatchQueue: DispatchQueue? = nil
    public var backgroundSession = false
    public var compactDataFormat = DbSyncConfig.defaultCompactDataFormat
    public var serverType: ServerType = DbSyncConfig.defaultServerType
    public var studyNumber: Int = DbSyncConfig.defaultStudyNumber
    public var studyKey: String = DbSyncConfig.defaultStudyKey

    public var test = false

    public init() {

    }

    public init(_ config: [String: Any]) {
        set(config: config)
    }

    /// Returns a new config with the same values. Sensors that upload several tables use it to give
    /// each table its own config (for example its own `completionHandler` and `dispatchQueue`)
    /// without missing settings. Handlers and the queue are shared, not duplicated.
    /// When adding a property to `DbSyncConfig`, copy it here too (`testDbSyncConfigCopy` checks it).
    public func copy() -> DbSyncConfig {
        let c = DbSyncConfig()
        c.removeAfterSync = removeAfterSync
        c.keepDataAfterSync = keepDataAfterSync
        c.batchSize = batchSize
        c.maxBatchBytes = maxBatchBytes
        c.maxBatchBytesCeiling = maxBatchBytesCeiling
        c.maxBatchRows = maxBatchRows
        c.prefetchNextBatch = prefetchNextBatch
        c.batchInterval = batchInterval
        c.cpuRestRatio = cpuRestRatio
        c.backgroundCpuRestRatio = backgroundCpuRestRatio
        c.markAsSynced = markAsSynced
        c.skipSyncedData = skipSyncedData
        c.keepLastData = keepLastData
        c.deviceId = deviceId
        c.debug = debug
        c.debugLevel = debugLevel
        c.completionHandler = completionHandler
        c.progressHandler = progressHandler
        c.dispatchQueue = dispatchQueue
        c.backgroundSession = backgroundSession
        c.compactDataFormat = compactDataFormat
        c.serverType = serverType
        c.studyNumber = studyNumber
        c.studyKey = studyKey
        c.test = test
        return c
    }

    public func set(config: [String: Any]) {
        if let removeAfterSync = config["removeAfterSync"] as? Bool {
            self.removeAfterSync = removeAfterSync
        }

        // Seconds ("keepDataAfterSync") or a period name ("keepPeriod": "immediately", "hour", "day", "week", "month")
        if let seconds = config["keepDataAfterSync"] as? Int {
            self.keepDataAfterSync = TimeInterval(seconds)
        } else if let seconds = config["keepDataAfterSync"] as? Double {
            self.keepDataAfterSync = seconds
        }
        if let name = config["keepPeriod"] as? String, let period = KeepPeriod(rawValue: name.lowercased()) {
            self.keepPeriod = period
        }

        if let batchSize = config["batchSize"] as? Int {
            self.batchSize = batchSize
        }
        if let bytes = config["maxBatchBytes"] as? Int {
            self.maxBatchBytes = bytes
        }
        if let bytes = config["maxBatchBytesCeiling"] as? Int {
            self.maxBatchBytesCeiling = bytes
        }
        if let rows = config["maxBatchRows"] as? Int {
            self.maxBatchRows = rows
        }
        if let prefetch = config["prefetchNextBatch"] as? Bool {
            self.prefetchNextBatch = prefetch
        }
        if let interval = config["batchInterval"] as? Double {
            self.batchInterval = interval
        } else if let interval = config["batchInterval"] as? Int {
            self.batchInterval = TimeInterval(interval)
        }
        if let ratio = config["cpuRestRatio"] as? Double {
            self.cpuRestRatio = ratio
        }
        if let ratio = config["backgroundCpuRestRatio"] as? Double {
            self.backgroundCpuRestRatio = ratio
        }

        if let markAsSynced = config["markAsSynced"] as? Bool {
            self.markAsSynced = markAsSynced
        }

        if let skipSyncedData = config["skipSyncedData"] as? Bool {
            self.skipSyncedData = skipSyncedData
        }

        if let keepLastData = config["keepLastData"] as? Bool {
            self.keepLastData = keepLastData
        }

        self.deviceId = config["deviceId"] as? String

        if let debug = config["debug"] as? Bool {
            self.debug = debug
        }

        if let debugLevel = config["debugLevel"] as? Int {
            if let level = DbSyncDebugLevel(rawValue: debugLevel) {
                self.debugLevel = level
            }
        } else if let debugLevelString = config["debugLevel"] as? String {
            switch debugLevelString.lowercased() {
            case "none", "0": self.debugLevel = .none
            case "error", "1": self.debugLevel = .error
            case "warning", "2": self.debugLevel = .warning
            case "info", "3": self.debugLevel = .info
            case "verbose", "4": self.debugLevel = .verbose
            case "trace", "5": self.debugLevel = .trace
            default: break
            }
        }

        if let test = config["test"] as? Bool {
            self.test = test
        }

        if let compactDataFormat = config["compactDataFormat"] as? Bool {
            self.compactDataFormat = compactDataFormat
        } else if let compressionMode = config["compressionMode"] as? String {
            self.compactDataFormat = compressionMode.lowercased() == "compact"
        }

        if let studyNumber = config["studyNumber"] as? Int {
            self.studyNumber = studyNumber
        } else if let studyNumber = config["study_number"] as? Int {
            self.studyNumber = studyNumber
        }

        if let studyKey = config["studyKey"] as? String {
            self.studyKey = studyKey
        } else if let studyKey = config["study_key"] as? String {
            self.studyKey = studyKey
        }

        if let serverType = config["serverType"] as? Int {
            if serverType == 0 {
                self.serverType = .none
            } else if serverType == 1 {
                self.serverType = .aware
            } else if serverType == 2 {
                self.serverType = .aware_micro
            } else if serverType == 3 {
                self.serverType = .aware_micro
            } else if serverType == 4 {
                self.serverType = .aware_light
            } else {
                self.serverType = .aware
            }
        }
    }

    public func apply(closure: (_ config: DbSyncConfig) -> Void) -> Self {
        closure(self)
        return self
    }
}
