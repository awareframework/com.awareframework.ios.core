//
//  DataSyncHelper.swift
//  com.aware.ios.sensor.core
//
//  Created by Yuuki Nishiyama on 2018/10/18.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import SwiftyJSON

// MARK: - Constants

/**
 * Constants definition for DbSyncHelper
 */
private struct DbSyncConstants {
    static let userDefaultsKeyPrefix = "aware.sync.task.last_uploaded_id"
    static let sessionQueueLabel = "com.aware.urlsession.queue"
    static let backgroundSessionIdentifierPrefix = "aware.sync.task.identifier"
    static let sharedContainerIdentifier = "aware.sync.task.shared.container.identifier"
    
    // Timeout values
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 300
    
    // Retry and delay values
    static let retryDelay: TimeInterval = 1.0
    static let nextBatchDelay: TimeInterval = 0.1
    
    // HTTP Status codes
    static let httpSuccessRange = 200..<300
    static let httpNotFoundStatus = 404
    
    // Excluded fields for compact format
    static let excludedCompactFields: Set<String> = ["os", "jsonVersion", "deviceId", "timezone"]
}

/**
 * DbSyncUtils - Utility class for database synchronization
 * 
 * Provides functionality to save and retrieve the ID of the last uploaded data in UserDefaults.
 * This enables incremental synchronization (synchronizing only new data after the last sync).
 */
struct DbSyncUtils {
    
    /**
     * Save the ID of the last uploaded data for the specified table
     * 
     * @param id ID of the last uploaded data
     * @param tableName Table name (used as identifier)
     */
    static func setLastUploadedId(_ id: Int64, for tableName: String) {
        let key = "\(DbSyncConstants.userDefaultsKeyPrefix).\(tableName)"
        UserDefaults.standard.setValue(id, forKey: key)
        UserDefaults.standard.synchronize()
    }
    
    /**
     * Get the ID of the last uploaded data for the specified table
     * 
     * @param tableName Table name
     * @return ID of the last uploaded data (0 if not exists)
     */
    static func getLastUploadedId(for tableName: String) -> Int64 {
        let key = "\(DbSyncConstants.userDefaultsKeyPrefix).\(tableName)"
        let lastUploadedId = UserDefaults.standard.integer(forKey: key)
        return Int64(lastUploadedId)
    }
    
