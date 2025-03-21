//
//  DataSyncHelper.swift
//  com.aware.ios.sensor.core
//
//  Created by Yuuki Nishiyama on 2018/10/18.
//

import UIKit
import Foundation
import SwiftyJSON

class DbSyncUtils {
    static func setLastUploadedId(_ id:Int64, _ tableName:String) {
        UserDefaults.standard.setValue(id, forKey: "aware.sync.task.last_uploaded_id.\(tableName)")
        UserDefaults.standard.synchronize()
    }
    
    static func getLastUploadedId(_ tableName:String) -> Int64 {
        let lastUploadedId = UserDefaults.standard.integer(forKey: "aware.sync.task.last_uploaded_id.\(tableName)")
        return Int64(lastUploadedId)
    }
}

open class DbSyncHelper: NSObject, URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {

    var receivedData = Data()
    var urlSession:URLSession?
    
    var endFlag = false
    
    var engine:Engine
    var host:String
    var tableName:String
    var config:DbSyncConfig
    var completion:DbSyncCompletionHandler? = nil
    
    var lastUploadedId:Int64 = 0
    var idOfLastCandidate:Int64?
    
    var progress:Double = 0.0
    var currentNumOfCandidates:Int = 0
    var originalNumOfCandidates:Int = 0
    
    public var createHttpRequestBodyHandler:((String)->String)?
    public var createURLRequestHandler:((URLRequest)->URLRequest)?
    
    public init(engine:Engine, host:String, tableName:String, config:DbSyncConfig){
        self.engine     = engine
        self.host       = host
        self.tableName  = tableName
        self.config     = config
    }
    
    open func run(completion:DbSyncCompletionHandler?){
        
        self.completion = completion
        
        self.urlSession = {
            if self.config.backgroundSession{
                let sessionConfig = URLSessionConfiguration.background(withIdentifier: "aware.sync.task.identifier.\(tableName)")
                sessionConfig.allowsCellularAccess = true
                sessionConfig.sharedContainerIdentifier = "aware.sync.task.shared.container.identifier"
                return URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
            }else{
                let sessionConfig = URLSessionConfiguration.default
                sessionConfig.allowsCellularAccess = true
                sessionConfig.sharedContainerIdentifier = "aware.sync.task.shared.container.identifier"
                return URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
            }
        }()
        
        urlSession?.getAllTasks(completionHandler: { (tasks) in
            if tasks.count == 0 {
                self.lastUploadedId = DbSyncUtils.getLastUploadedId(self.tableName)
                let batchSize = self.config.batchSize
                let candidates = self.getUploadCandidates(lastUploadedId: self.lastUploadedId, limit: batchSize)
                self.upload(candidates)
            }
        })
    }
    
    
    open func getUploadCandidates(lastUploadedId:Int64, limit:Int) -> Array<Dictionary<String, Any>>{
        let filter = "id > \(lastUploadedId)"
        let candidates = self.engine.fetch(filter: filter, limit:limit)
        return candidates ?? []
    }
    
    open func removeUploadedCandidates(lastUploadedId:Int64, limit:Int) {
        let filter = "id > \(lastUploadedId)"
        if self.config.debug {
            print("AWARE::Core","[\(tableName)] Remove uploaded data: \(filter) & limit \(limit)")
        }
        self.engine.remove(filter: filter, limit:limit)
    }
    
