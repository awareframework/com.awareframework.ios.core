//
//  SyncPacing.swift
//  com.awareframework.ios.core
//
//  How fast a sync may go: the app state (foreground or background), the device state (thermal
//  state, Low Power Mode) and the per-host request size limit.
//

import Foundation
#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

// MARK: - App state

/// Whether the app is in the background, readable from any thread.
///
/// Updated from the UIApplication notifications. Before the first notification the state is read
/// once on the main thread. On platforms without UIApplication the app is treated as foreground.
public final class SyncAppState {

    public static let shared = SyncAppState()

    private let lock = NSLock()
    private var background = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        #if canImport(UIKit) && !os(watchOS)
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.set(true) })
            observers.append(center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.set(false) })
            observers.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.set(false) })
            let read = { [weak self] in
                // UIApplication.shared is not available in app extensions; treat them as foreground
                guard let app = UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication else { return }
                self?.set(app.applicationState == .background)
            }
            if Thread.isMainThread { read() } else { DispatchQueue.main.async(execute: read) }
        #endif
    }

    private func set(_ value: Bool) {
        lock.lock()
        background = value
        lock.unlock()
    }

    /// `true` while the app is in the background.
    public var isInBackground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return background
    }

    /// Quality of service for sync work: lower in the background, so the system can keep the
    /// app within its background CPU limits.
    var workQoS: DispatchQoS {
        isInBackground ? .background : .utility
    }
}

// MARK: - Pacing between batches

/// How long a sync rests between batches.
///
/// Instead of a fixed wait, the sync rests for a multiple of the CPU-bound time the last batch took
/// (reading rows, building the request, deleting uploaded rows). Waiting for the server is not
/// counted, so on a slow network the sync does not wait more than it needs to, while on a fast
/// network it still leaves the CPU idle most of the time. iOS may stop an app that keeps the CPU
/// busy in the background, so the sync rests longer there.
enum SyncPacing {

    /// The rest before the next batch.
    ///
    /// - Parameters:
    ///   - workSeconds: CPU-bound time of the last batch.
    ///   - config: `batchInterval` (minimum rest), `cpuRestRatio` and `backgroundCpuRestRatio`.
    ///   - background: Whether the app is in the background.
    ///   - thermal: The device's thermal state.
    ///   - lowPower: Whether Low Power Mode is on.
    static func rest(
        workSeconds: TimeInterval, config: DbSyncConfig, background: Bool,
        thermal: ProcessInfo.ThermalState, lowPower: Bool
    ) -> TimeInterval {
        let ratio = max(0, background ? config.backgroundCpuRestRatio : config.cpuRestRatio)
        var rest = max(config.batchInterval, max(0, workSeconds) * ratio)
        if lowPower { rest *= 2 }
        switch thermal {
        case .serious: rest = max(rest, 5)
        case .critical: rest = max(rest, 30)
        default: break
        }
        return min(rest, 120)
    }