    /**
     * Clear the ID of the last uploaded data for the specified table
     * 
     * @param tableName Table name
     */
    static func clearLastUploadedId(for tableName: String) {
        let key = "\(DbSyncConstants.userDefaultsKeyPrefix).\(tableName)"
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Types and Enums

/**
 * Enum representing synchronization state
 */
private enum SyncState: Equatable {
    case idle
    case active
    case cancelling
    case completed
    case failed(Error)
    
    static func == (lhs: SyncState, rhs: SyncState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.active, .active), (.cancelling, .cancelling), (.completed, .completed):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

/**
 * Enum representing HTTP response result
 */
private enum ResponseResult {
    case success
    case failure(Error)
    case serverError(Int)
}

/**
 * Data format types
 */
private enum DataFormat {
    case standard
    case compact
}

/**
 * DbSyncHelper - Main class for managing database synchronization
 * 
 * This class handles data synchronization from local database to server.
 * Main features:
 * - Efficient data upload through batch processing
 * - Asynchronous communication using URLSession
 * - Progress reporting and error handling
 * - Thread-safe concurrent execution control
 * - Background execution support
 */
open class DbSyncHelper: NSObject {

    // MARK: - Properties
    
    /// Buffer to accumulate received data from server
    private var receivedData = Data()
    
    /// URLSession instance used for HTTP communication (private)
    private var urlSession: URLSession?
    
    /// Queue used for synchronizing URLSession operations
    private let sessionQueue = DispatchQueue(label: DbSyncConstants.sessionQueueLabel, qos: .utility)
    
    /// Current state of synchronization process
    private var syncState: SyncState = .idle
    
    /// Timestamp when sync started (for timeout detection)
    private var syncStartTime: TimeInterval = 0
    
    /// Flag indicating whether this is the last batch
    private var isLastBatch = false
    
    /// Property indicating whether session is active (for improved state management convenience)
    private var isSessionActive: Bool {
        get {
            // Check for sync timeout (5 minutes)
            let currentTime = Date().timeIntervalSince1970
            let syncTimeout: TimeInterval = 300 // 5 minutes
            
            switch syncState {
            case .active, .cancelling:
                // Check if sync has been running too long
                if syncStartTime > 0 && (currentTime - syncStartTime) > syncTimeout {
                    if config.debug {
                        logInfo("Sync timeout detected, forcing reset")
                    }
                    syncState = .idle
                    syncStartTime = 0
                    return false
                }
                return true
            default:
                return false
            }
        }
        set {
            if newValue {
                syncState = .active
                syncStartTime = Date().timeIntervalSince1970
            } else {
                syncState = .idle
                syncStartTime = 0
            }
        }
    }
    
    // MARK: - Core Dependencies
    
    /// Database engine (responsible for data retrieval and deletion)
    var engine:Engine
    
    /// Server hostname for synchronization
    var host:String
    
    /// Target table name for synchronization
    var tableName:String
    
    /// Synchronization configuration (batch size, debug flags, etc.)
    var config:DbSyncConfig
    
    /// Completion callback for synchronization
    var completion:DbSyncCompletionHandler? = nil
    
    // MARK: - State Management
    
    /// ID of the last uploaded data
    var lastUploadedId:Int64 = 0
    
    /// ID of the last data in current batch
    var idOfLastCandidate:Int64?
    
    /// Current progress (0.0 - 1.0)
    var progress:Double = 0.0
    
    /// Number of data items in current batch
    var currentNumOfCandidates:Int = 0
    
    /// Total number of data items at sync start (for progress calculation)
    var originalNumOfCandidates:Int = 0
    
    /// Total number of records uploaded in current sync session
    var totalUploadedRecords:Int = 0
    
    // MARK: - Customization Handlers
    
    /// Handler to customize HTTP request body
    public var createHttpRequestBodyHandler:((String)->String)?
    
    /// Handler to customize URLRequest
    public var createURLRequestHandler:((URLRequest)->URLRequest)?
    
    // MARK: - Initialization
    
    /**
     * DbSyncHelper initializer
     * 
     * @param engine Database engine
     * @param host Server host for synchronization (including protocol)
     * @param tableName Target table name for synchronization
     * @param config Synchronization configuration
     */
    public init(engine:Engine, host:String, tableName:String, config:DbSyncConfig){
        self.engine     = engine
        // Trim whitespace from host and table names (input normalization)
        self.host       = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tableName  = tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.config     = config
        super.init()
    }
    
    // MARK: - Debug Logging
    
    /**
     * Log a message at the specified debug level
     */
    private func log(_ level: DbSyncDebugLevel, _ message: String, function: String = #function) {
        guard config.debug && level.rawValue <= config.debugLevel.rawValue else { return }
        
        let prefix = "AWARE::Core"
        let levelStr = "[\(level.description.uppercased())]"
        let tableStr = "[\(tableName)]"
        let funcStr = level == .verbose || level == .trace ? "[\(function)]" : ""
        
        print(prefix, levelStr, tableStr, funcStr, message)
    }
    
    /**
     * Convenience methods for different log levels
     */
    private func logError(_ message: String, function: String = #function) {
        log(.error, message, function: function)
    }
    
    private func logWarning(_ message: String, function: String = #function) {
        log(.warning, message, function: function)
    }
    
    private func logInfo(_ message: String, function: String = #function) {
        log(.info, message, function: function)
    }
    
    private func logVerbose(_ message: String, function: String = #function) {
        log(.verbose, message, function: function)
    }
    
    private func logTrace(_ message: String, function: String = #function) {
        log(.trace, message, function: function)
    }
    
    // MARK: - Public Interface
    
    /**
     * Start data synchronization process
     * 
     * This method runs asynchronously and performs the following:
     * 1. Check and control concurrent execution
     * 2. Cancel existing tasks
     * 3. Retrieve target data for synchronization
     * 4. Execute upload in batch units
     * 
     * @param completion Completion callback for synchronization
     */
    open func run(completion: DbSyncCompletionHandler?) {
        logTrace("run() started")
        
        // Check if another sync is already in progress
//        guard !isSessionActive else {
//            logVerbose("run() detected concurrent sync, handling...")
//            handleConcurrentSyncAttempt(completion: completion)
//            return
//        }
        
        logVerbose("run() proceeding to start sync process")
        // Start the sync process
        startSyncProcess(completion: completion)
    }
    
    // MARK: - Private Sync Helpers
    
    /**
     * Handle when sync is already in progress
     */
    private func handleConcurrentSyncAttempt(completion: DbSyncCompletionHandler?) {
        logTrace("handleConcurrentSyncAttempt() started")
        logInfo("Sync already in progress, waiting...")
        
        // Check retry limits and handle accordingly
        if shouldStopRetrying() {
            logVerbose("handleConcurrentSyncAttempt() calling handleMaxRetriesReached()")
            handleMaxRetriesReached(completion: completion)
        } else {
            logVerbose("handleConcurrentSyncAttempt() calling scheduleRetry()")
            scheduleRetry(completion: completion)
        }
        
        logTrace("handleConcurrentSyncAttempt() completed")
    }
    
    /**
     * Check if we should stop retrying based on limits
     */
    private func shouldStopRetrying() -> Bool {
        logTrace("shouldStopRetrying() checking retry limits")
        
        let maxRetries = 10
        let currentRetries = UserDefaults.standard.integer(forKey: "aware.sync.retries.\(tableName)")
        let shouldStop = currentRetries >= maxRetries
        
        logTrace("shouldStopRetrying() currentRetries: \(currentRetries)/\(maxRetries), shouldStop: \(shouldStop)")
        
        return shouldStop
    }
    
    /**
     * Handle when max retries are reached
     */
    private func handleMaxRetriesReached(completion: DbSyncCompletionHandler?) {
        logTrace("handleMaxRetriesReached() started")
        logWarning("Max retries reached, forcing state reset")
        
        resetRetryCounters()
        forceResetSyncState()
        
        let error = NSError(domain: "DbSyncHelper", code: -2, 
                           userInfo: [NSLocalizedDescriptionKey: "Max retry attempts reached, state reset"])
        
        logTrace("handleMaxRetriesReached() calling completion with error")
        
        completion?(false, error)
        
        logTrace("handleMaxRetriesReached() completed")
    }
    
    /**
     * Schedule a retry attempt
     */
    private func scheduleRetry(completion: DbSyncCompletionHandler?) {
        logTrace("scheduleRetry() started")
        
        let currentRetries = UserDefaults.standard.integer(forKey: "aware.sync.retries.\(tableName)")
        UserDefaults.standard.set(currentRetries + 1, forKey: "aware.sync.retries.\(tableName)")
        
        // Calculate delay with exponential backoff (max 10 seconds)
        let delay = min(DbSyncConstants.retryDelay * pow(1.5, Double(currentRetries)), 10.0)
        
        logTrace("scheduleRetry() retry #\(currentRetries + 1), delay: \(delay)s")
        
        sessionQueue.asyncAfter(deadline: .now() + delay) {
            self.logTrace("scheduleRetry() executing delayed retry")
            self.run(completion: completion)
        }
        
        logTrace("scheduleRetry() scheduled")
    }
    
    /**
     * Reset retry counters
     */
    private func resetRetryCounters() {
        UserDefaults.standard.removeObject(forKey: "aware.sync.retries.\(tableName)")
    }
    
    /**
     * Force reset sync state to break deadlocks
     */
    private func forceResetSyncState() {
        syncState = .idle
        invalidateSession(waitForTasks: false)
    }
    
    /**
     * Start the actual sync process
     */
    private func startSyncProcess(completion: DbSyncCompletionHandler?) {
        if config.debug {
            logVerbose("→ startSyncProcess() started")
        }
        
        resetRetryCounters()
        self.completion = completion
        self.isSessionActive = true
        
        if config.debug {
            logVerbose("→ startSyncProcess() set session active, dispatching to background queue")
        }
        
        sessionQueue.async { [weak self] in
            self?.executeSyncWorkflow()
        }
        
        if config.debug {
            logVerbose("→ startSyncProcess() dispatched")
        }
    }
    
    /**
     * Execute the main sync workflow
     */
    private func executeSyncWorkflow() {
        if config.debug {
            logVerbose("→ executeSyncWorkflow() started")
        }
        
        cancelAllTasks { [weak self] in
            if self?.config.debug == true {
                self?.logVerbose("→ executeSyncWorkflow() tasks cancelled, proceeding to data sync")
            }
            self?.performDataSync()
        }
    }
    
    /**
     * Perform the actual data synchronization
     */
    private func performDataSync() {
        if config.debug {
            logVerbose("→ performDataSync() started")
        }
        
        // Get previously synced ID
        lastUploadedId = DbSyncUtils.getLastUploadedId(for: tableName)
        
        if config.debug {
            logVerbose("→ performDataSync() lastUploadedId: \(lastUploadedId)")
        }
        
        // Get initial data count for progress calculation (first time only)
        if originalNumOfCandidates == 0 {
            originalNumOfCandidates = engine.count(filter: "id > \(lastUploadedId)")
            // Reset upload progress tracking for new sync session
            totalUploadedRecords = 0
            if config.debug {
                logVerbose("→ performDataSync() originalNumOfCandidates: \(originalNumOfCandidates), reset totalUploadedRecords")
            }
        }
        
        // Get target data for synchronization
        let candidates = getUploadCandidates(lastUploadedId: lastUploadedId, limit: config.batchSize)
        
        if config.debug {
            logVerbose("→ performDataSync() found \(candidates.count) candidates, dispatching to upload")
        }
        
        // Start upload process on main thread
        DispatchQueue.main.async {
            self.logVerbose("calling upload() on main thread")
            self.upload(candidates)
        }
        
        logTrace("performDataSync() completed")
    }
    
    // MARK: - Data Management
    
    /**
     * Get upload candidate data
     * 
     * Retrieves data with IDs greater than the specified ID up to the specified count.
     * This enables incremental synchronization.
     * 
     * @param lastUploadedId ID of the last uploaded data
     * @param limit Maximum number of items to retrieve
     * @return Array of upload candidate data
     */
    open func getUploadCandidates(lastUploadedId:Int64, limit:Int) -> Array<Dictionary<String, Any>>{
        let filter = "id > \(lastUploadedId)"
        let candidates = self.engine.fetch(filter: filter, limit:limit)
        return candidates ?? []
    }
    
    /**
     * Remove uploaded candidate data
     * 
     * Deletes uploaded data to save local storage space
     * after synchronization completion.
     * 
     * @param lastUploadedId Base ID for deletion target
     * @param limit Maximum number of items to delete
     */
    open func removeUploadedCandidates(lastUploadedId:Int64, limit:Int) {
        let filter = "id > \(lastUploadedId)"
        if self.config.debug {
            logVerbose("Remove uploaded data: \(filter) & limit \(limit)")
        }
        self.engine.remove(filter: filter, limit:limit)
    }
    
    // MARK: - Private Helper Methods
    
    /**
     * Build HTTP request body
     * 
     * @param candidates Upload target data array
     * @return Built request body string
     * @throws JSONSerialization error
     */
    private func buildRequestBody(from candidates: Array<Dictionary<String, Any>>) throws -> String {
        let deviceId = AwareUtils.getCommonDeviceId()
        var data = ""
        
        // Compact data format processing
        if (self.config.compactDataFormat) {
            // Aggregate data by column (to reduce transfer volume)
            var aggregatedData: [String: [Any]] = [:]
            for dict in candidates {
                for (key, value) in dict {
                    // Exclude common system fields
                    if !DbSyncConstants.excludedCompactFields.contains(key) {
                        aggregatedData[key, default: []].append(value)
                    }
                }
            }
            let jsonData = try JSONSerialization.data(withJSONObject:aggregatedData)
            data = String(data: jsonData, encoding: .utf8)!
        }else{
            // Standard format (row by row)
            let jsonData = try JSONSerialization.data(withJSONObject: candidates, options: [])
            data = String(data: jsonData, encoding: .utf8)!
        }
        
        // Build request body in URL-encoded format
        var requestStr = "device_id=\(deviceId)&data=\(data)"
        
        // Apply custom request body handler
        if let handler = self.createHttpRequestBodyHandler{
            requestStr = handler(requestStr)
        }
        
        return requestStr
    }
    
    /**
     * Build HTTP request
     * 
     * @param requestBody Request body
     * @return Built URLRequest
     */
    private func buildHTTPRequest(with requestBody: String) -> URLRequest? {
        // Send HTTP request
        let hostName = AwareUtils.cleanHostName(self.host)
        
        // Encode table name to URL-safe format
        let safeTableName = self.tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self.tableName
        
        // Build endpoint URL
        guard let url = URL(string: "https://\(hostName)/\(safeTableName)/insert") else {
            return nil
        }
        
        // Configure HTTP request
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = requestBody.data(using: .utf8)
        request.timeoutInterval = DbSyncConstants.requestTimeout
        request.httpMethod = "POST"
        request.allowsCellularAccess = true
        
        // Apply custom request handler
        if let handler = self.createURLRequestHandler {
            request = handler(request)
        }
        
        return request
    }
    
    /**
     * Execute upload completion processing
     * 
     * @param responseState Server response state
     * @param error Error (if any)
     */
    private func handleUploadCompletion(responseState: Bool, error: Error?) {
        if responseState {
            // Success processing branch
            if isLastBatch {
                handleSyncCompletion(success: true, error: error)
            } else {
                handleNextBatch()
            }
        } else {
            // Failure processing
            handleSyncCompletion(success: false, error: error)
        }
    }
    
    /**
     * Synchronization completion processing
     * 
     * @param success Whether successful
     * @param error Error (if any)
     */
    private func handleSyncCompletion(success: Bool, error: Error?) {
        // Set final state
        if success {
            syncState = .completed
            logInfo("A sync process is done!")
        } else {
            syncState = .failed(error ?? NSError(domain: "DbSyncHelper", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown sync error"]))
            invalidateSession(waitForTasks: false)
            logError("A sync task is failed.")
        }
        
        // Report 100% progress
        if let pCallback = self.config.progressHandler {
            DispatchQueue.main.async {
                pCallback(success ? 1.0 : 0.0, error)
            }
        }
        
        // Call completion callback
        if let callback = self.completion {
            DispatchQueue.main.async {
                callback(success, error)
            }
        }
        
        // Reset state to idle after completion/failure to allow future syncs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.syncState = .idle
            if self?.config.debug == true {
                self?.logTrace("Sync state reset to idle")
            }
        }
    }
    
    /**
     * Start synchronization of next batch
     */
    private func handleNextBatch() {
        logInfo("A sync task is done. Execute a next sync task.")
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + DbSyncConstants.nextBatchDelay) { [weak self] in
            // Calculate and report progress
            if let pCallback = self?.config.progressHandler {
                // Calculate progress based on uploaded records vs total records
                let uploadedItems = Double(self?.totalUploadedRecords ?? 0)
                let totalItems = Double(self?.originalNumOfCandidates ?? 1)
                
                // Progress is calculated as percentage of uploaded records
                let p = totalItems > 0 ? min(1.0, max(0.0, uploadedItems / totalItems)) : 1.0
                
                if self?.config.debug == true {
                    let percentage = Int(p * 100)
                    self?.logVerbose("Progress: \(uploadedItems)/\(totalItems) records (\(percentage)%)")
                }
                
                DispatchQueue.main.async{
                    pCallback(p, nil)
                }
            }
            
            // Execute next sync (custom queue or default queue)
            if let queue = self?.config.dispatchQueue {
                queue.async {
                    self?.run(completion: self?.completion)
                }
            }else{
                self?.run(completion: self?.completion)
            }
        }
    }

    // MARK: - Upload Processing
    
    /**
     * Execute data upload process
     * 
     * This function performs the following processes:
     * 1. Data validation and state management
     * 2. JSON serialization
     * 3. HTTP request construction and transmission
     * 
     * @param candidates Array of data to be uploaded
     */
    open func upload(_ candidates: Array<Dictionary<String, Any>>){
        if config.debug {
            logVerbose("upload() started with \(candidates.count) candidates")
        }
        
        // Record current batch size
        self.currentNumOfCandidates = candidates.count
        
        // Record ID of the last data (used when sync is completed)
        self.idOfLastCandidate = nil
        if let lastCandidate = candidates.last {
            if let candidateId = lastCandidate["id"] as? Int64 {
                self.idOfLastCandidate = candidateId
                if config.debug {
                    logTrace("idOfLastCandidate: \(candidateId)")
                }
            }
        }
        
        // Output debug information
        if self.config.debug {
            logInfo("Data count = \(candidates.count)")
        }
        
        // If data is empty, process as sync completed
        if candidates.count == 0 {
            syncState = .completed
            if (self.config.debug) {
                logInfo("A sync process is done: No Data")
            }
            // Report progress as 100%
            if let pCallback = self.config.progressHandler {
                DispatchQueue.main.async {
                    pCallback(1.0, nil)
                }
            }
            // Call completion callback
            if let callback = self.completion {
                DispatchQueue.main.async {
                    callback(true, nil)
                }
            }
            
            // Reset state to idle after completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.syncState = .idle
                if self?.config.debug == true {
                    self?.logTrace("Sync state reset to idle (no data)")
                }
            }
            return
        }
        
        // Determine if this is the final batch (for controlling next run() call)
        if candidates.count < self.config.batchSize {
            self.isLastBatch = true
        }
        
        do {
            // Build HTTP request body
            let requestBody = try buildRequestBody(from: candidates)
            
            // Build HTTP request
            if let request = buildHTTPRequest(with: requestBody) {
                let session = getOrCreateURLSession()
                
                // Create and execute data task
                let task = session.dataTask(with: request)
                
                if !self.config.test {
                    // Send actual HTTP request
                    task.resume()
                }else{
                    // Test mode: process as success immediately
                    self.urlSession(session, task: task, didCompleteWithError: nil)
                }
            }
        } catch {
            // Handle JSON serialization error
            if self.config.debug {
                logError("JSON serialization error: \(error)")
            }
            // Stop sync on error and call callback
            syncState = .failed(error)
            if let callback = self.completion {
                DispatchQueue.main.async {
                    callback(false, error)
                }
            }
            
            // Reset state to idle after error
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.syncState = .idle
                if self?.config.debug == true {
                    self?.logTrace("Sync state reset to idle (JSON error)")
                }
            }
        }
    }
    
    // MARK: - URLSession Management
    
    /**
     * Create URLSession instance
     * 
     * Creates normal session or background session according to configuration.
     * Session settings include timeout values, cellular access permission, etc.
     * 
     * @return Configured URLSession instance
     */
    private func createURLSession() -> URLSession {
        let sessionConfig: URLSessionConfiguration
        
        if self.config.backgroundSession {
            // Background session (continues even when app is in background)
            sessionConfig = URLSessionConfiguration.background(withIdentifier: "\(DbSyncConstants.backgroundSessionIdentifierPrefix).\(tableName)")
        } else {
            // Normal session
            sessionConfig = URLSessionConfiguration.default
        }
        
        // Apply session settings
        sessionConfig.allowsCellularAccess = true
        sessionConfig.timeoutIntervalForRequest = DbSyncConstants.requestTimeout
        sessionConfig.timeoutIntervalForResource = DbSyncConstants.resourceTimeout
        sessionConfig.sharedContainerIdentifier = DbSyncConstants.sharedContainerIdentifier
        
        return URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
    }
    
    /**
     * Get or create URLSession (thread-safe)
     * 
     * Reuses existing session if available, otherwise creates new one.
     * Thread safety is guaranteed by synchronous execution in sessionQueue.
     * 
     * @return URLSession instance
     */
    private func getOrCreateURLSession() -> URLSession {
        return sessionQueue.sync { [weak self] in
            guard let self = self else {
                // Fallback when self is already released
                return URLSession.shared
            }
            
            if let existingSession = self.urlSession {
                return existingSession
            }
            
            let newSession = self.createURLSession()
            self.urlSession = newSession
            return newSession
        }
    }
    
    /**
     * Invalidate URLSession
     * 
     * You can choose the session termination method:
     * - waitForTasks = true: Wait for running tasks to complete before terminating
     * - waitForTasks = false: Cancel tasks immediately and terminate
     * 
     * @param waitForTasks Whether to wait for running tasks to complete
     */
    private func invalidateSession(waitForTasks: Bool = false) {
//        sessionQueue.async { [weak self] in
//            guard let self = self, let session = self.urlSession else { return }
            
            if waitForTasks {
                self.urlSession?.finishTasksAndInvalidate()
            } else {
                self.urlSession?.invalidateAndCancel()
            }
            
            self.urlSession = nil
//        }
    }
    
    /**
     * Cancel all running tasks
     * 
     * Uses DispatchGroup to wait for completion of all task cancellations.
     * 
     * @param completion Callback when all task cancellations are completed
     */
    private func cancelAllTasks(completion: @escaping () -> Void) {
        guard let session = urlSession else {
            completion()
            return
        }
        
        session.getAllTasks { [weak self] tasks in
            let group = DispatchGroup()
            
            for task in tasks {
                group.enter()
                if self?.config.debug == true {
                    self?.logWarning("session task is canceled.")
                }
                task.cancel()
                group.leave()
            }
            
            // Wait for completion of all task cancellations
            group.notify(queue: .main) {
                completion()
            }
        }
    }
    
    // MARK: - URLSession Delegate Methods
    
    /**
     * Process when HTTP response is received
     * 
     * Determines whether to continue or stop data reception based on HTTP status code.
     * If in 200-299 range, process continues as normal, otherwise stops as error.
     * 
     * @param session URLSession instance
     * @param dataTask Data task
     * @param response HTTP response
     * @param completionHandler Handler to specify how to process the response
     */
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        
        if let httpResponse = response as? HTTPURLResponse{
            if DbSyncConstants.httpSuccessRange.contains(httpResponse.statusCode) {
                // 2xx status codes are processed as success
                completionHandler(URLSession.ResponseDisposition.allow);
            }else{
                // Other status codes are processed as error and stopped
                completionHandler(URLSession.ResponseDisposition.cancel);
                logVerbose("Response: \(response)")
            }
        }
    }
    
