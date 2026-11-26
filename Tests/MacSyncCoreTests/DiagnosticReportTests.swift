import Foundation
import XCTest
@testable import MacSyncCore

final class DiagnosticReportTests: XCTestCase {
    func testTimingDistributionsAreBoundedAndExportedWithoutMessages() throws {
        var timing=DiagnosticTiming()
        for x in [0.001,0.002,0.003,1.2] { timing.observe(x) }
        timing.observe(-1);timing.observe(.infinity)
        XCTAssertEqual(timing.count,4)
        XCTAssertEqual(timing.maximumSeconds,1.2)
        XCTAssertEqual(timing.percentileUpperBound(0.5),0.002)
        XCTAssertEqual(timing.percentileUpperBound(0.95),1.2)
        XCTAssertEqual(timing.buckets.count,DiagnosticTiming.bounds.count+1)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let db=dir.appendingPathComponent("test.sqlite").path
        let log=try SyncActivityLog(path:db)
        log.cycleID="private-cycle"
        let encoded=String(decoding:try JSONEncoder().encode(timing),as:UTF8.self)
        try log.record(level:.info,rootID:"app",action:DiagnosticTiming.prefix+"metric_job_wall",durationSeconds:timing.totalSeconds,message:encoded)
        try log.record(level:.info,rootID:"app",action:DiagnosticTiming.prefix+"metric_copy_preflight",message:"private-message")
        try log.record(level:.info,rootID:"app",action:DiagnosticTiming.prefix+"metric_ui_main_queue_delay",durationSeconds:timing.totalSeconds,message:encoded)
        let data=try DiagnosticReport.make(databasePath:db,since:.distantPast,appVersion:"0.19.4")
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("private-"))
        let report=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(report["schemaVersion"] as? Int,3)
        let records=try XCTUnwrap(report["timingDistributions"] as? [[String:Any]])
        XCTAssertEqual(records.count,2)
        XCTAssertEqual(records[0]["p95UpperBoundSeconds"] as? Double,1.2)
        XCTAssertNotNil(report["environment"])
    }

    func testResourceCounterIntervalsAndRedactedExport() throws {
        let start=DiagnosticResourceCounters(uptime:10,processCPUSeconds:2,completedChildrenCPUSeconds:3,
            processPeakResidentBytes:100,processInputBlocks:10,processOutputBlocks:20,thermal:.nominal,lowPower:false)
        let end=DiagnosticResourceCounters(uptime:20,processCPUSeconds:7,completedChildrenCPUSeconds:15,
            processPeakResidentBytes:200,processInputBlocks:12,processOutputBlocks:25,thermal:.fair,lowPower:true)
        let sample=try XCTUnwrap(DiagnosticResourceSample.between(start,end))
        XCTAssertEqual(sample.processCPUPercentOfOneCore,50)
        XCTAssertEqual(sample.completedChildrenCPUSeconds,12)
        XCTAssertEqual(sample.processPeakResidentBytes,200)
        XCTAssertEqual(sample.processInputBlocks,2)
        XCTAssertEqual(sample.processOutputBlocks,5)
        XCTAssertNil(DiagnosticResourceSample.between(end,start))
        XCTAssertNil(DiagnosticResourceSample.between(start,start))
        XCTAssertNotNil(DiagnosticResourceCounters.read())
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let db=dir.appendingPathComponent("test.sqlite").path
        let log=try SyncActivityLog(path:db)
        let encoded=String(decoding:try JSONEncoder().encode(sample),as:UTF8.self)
        try log.record(level:.info,rootID:"app",action:DiagnosticResourceSample.action,durationSeconds:sample.intervalSeconds,message:encoded)
        try log.record(level:.warning,rootID:"private-root",action:DiagnosticResourceSample.action,message:"private-host")
        let data=try DiagnosticReport.make(databasePath:db,since:.distantPast,appVersion:"0.19.4")
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("private-"))
        let report=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let records=try XCTUnwrap(report["resourceSamples"] as? [[String:Any]])
        XCTAssertEqual(records.count,1)
        let measured=try XCTUnwrap(records[0]["sample"] as? [String:Any])
        XCTAssertEqual(measured["processCPUPercentOfOneCore"] as? Double,50)
        XCTAssertEqual(measured["thermal"] as? String,"fair")
    }

    func testPOSIXMetadataTimingMeasuresExistingEnumerationWithoutAdditionalReads() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        for name in ["one.jpg","two.jpg"] {
            try Data(name.utf8).write(to:dir.appendingPathComponent(name))
        }
        var observed=DiagnosticTiming()
        let baseline=try LocalScanner.scan(root:dir,preferPOSIXMetadata:true)
        let instrumented=try LocalScanner.scan(root:dir,preferPOSIXMetadata:true,onPOSIXMetadataTiming:{observed=$0},measurePOSIXMetadata:true)
        XCTAssertEqual(Set(baseline.map(\.relativePath)),Set(instrumented.map(\.relativePath)))
        XCTAssertEqual(observed.count,2)
        XCTAssertTrue(observed.isValid)
        var aggregate=observed
        aggregate.merge(observed)
        XCTAssertEqual(aggregate.count,4)
        XCTAssertEqual(aggregate.totalSeconds,observed.totalSeconds*2)
    }

    func testExportPaginatesAndRemovesFreeTextAndIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("fixture.sqlite").path
        let writer = try SyncActivityLog(path: db)
        writer.cycleID = "private-cycle"
        for index in 1...501 {
            try writer.record(level: .info, rootID: "private-root", action: "copy",
                relativePath: "private-name.psd", bytes: Int64(index), message: "private-host")
        }
        let data = try DiagnosticReport.make(databasePath: db, since: .distantPast, appVersion: "0.18.9")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(report["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 501)
        XCTAssertEqual(events.first?["bytes"] as? Int, 501)
        XCTAssertEqual(events.last?["bytes"] as? Int, 1)
        XCTAssertEqual(events.first?["item"] as? Int, events.last?["item"] as? Int)
    }
}
