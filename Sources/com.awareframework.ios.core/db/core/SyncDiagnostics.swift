//
//  SyncDiagnostics.swift
//  com.awareframework.ios.core
//
//  Where the time of an upload goes, to tell why a sync is slow: reading rows and building the
//  request on the device, opening the connection, sending the body, the server's processing,
//  deleting uploaded rows, the rest between requests (SyncPacing), and waits before retries.
//
//  Like the timing logs of AWAREFramework-iOS 1.x (`[sensor] SQLite ---> seconds`), but kept as
//  values: `SyncDiagnostics.shared` holds the last requests and the summary of the last sync of each
//  table, and `Notification.Name.Aware.dbSyncDiagnostics` is posted when a sync ends.
//

import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Clocks

/// Wall and CPU clocks for the measurements.
enum SyncClock {
    /// Monotonic time in nanoseconds
    @inline(__always) static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// CPU time of the current thread in nanoseconds
    static func threadCPU() -> UInt64 {
        #if canImport(Darwin)
            return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        #else
            return 0
        #endif
    }

    static func seconds(_ nanos: UInt64) -> TimeInterval { Double(nanos) / 1_000_000_000 }

    /// Seconds since `start` (nanoseconds from `now()`)
    static func since(_ start: UInt64) -> TimeInterval { seconds(now() &- start) }

    /// CPU time of the whole app (every thread), user and system
    static func processCPU() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> TimeInterval { TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    /// Memory the app uses (what iOS counts toward its memory limit), in bytes
    static func footprint() -> UInt64? {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : nil
        #else
            return nil
        #endif
    }
}

// MARK: - Phases

/// Where the device spent the time of a request, phase by phase.
public struct SyncPhaseTimes: Equatable {
    /// Waiting for the database queue (the sensors' writes use it too)
    public var dbWait: TimeInterval = 0
    /// Stepping through the rows in SQLite
    public var dbRead: TimeInterval = 0
    /// Writing the rows as JSON
    public var jsonEncode: TimeInterval = 0
    /// Measuring whether rows fit in the size limit (URL encoding for the legacy AWARE server)
    public var sizeCheck: TimeInterval = 0
    /// Joining the rows into the request body
    public var assemble: TimeInterval = 0
    /// Turning the body into bytes for the request
    public var toData: TimeInterval = 0
    /// Deleting uploaded rows
    public var delete: TimeInterval = 0
    /// CPU time of the preparation (reading to bytes)
    public var prepareCPU: TimeInterval = 0

    public init() {}

    /// Reading the rows to the bytes of the request
    public var prepare: TimeInterval { dbWait + dbRead + jsonEncode + sizeCheck + assemble + toData }

    /// The phases with their names, in order
    public var named: [(String, TimeInterval)] {
        [("db wait", dbWait), ("db read", dbRead), ("json", jsonEncode), ("size check", sizeCheck),
         ("assemble", assemble), ("to bytes", toData), ("delete", delete)]
    }

    public static func + (a: SyncPhaseTimes, b: SyncPhaseTimes) -> SyncPhaseTimes {
        var r = SyncPhaseTimes()
        r.dbWait = a.dbWait + b.dbWait
        r.dbRead = a.dbRead + b.dbRead
        r.jsonEncode = a.jsonEncode + b.jsonEncode
        r.sizeCheck = a.sizeCheck + b.sizeCheck
        r.assemble = a.assemble + b.assemble
        r.toData = a.toData + b.toData
        r.delete = a.delete + b.delete
        r.prepareCPU = a.prepareCPU + b.prepareCPU
        return r
    }

    /// Text like "db read 40 ms, json 25 ms, ... (CPU 60 ms)"
    public var description: String {
        named.filter { $0.1 >= 0.0005 }.map { "\($0.0) \(SyncDiagnostics.seconds($0.1))" }.joined(separator: ", ")
            + " (CPU \(SyncDiagnostics.seconds(prepareCPU)))"
    }
}

/// One request of a sync.
public struct SyncBatchMetrics: CustomStringConvertible {
    public let table: String
    public let host: String
    public let date: Date
    public let rows: Int
    public let bodyBytes: Int
    /// The size limit the request was chosen with (`SyncBatchLimit`)
    public let limitBytes: Int
    /// Reading rows and building the body (CPU and database)
    public let prepareSeconds: TimeInterval
    /// Whether the request was prepared while the previous one was in flight (`prefetchNextBatch`);
    /// its preparation then did not delay the sync
    public let prefetched: Bool
    /// From sending the request to its end (connection, body, server, response)
    public let networkSeconds: TimeInterval
    /// Parts of `networkSeconds` from `URLSessionTaskMetrics` (nil when not reported)
    public let connectSeconds: TimeInterval?
    public let uploadSeconds: TimeInterval?
    public let serverSeconds: TimeInterval?
    public let downloadSeconds: TimeInterval?
    /// Deleting uploaded rows
    public let deleteSeconds: TimeInterval
    /// Rest before the next request (SyncPacing), or wait before a retry
    public let restSeconds: TimeInterval
    public let statusCode: Int?
    public let success: Bool
    public let background: Bool
    public let lowPower: Bool
    public let thermalState: ProcessInfo.ThermalState
    /// Phase by phase times of the preparation and the deletion on the device
    public var phases = SyncPhaseTimes()
    /// CPU use of the whole app since the previous request (100 = one core), and its memory
    public var appCPUPercent: Double?
    public var memoryMB: Double?

