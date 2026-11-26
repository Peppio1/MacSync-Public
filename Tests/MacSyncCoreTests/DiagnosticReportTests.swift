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

    func testZIPExportUsesOneAnonymizedCollectionAndExpectedSections() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let db=dir.appendingPathComponent("test.sqlite").path
        let log=try SyncActivityLog(path:db)
        log.cycleID="private-cycle"
        try log.record(level:.success,rootID:"private-root",action:"copy",relativePath:"private-name.jpg",
                       bytes:10,durationSeconds:1,message:"private-host")
        let zip=dir.appendingPathComponent("diagnostic.zip")
        try DiagnosticReport.exportZIP(databasePath:db,since:.distantPast,appVersion:"0.19.4",to:zip)
        let unpack=dir.appendingPathComponent("unpack")
        let proc=Process()
        proc.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        proc.arguments=["-x","-k",zip.path,unpack.path]
        try proc.run();proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus,0)
        let names=try FileManager.default.contentsOfDirectory(atPath:unpack.path)
        XCTAssertEqual(Set(names),Set(["riepilogo.json","ambiente.json","risorse.json","sincronizzazioni.json",
            "verifiche_archivio.json","filesystem.json","interfaccia.json","coda.json","eventi.tsv"]))
        for name in names {
            let data=try Data(contentsOf:unpack.appendingPathComponent(name))
            XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("private-"))
        }
        let summary=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:unpack.appendingPathComponent("riepilogo.json"))) as? [String:Any])
        XCTAssertEqual(summary["eventCount"] as? Int,1)
        let tsv=try String(contentsOf:unpack.appendingPathComponent("eventi.tsv"),encoding:.utf8)
        XCTAssertTrue(tsv.contains("\tcopy\t1\t1\t1\t"))
    }

    func testDiagnosticRetentionDoesNotEvictOrdinaryEventsAndViceVersa() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let log=try SyncActivityLog(path:dir.appendingPathComponent("test.sqlite").path)
        for _ in 0..<105 {
            try log.record(level:.info,rootID:"app",action:"copy",message:"")
            try log.record(level:.info,rootID:"app",action:DiagnosticTiming.prefix+"metric_job_wall",message:"")
        }
        XCTAssertEqual(try log.prune(retainNewest:100,maxAgeDays:90),5)
        XCTAssertEqual(try log.pruneDiagnostics(retainNewest:100,maxAgeDays:30),5)
        let rows=try log.technicalPage(limit:500)
        XCTAssertEqual(rows.filter{$0.entry.action=="copy"}.count,100)
        XCTAssertEqual(rows.filter{$0.entry.action.hasPrefix(DiagnosticTiming.prefix)}.count,100)
    }

    func testProfilingExpiresAndStandardUsesLowerCadence() {
        let now=Date(timeIntervalSince1970:1000)
        XCTAssertEqual(DiagnosticCollectionLevel.effective(raw:"profiling",until:1900,now:now),.profiling)
        XCTAssertEqual(DiagnosticCollectionLevel.effective(raw:"profiling",until:999,now:now),.advanced)
        XCTAssertEqual(DiagnosticCollectionLevel.effective(raw:"profiling",until:1901,now:now),.advanced)
        XCTAssertEqual(DiagnosticCollectionLevel.effective(raw:nil,until:0,now:now),.advanced)
        XCTAssertGreaterThan(DiagnosticCollectionLevel.standard.flushInterval,DiagnosticCollectionLevel.advanced.flushInterval)
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