    open func upload(_ candidates: Array<Dictionary<String, Any>>){
        
        
        if self.originalNumOfCandidates == 0 {
            self.originalNumOfCandidates = candidates.count
        }
        self.currentNumOfCandidates = candidates.count
        
        self.idOfLastCandidate = nil
        if let lastCandidate = candidates.last {
            if let candidateId = lastCandidate["id"] as? Int64 {
                self.idOfLastCandidate = candidateId
            }
        }
        
        if self.config.debug {
            print("AWARE::Core", self.tableName,
                  "Data count = \(candidates.count)")
        }
        
        if candidates.count == 0 {
            if (self.config.debug) {
                print("AWARE::Core", self.tableName, "A sync process is done: No Data")
            }
            if let pCallback = self.config.progressHandler {
                DispatchQueue.main.async {
                    pCallback(1.0, nil)
                }
            }
            if let callback = self.completion {
                DispatchQueue.main.async {
                    callback(true, nil)
                }
            }
            return
        }
        
        if candidates.count < self.config.batchSize {
            self.endFlag = true
        }
        
        /// set parameter
        let deviceId = AwareUtils.getCommonDeviceId()
        var requestStr = ""
        do{
            var data = ""
            if (self.config.compactDataFormat) {
                var aggregatedData: [String: [Any]] = [:]
                for dict in candidates {
                    for (key, value) in dict {
                        if (key != "os" && key != "jsonVersion" && key != "deviceId" && key != "timezone") {
                            aggregatedData[key, default: []].append(value)
                        }
                    }
                }
                let jsonData = try JSONSerialization.data(withJSONObject:aggregatedData)
                data = String(data: jsonData, encoding: .utf8)!
            }else{
                let jsonData = try JSONSerialization.data(withJSONObject: candidates, options: [])
                data = String(data: jsonData, encoding: .utf8)!
            }
            
            /// main body
            requestStr = "device_id=\(deviceId)&data=\(data)"
            
            if let handler = self.createHttpRequestBodyHandler{
                requestStr = handler(requestStr)
            }
        }catch{
            if self.config.debug {
                print(error)
            }
        }
        
        
        let hostName = AwareUtils.cleanHostName(self.host)
        
        let url = URL.init(string: "https://"+hostName+"/"+self.tableName+"/insert")
        if let unwrappedUrl = url, let session = self.urlSession {
            var request = URLRequest.init(url: unwrappedUrl)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.httpBody =  requestStr.data(using: .utf8)
            request.timeoutInterval = 30
            request.httpMethod = "POST"
            request.allowsCellularAccess = true
            
            if let handler = self.createURLRequestHandler {
                request = handler(request)
            }
            
            let task = session.dataTask(with: request) // dataTask(with: request)
            
            if !self.config.test {
                task.resume()
            }else{
                self.urlSession(session, task: task, didCompleteWithError: nil)
            }
        }
    
    }
    