    /// Body bytes per second while the body was sent
    public var uploadBytesPerSecond: Double? {
        guard let s = uploadSeconds, s > 0 else { return nil }
        return Double(bodyBytes) / s
    }

    public var description: String {
        var parts = [
            "\(rows) rows", SyncDiagnostics.bytes(bodyBytes) + "/" + SyncDiagnostics.bytes(limitBytes),
            "prepare " + SyncDiagnostics.seconds(prepareSeconds) + (prefetched ? " (overlapped)" : ""),
            "network " + SyncDiagnostics.seconds(networkSeconds),
        ]
        if let c = connectSeconds { parts.append("connect " + SyncDiagnostics.seconds(c)) }
        if let u = uploadSeconds { parts.append("send " + SyncDiagnostics.seconds(u)) }
        if let s = serverSeconds { parts.append("server " + SyncDiagnostics.seconds(s)) }
        if let r = uploadBytesPerSecond { parts.append(SyncDiagnostics.bytes(Int(r)) + "/s") }
        parts.append("delete " + SyncDiagnostics.seconds(deleteSeconds))
        parts.append("rest " + SyncDiagnostics.seconds(restSeconds))
        parts.append(success ? "OK" : "FAILED(\(statusCode.map(String.init) ?? "-"))")
        if background { parts.append("background") }
        if lowPower { parts.append("low power") }
        if thermalState == .serious || thermalState == .critical { parts.append("hot") }
        var text = parts.joined(separator: ", ")
        text += " | phases: " + phases.description
        if let cpu = appCPUPercent { text += String(format: " | app CPU %.0f%%", cpu) }
        if let mb = memoryMB { text += String(format: ", memory %.0f MB", mb) }
        return text
    }
}

/// Where the time of a sync went.
public enum SyncBottleneck: String, CaseIterable {
    case preparation = "device: reading rows and building requests"
    case connection = "network: opening connections"
    case upload = "network: sending data (bandwidth)"
    case server = "server: processing requests"
    case network = "network or server (no detailed timing)"
    case deletion = "device: deleting uploaded rows"
    case pacing = "rest between requests (background, Low Power Mode, heat or cpuRestRatio)"
    case retries = "retries (413, timeouts, 429/503)"
    case unknown = "unknown"
}

/// The summary of one sync of one table.
public struct SyncRunSummary: CustomStringConvertible {
    public let table: String
    public let host: String
    public let startedAt: Date
    public let endedAt: Date
    public let success: Bool
    public let batches: Int
    public let failedRequests: Int
    public let rows: Int
    public let bytes: Int
    /// Preparation that delayed the sync (prefetched preparation overlaps the network and is left out)
    public let prepareSeconds: TimeInterval
    public let overlappedPrepareSeconds: TimeInterval
    public let networkSeconds: TimeInterval
    public let connectSeconds: TimeInterval
    public let uploadSeconds: TimeInterval
    public let serverSeconds: TimeInterval
    public let deleteSeconds: TimeInterval
    public let restSeconds: TimeInterval
    public let retryWaitSeconds: TimeInterval
    public let lastLimitBytes: Int
    public let backgroundBatches: Int
    /// Phase by phase times of every request together
    public var phases = SyncPhaseTimes()
    /// Largest memory use of the app during the sync
    public var peakMemoryMB: Double?

    public var elapsedSeconds: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    public var rowsPerSecond: Double { elapsedSeconds > 0 ? Double(rows) / elapsedSeconds : 0 }
    public var bytesPerSecond: Double { elapsedSeconds > 0 ? Double(bytes) / elapsedSeconds : 0 }
    /// Time not covered by the measured parts (queue hops, waiting for the database lock, ...)
    public var otherSeconds: TimeInterval {
        max(0, elapsedSeconds - prepareSeconds - networkSeconds - deleteSeconds - restSeconds - retryWaitSeconds)
    }

