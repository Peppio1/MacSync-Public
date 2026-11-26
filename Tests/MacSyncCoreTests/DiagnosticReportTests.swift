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
        XCTAssertEqual(report["schemaVersion"] as? Int,2)
        let records=try XCTUnwrap(report["timingDistributions"] as? [[String:Any]])
        XCTAssertEqual(records.count,2)
        XCTAssertEqual(records[0]["p95UpperBoundSeconds"] as? Double,1.2)
        XCTAssertNotNil(report["environment"])
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