    //////////
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        
        if let httpResponse = response as? HTTPURLResponse{
            if(httpResponse.statusCode >= 200 && httpResponse.statusCode < 300){
                completionHandler(URLSession.ResponseDisposition.allow);
            }else{
                completionHandler(URLSession.ResponseDisposition.cancel);
                if config.debug { print("AWARE::Core","\( tableName )=>\(response)") }
                // print("\( config.table! )=>\(httpResponse.statusCode)")
            }
        }
    }
    
    open func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let e = error {
            print(#function)
            print(e)
        }
    }
    
    open func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // print(#function)
        var responseState = false
        
        if let unwrappedError = error {
            if config.debug { print("AWARE::Core","failed: \(unwrappedError)") }
        }else{
            /**
             * TODO: this is an error handler
             * aware-server-node ( https://github.com/awareframework/aware-server-node/blob/master/handlers/errorHandlers.js )
             * generates 201 even if the query is wrong ...
             * {"status":404,"message":"Not found"} with error code 201
             *
             * The value should be as follows:
             *{"status":false,"message":"Not found"} with error code 404
             */
            
            do {
                if (!receivedData.isEmpty) {
                    let json = try JSON.init(data: receivedData)
                    if json["status"] == 404 {
                        responseState = false
                    }else{
                        // normal condition
                        responseState = true
                    }
                }
            }catch {
                if ( config.debug ) {
                    print("AWARE::Core","[\(tableName)]: Error: A JSON convert error: \(error)")
                }
                // An upload task is done correctly.
                responseState = true
            }
        }
        
        if (config.test){ responseState = true }
        
        let response = String.init(data: receivedData, encoding: .utf8)
        if let unwrappedResponse = response {
            if self.config.debug {
                print("AWARE::Core","[Server Response][\(self.tableName)][\(self.host)]", unwrappedResponse)
            }
        }
        
        if (responseState){
            if config.debug {
                print("AWARE::Core","[\(tableName)] Success: A sync task is done correctly.")
            }
            
            session.finishTasksAndInvalidate()
            
            // NOTE: データ削除のプロセス
            if (config.removeAfterSync) {
                self.removeUploadedCandidates(lastUploadedId: self.lastUploadedId, limit: self.config.batchSize)
            }
            // NOTE: 最終アップロード済みIDの登録
            if let candidateId = idOfLastCandidate {
                DbSyncUtils.setLastUploadedId(candidateId, tableName)
                idOfLastCandidate = nil
                if (config.debug) {
                    print("AWARE::Core","Regist ID of the last upload object for (\(tableName)) => \(candidateId) : \(lastUploadedId) ~ \(candidateId)")
                }
            }
        }else{
            session.invalidateAndCancel()
        }
        
        receivedData = Data()
        
        if responseState {
            // A sync process is succeed
            if endFlag {
                if config.debug { print("AWARE::Core","A sync process (\(tableName)) is done!") }
                
                if let pCallback = self.config.progressHandler {
                    DispatchQueue.main.async {
                        pCallback(1, nil)
                    }
                }
                
                if let callback = self.completion {
                    DispatchQueue.main.async {
                        callback(true, error)
                    }
                }else{
                    print("self.completion is `nil`")
                }
            }else{
                if config.debug { print("AWARE::Core","A sync task(\(tableName)) is done. Execute a next sync task.") }
                DispatchQueue.main.asyncAfter( deadline: DispatchTime.now() + 1 ) {
                    if let pCallback = self.config.progressHandler {
                        let p = 1.0 - (Double(self.currentNumOfCandidates)/Double(self.originalNumOfCandidates))
                        DispatchQueue.main.async{
                            pCallback(p, nil)
                        }
                    }
                    
                    if let queue = self.config.dispatchQueue {
                        queue.async {
                            self.run(completion: self.completion)
                        }
                    }else{
                        self.run(completion: self.completion)
                    }
                }
            }
        }else{
            //A sync process is failed
            if config.debug { print("AWARE::Core","A sync task (\(tableName)) is faild.") }
            if let callback = self.completion {
                DispatchQueue.main.async {
                    callback(false, error)
                }
            }
        }
    }
    
    
    open func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        /// show progress of an upload process
        if config.debug {
            print("AWARE::Core","\(task.taskIdentifier): \( NSString(format: "%.2f",Double(totalBytesSent)/Double(totalBytesExpectedToSend)*100.0))%")
        }
    }
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if config.debug{
            print("AWARE::Core","\(#function):\(dataTask.taskIdentifier)")
        }
        self.receivedData.append(data)
    }
    
    public func stop() {
        if let session = self.urlSession {
            session.getAllTasks { (sessionTasks) in
                for task in sessionTasks{
                    if self.config.debug { print("AWARE::Core","[\(task.taskIdentifier)] session task is canceled.") }
                    task.cancel()
                }
            }
        }
    }
}



//////////////////////////

//// Set a HTTP Body
//                    let timestamp = Int64(Date().timeIntervalSince1970/1000.0)
//                    let deviceId = AwareUtils.getCommonDeviceId()
//                    var requestStr = ""
//                    let requestParams: Dictionary<String, Any>
//                        = ["timestamp":timestamp,
//                           "deviceId":deviceId,
//                           "data":dataArray,
//                           "tableName":self.tableName]
//                    do{
//                        let requestObject = try JSONSerialization.data(withJSONObject:requestParams)
//                        requestStr = String.init(data: requestObject, encoding: .utf8)!
//                        // requestStr = requestStr.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlUserAllowed)!
//                    }catch{
//                        print(error)
//                    }
//
//                    if self.config.debug {
//                        // print(requestStr)
//                    }
//
//                    let hostName = AwareUtils.cleanHostName(self.host)
//
//                    let url = URL.init(string: "https://"+hostName+"/insert/")
//                    if let unwrappedUrl = url, let session = self.urlSession {
//                        var request = URLRequest.init(url: unwrappedUrl)
//                        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
//                        request.httpBody = requestStr.data(using: .utf8)
//                        request.timeoutInterval = 30
//                        request.httpMethod = "POST"
//                        request.allowsCellularAccess = true
//                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
//                        request.setValue("application/json", forHTTPHeaderField: "Accept")
//                        let task = session.dataTask(with: request) // dataTask(with: request)
//
//                        task.resume()
//                    }