    /**
     * Process when URLSession becomes invalid
     * 
     * Outputs to debug log if an error occurs during session invalidation.
     * 
     * @param session Invalidated URLSession
     * @param error Error during invalidation (if any)
     */
    open func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let e = error {
            logError("Exception in urlSession task: \(#function)")
            logError("Error details: \(e)")
        }
    }
    
    /**
     * Process when HTTP task is completed (most important method)
     * 
     * This method determines the success/failure of data upload and
     * controls subsequent processing (progress update, next batch execution, completion notification, etc.).
     * 
     * Process flow:
     * 1. Error and response validation
     * 2. Server response JSON parsing
     * 3. On success: Data deletion, ID update, next batch or completion processing
     * 4. On failure: Error handling and termination processing
     * 
     * @param session URLSession instance
     * @param task Completed URLSessionTask
     * @param error Task error (if any)
     */
    open func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let responseState = evaluateResponseState(error: error)
        
        // Debug output of server response
        if self.config.debug {
            let response = String(data: receivedData, encoding: .utf8) ?? ""
            logVerbose("Server Response: \(response)")
        }
        
        // Process on successful upload
        if responseState {
            if config.debug {
                logInfo("Success: A sync task is done correctly.")
            }
            
            // Update total uploaded records count
            totalUploadedRecords += currentNumOfCandidates
            if config.debug {
                logVerbose("Updated totalUploadedRecords: \(totalUploadedRecords)")
            }
            
            // Properly terminate session if this is the final batch
            if isLastBatch {
                invalidateSession(waitForTasks: true)
            }
            
            // Delete uploaded data (according to settings)
            if config.removeAfterSync {
                removeUploadedCandidates(lastUploadedId: lastUploadedId, limit: config.batchSize)
            }
            
            // Finally update uploaded ID
            updateLastUploadedId()
        } else {
            // Immediately terminate session on upload failure
            invalidateSession(waitForTasks: false)
        }
        
        // Clear received data buffer
        receivedData = Data()
        
        // Execute subsequent processing
        handleUploadCompletion(responseState: responseState, error: error)
    }
    
    /**
     * Evaluate response state
     * 
     * @param error Network error (if any)
     * @return Whether the response is successful
     */
    private func evaluateResponseState(error: Error?) -> Bool {
        if let unwrappedError = error {
            // In case of network error or HTTP error
            logError("failed: \(unwrappedError)")
            return false
        }
        
        // Always process as success in test mode
        if config.test { return true }
        
        // Parse response data
        /**
         * NOTE: Handling special circumstances of server implementation
         * aware-server-node returns 201 even for invalid queries,
         * so check JSON in response body to determine actual success/failure
         */
        
        do {
            if !receivedData.isEmpty {
                let json = try JSON(data: receivedData)
                if json["status"].intValue == DbSyncConstants.httpNotFoundStatus {
                    // When server returns error response
                    return false
                } else {
                    // Normal response
                    return true
                }
            }
        } catch {
            if config.debug {
                logError("Error: A JSON convert error: \(error)")
            }
            // Even with JSON parsing error, consider upload itself as successful
            return true
        }
        
        return true
    }
    
    /**
     * Update the last uploaded ID
     */
    private func updateLastUploadedId() {
        if let candidateId = idOfLastCandidate {
            DbSyncUtils.setLastUploadedId(candidateId, for: tableName)
            idOfLastCandidate = nil
            if config.debug {
                logVerbose("Regist ID of the last upload object => \(candidateId) : \(lastUploadedId) ~ \(candidateId)")
            }
        }
    }
    
    /**
     * Monitor upload progress (callback during data transmission)
     * 
     * Outputs data transmission progress as percentage.
     * Used for progress display when uploading large data.
     * 
     * @param session URLSession instance
     * @param task Task sending data
     * @param bytesSent Number of bytes sent this time
     * @param totalBytesSent Total bytes sent so far
     * @param totalBytesExpectedToSend Total bytes expected to be sent
     */
    open func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if config.debug {
            let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend) * 100.0
            logVerbose("Upload progress: \(NSString(format: "%.2f", progress))%")
        }
    }
    
    /**
     * Process when receiving data from server
     * 
     * Accumulates received data in internal buffer (receivedData).
     * Since data may be received in multiple parts, concatenate with append.
     * 
     * @param session URLSession instance
     * @param dataTask Task that received data
     * @param data Received data
     */
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if config.debug{
            logTrace("Task completed: \(#function):\(dataTask.taskIdentifier)")
        }
        self.receivedData.append(data)
    }
    
    // MARK: - Public Control Methods
    
    /**
     * Gradually stop synchronization process (recommended)
     * 
     * Stops after waiting for running tasks to complete.
     * Forces stop if not completed within timeout period.
     * 
     * @param timeout Timeout period (seconds, default: 30 seconds)
     * @param handler Callback when stop is completed
     */
    public func stopGracefully(timeout: TimeInterval = 30.0, handler: ((_ completed: Bool) -> Void)? = nil) {
        guard canStop() else {
            handler?(syncState == .idle || syncState == .completed)
            return
        }
        
        if config.debug {
            logInfo("Starting graceful shutdown (timeout: \(timeout)s)")
        }
        
        syncState = .cancelling
        
        // Execute gradual stop with timeout
        let timeoutTimer = DispatchWorkItem { [weak self] in
            if self?.config.debug == true {
                self?.logWarning("Graceful shutdown timed out")
            }
            self?.stopImmediately { handler?(false) }
        }
        
        sessionQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutTimer)
        
        // Execute gradual stop
        sessionQueue.async { [weak self] in
            guard let self = self else {
                timeoutTimer.cancel()
                handler?(false)
                return
            }
            
            self.invalidateSession(waitForTasks: true)
            self.resetSyncState()
            
            timeoutTimer.cancel()
            
            if self.config.debug {
                logInfo("Graceful shutdown completed")
            }
            
            DispatchQueue.main.async {
                handler?(true)
            }
        }
    }
    
    /**
     * Stop synchronization process immediately
     * 
     * Immediately cancels all running tasks and invalidates session.
     * Used in emergency situations or when app is terminating.
     * 
     * @param handler Callback when stop is completed
     */
    public func stopImmediately(_ handler: (() -> Void)? = nil) {
        if config.debug {
            logInfo("Starting immediate shutdown")
        }
        
        syncState = .cancelling
        
        sessionQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { handler?() }
                return
            }
            
            // Cancel all tasks and immediately invalidate session
            self.urlSession?.invalidateAndCancel()
            self.urlSession = nil
            self.resetSyncState()
            
            if self.config.debug {
                logInfo("Immediate shutdown completed")
            }
            
            DispatchQueue.main.async {
                handler?()
            }
        }
    }
    
    /**
     * Legacy stop method (maintained for backward compatibility)
     * 
     * @param handler Callback when stop is completed
     */
    public func stop(_ handler: (() -> Void)? = nil) {
        stopImmediately(handler)
    }
    
    // MARK: - Private Shutdown Helpers
    
    /**
     * Reset sync state
     */
    private func resetSyncState() {
        syncState = .idle
        syncStartTime = 0
        receivedData = Data()
        completion = nil
        isLastBatch = false
        
        // Reset progress state
        currentNumOfCandidates = 0
        originalNumOfCandidates = 0
        totalUploadedRecords = 0
        progress = 0.0
        idOfLastCandidate = nil
    }
    
    /**
     * Destructor
     * 
     * Properly terminates session when object is released,
     * preventing resource leaks.
     */
    deinit {
        invalidateSession(waitForTasks: false)
    }
}

