//
//  DBSyncManager.swift
//  com.aware.ios.sensor.core
//
//  Created by Yuuki Nishiyama on 2018/03/08.
//

import Foundation
import UIKit

open class DbSyncManager {
    
    private var timer:Timer?
    public var CONFIG:DbSyncManagerConfig
    var TAG:String = "com.aware.manager.sync"
    
    open class DbSyncManagerConfig{
        public init(){}
        public var syncInterval:Double      = 1.0
        public var wifiOnly:Bool            = true
        public var batteryChargingOnly:Bool = false
        public var debug:Bool               = false
        public var sensors                  = Array<AwareSensor>()
    }
    
    open class Builder{
        var builderConfig = DbSyncManagerConfig()
        public init(){}
        
        public func setSyncInterval(_ minutes:Double) -> Builder{
            if minutes > 0 {
                builderConfig.syncInterval = minutes
            }else{
                print("[Error]","[Illegal Parameter]","The interval parameter (minute) has to be more than zero.")
            }
            return self
        }
        
        public func setWifiOnly(_ state:Bool) -> Builder{
            builderConfig.wifiOnly = state
            return self
        }
        
        public func setBatteryOnly(_ state:Bool) -> Builder {
            builderConfig.batteryChargingOnly = state
            return self
        }
        
        public func addSensors(_ sensors:Array<AwareSensor>) -> Builder {
            for sensor in sensors{
                if !isExist(sensor){
                    builderConfig.sensors.append(sensor)
                }
            }
            return self
        }

        public func addSensor(_ sensor:AwareSensor)  -> Builder {
            if !isExist(sensor){
                builderConfig.sensors.append(sensor)
            }
            return self
        }

        public func remove(_ targetSensor:AwareSensor) -> Builder {
            for (index, sensor) in builderConfig.sensors.enumerated() {
                if sensor.id == targetSensor.id {
                    builderConfig.sensors.remove(at: index)
                }
            }
            return self
        }

        private func isExist(_ targetSensor:AwareSensor) -> Bool{
            for sensor in builderConfig.sensors {
                if sensor.id == targetSensor.id {
                    return true
                }
            }
            return false
        }
        
        public func build() -> DbSyncManager{
            return DbSyncManager.init(builderConfig)
        }
        
    }
    
    private init(){
        self.CONFIG = DbSyncManagerConfig()
    }
    
    public init(_ config: DbSyncManagerConfig){
        self.CONFIG = config
    }
    
    
    
    ////////////////////////////////////////////
    
    public func start(){
        if let timer = self.timer {
            timer.invalidate()
            self.timer = nil
            start()
        }else{
            if CONFIG.syncInterval > 0 {
                self.timer = Timer.scheduledTimer(
                    timeInterval:TimeInterval(CONFIG.syncInterval) * 60,
                    target: self,
                    selector: #selector(sync),
                    userInfo: nil,
                    repeats: true)
                // self.timer?.fire()
            }
        }
    }
    
    public func stop(){
        if let timer = self.timer {
            timer.invalidate()
            self.timer = nil
        }
    }
    
    @objc public func sync(_ force:Bool=false){
        
        if CONFIG.batteryChargingOnly && force == false {
            switch UIDevice.current.batteryState {
            case .unknown,.unplugged:
                return
            default:
                break
            }
        }
        
        if CONFIG.wifiOnly && force == false {
            do {
                let reachability = try Reachability()
                if reachability.connection == .cellular || reachability.connection == .unavailable {
                    return
                }
            }catch {
                print(error)
                return
            }
        }
        
        NotificationCenter.default.post(name: Notification.Name.Aware.dbSyncRequest, object:nil)
        
//        for sensor in CONFIG.sensors {
//            sensor.sync()
//        }
    }
}

