//
//  UploadSchedulerTests.swift
//  The conditions UploadScheduler checks before an upload starts.
//

import XCTest
@testable import com_awareframework_ios_core

final class UploadSchedulerTests: XCTestCase {

    private func check(_ trigger: UploadScheduler.Trigger, _ c: UploadScheduler.Configuration,
                       wifi: Bool = true, charging: Bool = true, uploading: Bool = false) -> UploadScheduler.SkipReason? {
        UploadScheduler.check(trigger: trigger, configuration: c, wifi: wifi, charging: charging, uploading: uploading)
    }

    func testAutomaticTriggersNeedAutomaticUpload() {
        let off = UploadScheduler.Configuration(automatic: false)
        XCTAssertEqual(check(.timer, off), .automaticUploadOff)
        XCTAssertEqual(check(.chargingStarted, off), .automaticUploadOff)
        XCTAssertEqual(check(.background, off), .automaticUploadOff)
        XCTAssertNil(check(.manual, off), "a manual upload works without automatic upload")
    }

    func testConditions() {
        var c = UploadScheduler.Configuration(automatic: true, wifiOnly: true, chargingOnly: false)
        XCTAssertNil(check(.timer, c))
        XCTAssertEqual(check(.timer, c, wifi: false), .waitingForWiFi)
        XCTAssertEqual(check(.manual, c, wifi: false), .waitingForWiFi, "manual uploads follow Wi-Fi only too")
        XCTAssertEqual(check(.timer, c, uploading: true), .uploadRunning)
        c.wifiOnly = false
        c.chargingOnly = true
        XCTAssertNil(check(.timer, c, wifi: false))
        XCTAssertEqual(check(.timer, c, charging: false), .waitingForCharging)
    }

    func testIntervalIsAtLeastOneMinute() {
        XCTAssertEqual(UploadScheduler.Configuration(interval: 5).interval, 60)
    }

    func testRequestUploadCallsPerformUploadOnceAtATime() {
        let s = UploadScheduler.shared
        s.configuration = .init(automatic: true, wifiOnly: false, chargingOnly: false)
        var finish: (() -> Void)?
        var calls = 0
        s.performUpload = { _, done in calls += 1; finish = done }
        defer { s.performUpload = nil }
        XCTAssertNil(s.requestUpload(.manual))
        XCTAssertTrue(s.isUploading)
        XCTAssertEqual(s.requestUpload(.timer), .uploadRunning)
        XCTAssertEqual(calls, 1)
        finish?()
        XCTAssertFalse(s.isUploading)
        XCTAssertNil(s.requestUpload(.timer))
        XCTAssertEqual(calls, 2)
        finish?()
    }
}