// MARK: - Legacy Code Reference

/**
 * The following is an example of the old version HTTP request implementation (for reference)
 * 
 * This implementation had the following differences:
 * - Request transmission in JSON format
 * - Different endpoint structure
 * - Explicit setting of Content-Type header
 * 
 * The current implementation adopts URL-encoded format to match server specifications.
 */

/*
// Legacy implementation example:
let timestamp = Int64(Date().timeIntervalSince1970/1000.0)
let deviceId = AwareUtils.getCommonDeviceId()
var requestStr = ""
let requestParams: Dictionary<String, Any> = [
    "timestamp": timestamp,
    "deviceId": deviceId,
    "data": dataArray,
    "tableName": self.tableName
]

do {
    let requestObject = try JSONSerialization.data(withJSONObject: requestParams)
    requestStr = String.init(data: requestObject, encoding: .utf8)!
} catch {
    print("Error getting sync data: \(error)")
}

let hostName = AwareUtils.cleanHostName(self.host)
let url = URL.init(string: "https://"+hostName+"/insert/")

if let unwrappedUrl = url, let session = self.urlSession {
    var request = URLRequest.init(url: unwrappedUrl)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.httpBody = requestStr.data(using: .utf8)
    request.timeoutInterval = 30
    request.httpMethod = "POST"
    request.allowsCellularAccess = true
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    
    let task = session.dataTask(with: request)
    task.resume()
}
*/
//}

