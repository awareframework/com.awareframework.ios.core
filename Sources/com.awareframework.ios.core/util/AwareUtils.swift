//
//  AwareUtils.swift
//  CoreAware
//
//  Created by Yuuki Nishiyama on 2018/03/04.
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

public class AwareUtils{

    private static let kDeviceIdKey:String = "com.aware.ios.sensor.core.key.deviceid"
    
    public static func getTimeZone() -> Int {
        let secondsFromGMT = TimeZone.current.secondsFromGMT()
        return secondsFromGMT/60/60 // convert a secounds -> hours
    }
    
    public static func getCommonDeviceId() -> String {
        if let deviceId = UserDefaults.standard.string(forKey: kDeviceIdKey) {
            return deviceId
        }else{
            
            #if os(watchOS)
            let deviceId =  WKInterfaceDevice.current().identifierForVendor?.uuidString
            #elseif os(iOS)
            let deviceId = UIDevice.current.identifierForVendor?.uuidString
            #else
            // macOS or other platforms - use a UUID
            let deviceId: String? = nil
            #endif
                        
            if let did = deviceId {
                UserDefaults.standard.set(did, forKey: kDeviceIdKey)
                return did
            }else{
                let uuid = UUID.init().uuidString
                UserDefaults.standard.set(uuid, forKey: kDeviceIdKey)
                return uuid
            }
        }
    }
    
    /**
     * Remove "http://" and "https://" if the protocol is included in the "host" name.
     */
    public static func cleanHostName(_ hostName:String) -> String {
        var newHostName = hostName;
        if let range = newHostName.range(of: "http://") {
            newHostName.removeSubrange(range)
        }
        
        if let range = newHostName.range(of: "https://") {
            newHostName.removeSubrange(range)
        }
        return newHostName
    }
}