    /// The share of the elapsed time of each part, largest first.
    public var breakdown: [(SyncBottleneck, Double)] {
        let total = max(elapsedSeconds, 1e-9)
        var parts: [(SyncBottleneck, TimeInterval)] = [
            (.preparation, prepareSeconds), (.deletion, deleteSeconds),
            (.pacing, restSeconds), (.retries, retryWaitSeconds),
        ]
        let detailed = connectSeconds + uploadSeconds + serverSeconds
        if detailed > 0 {
            parts += [(.connection, connectSeconds), (.upload, uploadSeconds),
                      (.server, serverSeconds + max(0, networkSeconds - detailed))]
        } else {
            parts.append((.network, networkSeconds))
        }
        return parts.map { ($0.0, $0.1 / total) }.sorted { $0.1 > $1.1 }
    }

    /// The part that took the most time.
    public var bottleneck: SyncBottleneck {
        guard let top = breakdown.first, top.1 > 0 else { return .unknown }
        return top.0
    }

    public var description: String {
        let shares = breakdown.filter { $0.1 >= 0.01 }
            .map { "\($0.0.shortName) \(Int(($0.1 * 100).rounded()))%" }.joined(separator: ", ")
        return "[\(table)] \(success ? "done" : "failed"): \(rows) rows, \(SyncDiagnostics.bytes(bytes)) "
            + "in \(SyncDiagnostics.seconds(elapsedSeconds)) (\(batches) requests, "
            + "\(SyncDiagnostics.bytes(Int(bytesPerSecond)))/s, \(Int(rowsPerSecond)) rows/s, "
            + "limit \(SyncDiagnostics.bytes(lastLimitBytes)))"
            + (failedRequests > 0 ? ", \(failedRequests) failed requests" : "")
            + (backgroundBatches > 0 ? ", \(backgroundBatches) in background" : "")
            + " | \(shares)"
            + (overlappedPrepareSeconds > 0 ? " | overlapped prepare \(SyncDiagnostics.seconds(overlappedPrepareSeconds))" : "")
            + " | bottleneck: \(bottleneck.rawValue)"
            + " | device phases: " + phases.description
            + (rows > 0 ? String(format: " | %.0f ms per 1000 rows prepared", phases.prepare / Double(rows) * 1_000_000) : "")
            + (peakMemoryMB.map { String(format: " | peak memory %.0f MB", $0) } ?? "")
    }
}

extension SyncBottleneck {
    public var shortName: String {
        switch self {
        case .preparation: return "prepare"
        case .connection: return "connect"
        case .upload: return "send"
        case .server: return "server"
        case .network: return "network"
        case .deletion: return "delete"
        case .pacing: return "rest"
        case .retries: return "retry"
        case .unknown: return "other"
        }
    }
}

/// Collects `SyncBatchMetrics` of a running sync and makes its `SyncRunSummary`.
struct SyncRunRecorder {
    let table: String
    let host: String
    var startedAt: Date?
    var batches = 0
    var failedRequests = 0
    var rows = 0
    var bytes = 0
    var prepare: TimeInterval = 0
    var overlappedPrepare: TimeInterval = 0
    var network: TimeInterval = 0
    var connect: TimeInterval = 0
    var upload: TimeInterval = 0
    var server: TimeInterval = 0
    var delete: TimeInterval = 0
    var rest: TimeInterval = 0
    var retryWait: TimeInterval = 0
    var lastLimit = 0
    var backgroundBatches = 0
    var phases = SyncPhaseTimes()
    var peakMemoryMB: Double?

    init(table: String, host: String) {
        self.table = table
        self.host = host
    }

    mutating func add(_ m: SyncBatchMetrics, isRetryWait: Bool) {
        if m.success {
            batches += 1
            rows += m.rows
            bytes += m.bodyBytes
        } else {
            failedRequests += 1
        }
        if m.prefetched { overlappedPrepare += m.prepareSeconds } else { prepare += m.prepareSeconds }
        network += m.networkSeconds
        connect += m.connectSeconds ?? 0
        upload += m.uploadSeconds ?? 0
        server += m.serverSeconds ?? 0
        delete += m.deleteSeconds
        if isRetryWait { retryWait += m.restSeconds } else { rest += m.restSeconds }
        lastLimit = m.limitBytes
        if m.background { backgroundBatches += 1 }
        phases = phases + m.phases
        if let mb = m.memoryMB { peakMemoryMB = max(peakMemoryMB ?? 0, mb) }
    }