// MARK: - URLSession Delegate Extensions

extension DbSyncHelper: URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
    // Delegate methods are already implemented, so this section is for explicitly showing protocol conformance
    //}
    
    // MARK: - Public API Documentation
    
    /**
     * Get current sync state
     *
     * @return Current sync state (SyncState enum)
     */
    public func getCurrentSyncState() -> String {
        switch syncState {
        case .idle:
            return "idle"
        case .active:
            return "active"
        case .cancelling:
            return "cancelling"
        case .completed:
            return "completed"
        case .failed(let error):
            return "failed: \(error.localizedDescription)"
        }
    }
    
    /**
     * Get progress information
     *
     * @return Current progress (0.0 - 1.0)
     */
    public func getCurrentProgress() -> Double {
        return progress
    }
    
    /**
     * Get sync statistics
     *
     * @return Sync statistics information
     */
    public func getSyncStatistics() -> [String: Any] {
        let uploadProgress = originalNumOfCandidates > 0 ? 
            Double(totalUploadedRecords) / Double(originalNumOfCandidates) : 0.0
        let uploadPercentage = Int(uploadProgress * 100)
        
        return [
            "tableName": tableName,
            "originalNumOfCandidates": originalNumOfCandidates,
            "currentNumOfCandidates": currentNumOfCandidates,
            "totalUploadedRecords": totalUploadedRecords,
            "lastUploadedId": lastUploadedId,
            "isLastBatch": isLastBatch,
            "progress": progress,
            "uploadProgress": uploadProgress,
            "uploadPercentage": uploadPercentage,
            "syncState": getCurrentSyncState()
        ]
    }
    
    /**
     * Check if sync process is running
     *
     * @return true if running
     */
    public func isSyncActive() -> Bool {
        return isSessionActive
    }
    
    /**
     * Check if stop process is possible
     *
     * @return true if stop is possible
     */
    public func canStop() -> Bool {
        switch syncState {
        case .active, .failed:
            return true
        case .idle, .completed, .cancelling:
            return false
        }
    }
    
}