    static func rest(workSeconds: TimeInterval, config: DbSyncConfig) -> TimeInterval {
        rest(workSeconds: workSeconds, config: config, background: SyncAppState.shared.isInBackground,
             thermal: ProcessInfo.processInfo.thermalState,
             lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}

// MARK: - Request size limit

/// The largest request body a sync sends to a host.
///
/// - Default: `DbSyncConfig.maxBatchBytes`, or 500 KB when it is not set, for every server type
///   (AWARE Micro, and the AWARE server, whose PHP version is retired and whose endpoints are served
///   by Flask). 500 KB is Flask's default limit of a form field (Werkzeug 3.1 `MAX_FORM_MEMORY_SIZE`),
///   and the AWARE server receives all rows of a request in one form field, so a server with default
///   settings never rejects the first requests. A server with a higher limit gets larger requests
///   by growth (below). A server with a smaller limit (413) gets a smaller size, which is remembered.
/// - Growth (like `AWAREFetchSizeAdjuster` of AWAREFramework-iOS 1.x): after `growAfterFullSuccesses`
///   requests in a row that were filled up to the limit and finished within `growMaxNetworkSeconds`,
///   the limit grows by half, up to the ceiling (`DbSyncConfig.maxBatchBytesCeiling`; 8 MB by
///   default). What was learned is saved (UserDefaults), so later syncs start from it.
/// - When a host answers 413, half of the rejected body size becomes its limit. This is saved, so
///   later syncs start with a size the host accepts. It grows back by the rule above, but never above
///   90 % of the smallest body the host rejected.
/// - When a request times out, the limit is halved for the running app only (network speed
///   changes), and grows back after `growAfterSuccesses` successful requests.
public enum SyncBatchLimit {

    /// Default request size, for every server type: Flask's default form field limit
    /// (Werkzeug 3.1 `MAX_FORM_MEMORY_SIZE` = 500,000 bytes)
    public static let defaultBytes = 500_000
    /// Default ceiling of the growth, for every server type (Google App Engine accepts 32 MB). Kept
    /// well below it: each table holds the body in flight and the prefetched next one, and several
    /// tables upload at the same time, so larger bodies risk the app's memory limit.
    public static let defaultCeilingBytes = 8_000_000
    /// Up to 1.7 the defaults depended on the server type. They are the same now.
    public static let microDefaultBytes = defaultBytes
    public static let otherDefaultBytes = defaultBytes
    public static let microCeilingBytes = defaultCeilingBytes
    /// Never below this, so that a sync always makes progress
    public static let minimumBytes = 16_384
    static let growAfterSuccesses = 20
    /// Full requests in a row before the limit grows
    static let growAfterFullSuccesses = 3
    /// A request counts toward growth only when its body was at least this part of the limit
    static let fullRatio = 0.8
    /// A request counts toward growth only when it finished within this time, so that the limit
    /// does not grow toward timeouts on a slow network
    static let growMaxNetworkSeconds: TimeInterval = 10
    static let growthFactor = 1.5
    static let keyPrefix = "aware.sync.max_batch_bytes."
    static let grownKeyPrefix = "aware.sync.grown_batch_bytes."
    static let rejectedKeyPrefix = "aware.sync.rejected_batch_bytes."

    private static let lock = NSLock()
    private static var timeoutLimits: [String: Int] = [:]
    private static var successes: [String: Int] = [:]
    private static var fullSuccesses: [String: Int] = [:]

    /// The configured or default limit, before what was learned from the host.
    public static func configured(_ config: DbSyncConfig) -> Int {
        if let bytes = config.maxBatchBytes, bytes > 0 { return max(minimumBytes, bytes) }
        return defaultBytes
    }

    /// The largest limit the growth may reach (never below the configured limit).
    public static func ceiling(_ config: DbSyncConfig) -> Int {
        let base = configured(config)
        if let bytes = config.maxBatchBytesCeiling, bytes > 0 { return max(base, bytes) }
        return max(base, defaultCeilingBytes)
    }

    /// The limit to use for `host` now.
    public static func current(host: String, config: DbSyncConfig) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentLocked(host: host, config: config)
    }

    private static func currentLocked(host: String, config: DbSyncConfig) -> Int {
        let defaults = UserDefaults.standard
        var limit = configured(config)
        let grown = defaults.integer(forKey: grownKeyPrefix + host)
        if grown > limit { limit = min(grown, ceiling(config)) }
        let saved = defaults.integer(forKey: keyPrefix + host)
        if saved > 0 { limit = min(limit, saved) }
        if let t = timeoutLimits[host] { limit = min(limit, t) }
        return max(minimumBytes, limit)
    }

    /// The host rejected a body of `bodyBytes` as too large (413).
    /// - Returns: The new limit.
    @discardableResult
    public static func recordTooLarge(host: String, bodyBytes: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        let limit = max(minimumBytes, bodyBytes / 2)
        let saved = defaults.integer(forKey: keyPrefix + host)
        defaults.set(saved > 0 ? min(saved, limit) : limit, forKey: keyPrefix + host)
        let rejected = defaults.integer(forKey: rejectedKeyPrefix + host)
        defaults.set(rejected > 0 ? min(rejected, bodyBytes) : bodyBytes, forKey: rejectedKeyPrefix + host)
        if defaults.integer(forKey: grownKeyPrefix + host) >= bodyBytes {
            defaults.removeObject(forKey: grownKeyPrefix + host)
        }
        successes[host] = 0
        fullSuccesses[host] = 0
        return limit
    }

    /// A request of `bodyBytes` timed out.
    @discardableResult
    public static func recordTimeout(host: String, bodyBytes: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let limit = max(minimumBytes, bodyBytes / 2)
        timeoutLimits[host] = min(timeoutLimits[host] ?? limit, limit)
        successes[host] = 0
        fullSuccesses[host] = 0
        return limit
    }

    /// A request succeeded: after `growAfterSuccesses` in a row, a timeout limit grows back by half.
    public static func recordSuccess(host: String) {
        lock.lock()
        defer { lock.unlock() }
        growBackFromTimeout(host: host)
    }

    /// A request of `bodyBytes` succeeded after `networkSeconds`. Besides `recordSuccess(host:)`, the
    /// limit grows after `growAfterFullSuccesses` full requests in a row (see the type's description).
    /// - Returns: The new limit when it grew, otherwise nil.
    @discardableResult
    public static func recordSuccess(host: String, bodyBytes: Int, networkSeconds: TimeInterval,
                                     config: DbSyncConfig) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        growBackFromTimeout(host: host)

        let limit = currentLocked(host: host, config: config)
        let full = Double(bodyBytes) >= Double(limit) * fullRatio
        guard full, networkSeconds <= growMaxNetworkSeconds, timeoutLimits[host] == nil else {
            fullSuccesses[host] = 0
            return nil
        }
        let n = (fullSuccesses[host] ?? 0) + 1
        guard n >= growAfterFullSuccesses else {
            fullSuccesses[host] = n
            return nil
        }
        fullSuccesses[host] = 0

        let defaults = UserDefaults.standard
        var cap = ceiling(config)
        let rejected = defaults.integer(forKey: rejectedKeyPrefix + host)
        if rejected > 0 { cap = min(cap, Int(Double(rejected) * 0.9)) }
        let next = min(cap, Int(Double(limit) * growthFactor))
        guard next > limit else { return nil }

        let saved = defaults.integer(forKey: keyPrefix + host)
        if saved > 0 && saved <= limit {
            // The limit learned from a 413 is what holds it back: raise it (still below the rejected size)
            defaults.set(next, forKey: keyPrefix + host)
        }
        if next > configured(config) {
            defaults.set(next, forKey: grownKeyPrefix + host)
        }
        return currentLocked(host: host, config: config)
    }