    func summary(success: Bool, endedAt: Date = Date()) -> SyncRunSummary? {
        guard let startedAt, batches + failedRequests > 0 else { return nil }
        var summary = SyncRunSummary(
            table: table, host: host, startedAt: startedAt, endedAt: endedAt, success: success,
            batches: batches, failedRequests: failedRequests, rows: rows, bytes: bytes,
            prepareSeconds: prepare, overlappedPrepareSeconds: overlappedPrepare, networkSeconds: network,
            connectSeconds: connect, uploadSeconds: upload, serverSeconds: server, deleteSeconds: delete,
            restSeconds: rest, retryWaitSeconds: retryWait, lastLimitBytes: lastLimit,
            backgroundBatches: backgroundBatches)
        summary.phases = phases
        summary.peakMemoryMB = peakMemoryMB
        return summary
    }
}

/// The last requests and the summary of the last sync of each table, readable from any thread.
public final class SyncDiagnostics {

    public static let shared = SyncDiagnostics()

    /// Requests kept (all tables together)
    public var maxBatches = 300
    /// Print each request and each summary, even when `DbSyncConfig.debug` is off
    public var printsToConsole = false

    private let lock = NSLock()
    private var loadSample: (time: UInt64, cpu: TimeInterval)?
    private var batches: [SyncBatchMetrics] = []
    private var summaries: [String: SyncRunSummary] = [:]

    private init() {}

    /// CPU use of the whole app since the last call (100 = one core), and its memory in MB
    func sampleLoad() -> (cpuPercent: Double?, memoryMB: Double?) {
        let now = SyncClock.now()
        let cpu = SyncClock.processCPU()
        lock.lock()
        let previous = loadSample
        loadSample = (now, cpu)
        lock.unlock()
        var percent: Double?
        if let previous, now > previous.time {
            percent = (cpu - previous.cpu) / SyncClock.seconds(now - previous.time) * 100
        }
        return (percent, SyncClock.footprint().map { Double($0) / 1_000_000 })
    }

    func record(_ batch: SyncBatchMetrics) {
        lock.lock()
        batches.append(batch)
        if batches.count > maxBatches { batches.removeFirst(batches.count - maxBatches) }
        let printing = printsToConsole
        lock.unlock()
        if printing { print("[AWARE::Core][SyncDiagnostics][\(batch.table)] \(batch)") }
    }

    func record(_ summary: SyncRunSummary) {
        lock.lock()
        summaries[summary.table] = summary
        let printing = printsToConsole
        lock.unlock()
        if printing { print("[AWARE::Core][SyncDiagnostics] \(summary)") }
        NotificationCenter.default.post(name: Notification.Name.Aware.dbSyncDiagnostics, object: summary)
    }

    /// The summary of the last sync of each table, newest first.
    public func latestSummaries() -> [SyncRunSummary] {
        lock.lock()
        defer { lock.unlock() }
        return summaries.values.sorted { $0.endedAt > $1.endedAt }
    }

    public func latestSummary(table: String) -> SyncRunSummary? {
        lock.lock()
        defer { lock.unlock() }
        return summaries[table]
    }

    /// The last requests, oldest first (of one table, or of all tables).
    public func recentBatches(table: String? = nil) -> [SyncBatchMetrics] {
        lock.lock()
        defer { lock.unlock() }
        guard let table else { return batches }
        return batches.filter { $0.table == table }
    }

    /// A text report of the last syncs, for logs or for sharing.
    public func report() -> String {
        let list = latestSummaries()
        guard list.isEmpty == false else { return "No upload has been measured yet." }
        let total = list.reduce(into: [SyncBottleneck: TimeInterval]()) { result, s in
            for (part, share) in s.breakdown { result[part, default: 0] += share * s.elapsedSeconds }
        }
        let overall = total.max { $0.value < $1.value }?.key ?? .unknown
        return (["Overall bottleneck: \(overall.rawValue)"] + list.map(\.description)).joined(separator: "\n")
    }

    public func reset() {
        lock.lock()
        batches = []
        summaries = [:]
        lock.unlock()
    }

    static func seconds(_ s: TimeInterval) -> String {
        s < 1 ? String(format: "%.0f ms", s * 1000) : String(format: "%.1f s", s)
    }

    static func bytes(_ b: Int) -> String {
        if b >= 1_000_000 { return String(format: "%.1f MB", Double(b) / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f KB", Double(b) / 1_000) }
        return "\(b) B"
    }
}
