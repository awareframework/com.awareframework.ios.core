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
/// - Default: `DbSyncConfig.maxBatchBytes`, or by server type when it is not set: 4 MB for AWARE Micro
///   (Google App Engine accepts up to 32 MB; the margin keeps uploads short on slow networks and
///   keeps memory use low), 900 KB for other servers (below the nginx default of 1 MB and the PHP
///   default `post_max_size` of 8 MB, which drops larger bodies without an error).
/// - When a host answers 413, half of the rejected body size becomes its limit. This is saved
///   (UserDefaults), so later syncs start with a size the host accepts.
/// - When a request times out, the limit is halved for the running app only (network speed
///   changes), and grows back after `growAfterSuccesses` successful requests.
public enum SyncBatchLimit {

    public static let microDefaultBytes = 4_000_000
    public static let otherDefaultBytes = 900_000
    /// Never below this, so that a sync always makes progress
    public static let minimumBytes = 16_384
    static let growAfterSuccesses = 20
    static let keyPrefix = "aware.sync.max_batch_bytes."

    private static let lock = NSLock()
    private static var timeoutLimits: [String: Int] = [:]
    private static var successes: [String: Int] = [:]

    /// The configured or default limit, before what was learned from the host.
    public static func configured(_ config: DbSyncConfig) -> Int {
        if let bytes = config.maxBatchBytes, bytes > 0 { return max(minimumBytes, bytes) }
        return config.serverType == .aware_micro ? microDefaultBytes : otherDefaultBytes
    }

    /// The limit to use for `host` now.
    public static func current(host: String, config: DbSyncConfig) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var limit = configured(config)
        let saved = UserDefaults.standard.integer(forKey: keyPrefix + host)
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
        let limit = max(minimumBytes, bodyBytes / 2)
        let saved = UserDefaults.standard.integer(forKey: keyPrefix + host)
        UserDefaults.standard.set(saved > 0 ? min(saved, limit) : limit, forKey: keyPrefix + host)
        successes[host] = 0
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
        return limit
    }

    /// A request succeeded: after `growAfterSuccesses` in a row, a timeout limit grows back by half.
    public static func recordSuccess(host: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let t = timeoutLimits[host] else { return }
        let n = (successes[host] ?? 0) + 1
        if n >= growAfterSuccesses {
            timeoutLimits[host] = t + t / 2
            successes[host] = 0
        } else {
            successes[host] = n
        }
    }

    /// Forget what was learned about `host` (or every host).
    public static func reset(host: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let host {
            UserDefaults.standard.removeObject(forKey: keyPrefix + host)
            timeoutLimits[host] = nil
            successes[host] = nil
        } else {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            timeoutLimits = [:]
            successes = [:]
        }
    }
}