    private static func growBackFromTimeout(host: String) {
        guard let t = timeoutLimits[host] else { return }
        let n = (successes[host] ?? 0) + 1
        if n >= growAfterSuccesses {
            timeoutLimits[host] = t + t / 2
            successes[host] = 0
        } else {
            successes[host] = n
        }
    }

    /// The key a sync uses for `host` (a server URL or host name): the host without `http://` or `https://`.
    public static func hostKey(_ host: String) -> String {
        AwareUtils.cleanHostName(host.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What is known about the request size for a host, for display.
    public struct State: Equatable {
        public let host: String
        /// The configured or default size (`DbSyncConfig.maxBatchBytes`)
        public let configuredBytes: Int
        /// The largest size growth may reach (`DbSyncConfig.maxBatchBytesCeiling`)
        public let ceilingBytes: Int
        /// The size the next request uses
        public let currentBytes: Int
        /// Size reached by growth (saved), if above the configured size
        public let grownBytes: Int?
        /// Limit learned from a 413 (saved)
        public let tooLargeLimitBytes: Int?
        /// Smallest body the host rejected with 413 (saved); growth stays below 90 % of it
        public let rejectedBytes: Int?
        /// Limit after a timeout (this run of the app only)
        public let timeoutLimitBytes: Int?

        /// Whether anything learned is in effect
        public var hasLearned: Bool {
            grownBytes != nil || tooLargeLimitBytes != nil || rejectedBytes != nil || timeoutLimitBytes != nil
        }
    }

    /// What is known about `host` (a server URL or host name) under `config`.
    public static func state(host: String, config: DbSyncConfig) -> State {
        let key = hostKey(host)
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        func saved(_ prefix: String) -> Int? {
            let v = defaults.integer(forKey: prefix + key)
            return v > 0 ? v : nil
        }
        let grown = saved(grownKeyPrefix).flatMap { $0 > configured(config) ? $0 : nil }
        return State(
            host: key, configuredBytes: configured(config), ceilingBytes: ceiling(config),
            currentBytes: currentLocked(host: key, config: config), grownBytes: grown,
            tooLargeLimitBytes: saved(keyPrefix), rejectedBytes: saved(rejectedKeyPrefix),
            timeoutLimitBytes: timeoutLimits[key])
    }

    /// Hosts with saved learned values.
    public static func learnedHosts() -> [String] {
        let prefixes = [keyPrefix, grownKeyPrefix, rejectedKeyPrefix]
        var hosts = Set<String>()
        for key in UserDefaults.standard.dictionaryRepresentation().keys {
            if let prefix = prefixes.first(where: { key.hasPrefix($0) }) {
                hosts.insert(String(key.dropFirst(prefix.count)))
            }
        }
        lock.lock()
        hosts.formUnion(timeoutLimits.keys)
        lock.unlock()
        return hosts.sorted()
    }

    /// Forget what was learned about `host` (or every host).
    public static func reset(host: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        let prefixes = [keyPrefix, grownKeyPrefix, rejectedKeyPrefix]
        if let host = host.map(hostKey) {
            prefixes.forEach { defaults.removeObject(forKey: $0 + host) }
            timeoutLimits[host] = nil
            successes[host] = nil
            fullSuccesses[host] = nil
        } else {
            for key in defaults.dictionaryRepresentation().keys
            where prefixes.contains(where: { key.hasPrefix($0) }) {
                defaults.removeObject(forKey: key)
            }
            timeoutLimits = [:]
            successes = [:]
            fullSuccesses = [:]
        }
    }
}
