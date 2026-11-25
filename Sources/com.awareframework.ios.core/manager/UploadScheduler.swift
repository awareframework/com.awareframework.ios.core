//
//  UploadScheduler.swift
//  com.awareframework.ios.core
//
//  When to upload: a repeating timer, the device starting to charge, and (iOS) uploads in the
//  background - an upload that is running when the app leaves the screen goes on while iOS allows
//  it, and iOS runs uploads later (BGProcessingTask) while the app is not running. Before an
//  upload starts, the scheduler checks the conditions (Wi-Fi only, charging only, an upload that
//  is already running).
//
//  The app says how to upload (`performUpload`), so it can show the progress of each sensor; by
//  default the scheduler posts `Notification.Name.Aware.dbSyncRequest`, which every enabled sensor
//  observes (see `AwareSensor.enable()`).
//
//  Usage (iOS):
//
//      // application(_:didFinishLaunchingWithOptions:), before it returns
//      UploadScheduler.shared.registerBackgroundTask(identifier: "com.example.app.upload")
//
//      UploadScheduler.shared.performUpload = { trigger, done in
//          startUploadOfAllSensors(onEnd: done)
//      }
//      UploadScheduler.shared.configuration = .init(automatic: true, interval: 15 * 60, wifiOnly: true)
//
//  `BGTaskSchedulerPermittedIdentifiers` in Info.plist must list the identifier, and
//  `UIBackgroundModes` must contain `processing`.
//

import Foundation
import Network
#if os(iOS)
    import BackgroundTasks
    import UIKit
#endif

public final class UploadScheduler {

    public static let shared = UploadScheduler()

    // MARK: Configuration

    public struct Configuration: Equatable {
        /// Upload by the timer, when charging starts, and in the background. Manual uploads
        /// (`requestUpload(.manual)`) work either way.
        public var automatic: Bool
        /// Time between automatic uploads
        public var interval: TimeInterval
        /// Upload only on Wi-Fi
        public var wifiOnly: Bool
        /// Upload only while the device is charging (or full)
        public var chargingOnly: Bool
        /// Also upload when the device starts charging
        public var uploadOnChargingStart: Bool
        /// Keep uploading in the background (iOS): finish a running upload after the app leaves the
        /// screen, and let iOS run automatic uploads while the app is not running
        public var inBackground: Bool

        public init(automatic: Bool = false, interval: TimeInterval = 15 * 60, wifiOnly: Bool = true,
                    chargingOnly: Bool = false, uploadOnChargingStart: Bool = true, inBackground: Bool = true) {
            self.automatic = automatic
            self.interval = max(60, interval)
            self.wifiOnly = wifiOnly
            self.chargingOnly = chargingOnly
            self.uploadOnChargingStart = uploadOnChargingStart
            self.inBackground = inBackground
        }
    }

    /// What started an upload
    public enum Trigger: String {
        case manual
        case timer
        case chargingStarted
        case background
    }

    /// Why an upload did not start
    public enum SkipReason: String, Error {
        case automaticUploadOff = "Automatic upload is off"
        case uploadRunning = "An upload is already in progress"
        case waitingForWiFi = "Skipped while waiting for Wi-Fi"
        case waitingForCharging = "Skipped while waiting for charging"
        case tooSoonAfterChargingUpload = "An upload started when charging started a moment ago"
    }

    /// The settings. Setting them restarts the timer and the background schedule.
    public var configuration = Configuration() {
        didSet {
            guard configuration != oldValue else { return }
            onMain { self.reschedule() }
        }
    }

    /// How to upload. Call `done` when the upload has ended (or failed), so the scheduler knows
    /// when it may start another one and when the background time can be given back.
    /// Default: post `Notification.Name.Aware.dbSyncRequest` and end at once.
    public var performUpload: ((_ trigger: Trigger, _ done: @escaping () -> Void) -> Void)?

    /// Called on the main thread when an upload is started or skipped (for logs and the UI)
    public var onEvent: ((_ trigger: Trigger, _ skipped: SkipReason?) -> Void)?

    /// Charging that starts again within this time (a loose cable) does not start another upload
    public var chargingStartInterval: TimeInterval = 10 * 60

    // MARK: State

    /// Whether the device is on Wi-Fi (updated by NWPathMonitor)
    public var isWiFiAvailable: Bool { lock.withLock { wifi } }

    /// Whether the device is charging or full
    public var isCharging: Bool {
        #if os(iOS)
            if Thread.isMainThread { return Self.chargingState() }
            return DispatchQueue.main.sync { Self.chargingState() }
        #else
            return true
        #endif
    }

    /// Whether an upload started by the scheduler, or reported with `uploadDidStart()`, is running
    public var isUploading: Bool { lock.withLock { activeUploads > 0 } }

    /// When the last upload started, and why
    public private(set) var lastUploadStart: (date: Date, trigger: Trigger)?

    private let lock = NSLock()
    private var wifi = false
    private var activeUploads = 0
    private var timer: Timer?
    private var lastChargingStartUpload: Date?
    private var wasCharging = false
    private var started = false
    private let pathMonitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    #if os(iOS)
        private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
        private var backgroundTaskIdentifier: String?
    #endif

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let onWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            self?.lock.withLock { self?.wifi = onWiFi }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.awareframework.upload-scheduler.network", qos: .utility))
    }

    // MARK: - Decisions

    /// Whether an upload may start now (pure, for tests).
    public static func check(trigger: Trigger, configuration: Configuration, wifi: Bool, charging: Bool,
                             uploading: Bool) -> SkipReason? {
        if trigger != .manual && configuration.automatic == false { return .automaticUploadOff }
        if uploading { return .uploadRunning }
        if configuration.wifiOnly && wifi == false { return .waitingForWiFi }
        if configuration.chargingOnly && charging == false { return .waitingForCharging }
        return nil
    }

    // MARK: - Uploads

    /// Start an upload if the conditions allow it.
    /// - Returns: Why it did not start, or nil when it started.
    @discardableResult
    public func requestUpload(_ trigger: Trigger) -> SkipReason? {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { requestUpload(trigger) }
        }
        if let reason = Self.check(trigger: trigger, configuration: configuration, wifi: isWiFiAvailable,
                                   charging: isCharging, uploading: isUploading) {
            onEvent?(trigger, reason)
            return reason
        }
        uploadDidStart()
        lastUploadStart = (Date(), trigger)
        onEvent?(trigger, nil)
        let done: () -> Void = { [weak self] in self?.onMain { self?.uploadDidFinish() } }
        if let performUpload {
            performUpload(trigger, done)
        } else {
            NotificationCenter.default.post(name: Notification.Name.Aware.dbSyncRequest, object: nil)
            done()
        }
        return nil
    }

    /// Report an upload the app started itself (for example a single sensor), so the scheduler
    /// does not start another one meanwhile and keeps it running in the background.
    public func uploadDidStart() {
        lock.withLock { activeUploads += 1 }
    }

    /// Report the end of an upload reported with `uploadDidStart()`.
    public func uploadDidFinish() {
        let idle = lock.withLock { () -> Bool in
            activeUploads = max(0, activeUploads - 1)
            return activeUploads == 0
        }
        #if os(iOS)
            if idle { onMain { self.endBackgroundTime() } }
        #endif
    }

    // MARK: - Start and stop

    /// Start the timer and observe charging and the app state. Called by setting `configuration`
    /// too; call it once at launch.
    public func start() {
        onMain {
            guard self.started == false else { return }
            self.started = true
            self.observe()
            self.reschedule()
        }
    }

    /// Stop the timer and cancel the background schedule.
    public func stop() {
        onMain {
            self.timer?.invalidate()
            self.timer = nil
            #if os(iOS)
                self.cancelBackgroundTask()
            #endif
        }
    }

    private func reschedule() {
        guard started else { return }
        timer?.invalidate()
        timer = nil
        if configuration.automatic {
            let t = Timer.scheduledTimer(withTimeInterval: configuration.interval, repeats: true) { [weak self] _ in
                self?.requestUpload(.timer)
            }
            t.tolerance = min(configuration.interval * 0.1, 60)
            timer = t
        }
        #if os(iOS)
            scheduleBackgroundTask()
        #endif
    }

    private func observe() {
        #if os(iOS)
            UIDevice.current.isBatteryMonitoringEnabled = true
            wasCharging = Self.chargingState()
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.batteryStateDidChange() })
            observers.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.extendRunningUpload()
                self?.scheduleBackgroundTask()
            })
        #endif
    }

    // MARK: - Charging

    #if os(iOS)
        private static func chargingState() -> Bool {
            let state = UIDevice.current.batteryState
            return state == .charging || state == .full
        }

        /// Upload when charging starts (iOS reports it only while the app runs)
        private func batteryStateDidChange() {
            let charging = Self.chargingState()
            defer { wasCharging = charging }
            guard charging, wasCharging == false, configuration.uploadOnChargingStart else { return }
            if let last = lastChargingStartUpload, Date().timeIntervalSince(last) < chargingStartInterval {
                onEvent?(.chargingStarted, .tooSoonAfterChargingUpload)
                return
            }
            if requestUpload(.chargingStarted) == nil {
                lastChargingStartUpload = Date()
            }
        }
    #endif

    // MARK: - Background (iOS)

    #if os(iOS)
        /// Register the background upload task. Call it before `application(_:didFinishLaunchingWithOptions:)`
        /// returns. The identifier must be listed in `BGTaskSchedulerPermittedIdentifiers`.
        public func registerBackgroundTask(identifier: String) {
            backgroundTaskIdentifier = identifier
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let self, let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.runBackgroundTask(task)
            }
        }

        /// An upload that is running when the app enters the background goes on while iOS allows
        private func extendRunningUpload() {
            guard configuration.inBackground, isUploading, backgroundTime == .invalid else { return }
            backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "AWARE upload") { [weak self] in
                // Time is up. Requests in flight end; their rows are sent again at the next upload.
                self?.endBackgroundTime()
            }
        }

        private func endBackgroundTime() {
            guard backgroundTime != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTime)
            backgroundTime = .invalid
        }

        /// Ask iOS to run an upload later, while the app may not be running. iOS chooses the time
        /// (often while the device is charging and idle), never earlier than one interval from now.
        private func scheduleBackgroundTask() {
            guard let identifier = backgroundTaskIdentifier else { return }
            guard configuration.automatic, configuration.inBackground else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                return
            }
            let request = BGProcessingTaskRequest(identifier: identifier)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = configuration.chargingOnly
            request.earliestBeginDate = Date(timeIntervalSinceNow: configuration.interval)
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("[AWARE::UploadScheduler] could not schedule the background upload: \(error)")
            }
        }

        private func cancelBackgroundTask() {
            guard let identifier = backgroundTaskIdentifier else { return }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }

        /// Run by iOS in the background: upload, and complete the task when the upload ends
        private func runBackgroundTask(_ task: BGProcessingTask) {
            scheduleBackgroundTask()
            var completed = false
            let complete = { (success: Bool) in
                guard completed == false else { return }
                completed = true
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = {
                // iOS needs the time back. Requests in flight end; their rows are sent again later.
                complete(false)
            }
            // Wait a moment for the network monitor, which starts with the app
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, completed == false else { return }
                guard self.requestUpload(.background) == nil else { return complete(true) }
                self.waitUntilIdle { complete(true) }
            }
        }

        private func waitUntilIdle(_ then: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return then() }
                self.isUploading ? self.waitUntilIdle(then) : then()
            }
        }
    #endif

    private func onMain(_ work: @escaping () -> Void) {
        Thread.isMainThread ? work() : DispatchQueue.main.async(execute: work)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
