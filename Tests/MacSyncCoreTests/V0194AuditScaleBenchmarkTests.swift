import Foundation
import XCTest
@testable import MacSyncCore

/// Comparative, opt-in metadata workload on the operational QUICK path.
/// Synthetic files only; fixture creation and inventory are timed separately.
final class V0194AuditScaleBenchmarkTests: XCTestCase {
    func testOperationalQuickScale() throws {
        let env=ProcessInfo.processInfo.environment
        guard env["MACSYNC_RUN_AUDIT_SCALE"]=="1" else {
            throw XCTSkip("Opt-in disposable archive scalability benchmark")
        }
        let count=try XCTUnwrap(Int(try XCTUnwrap(env["MACSYNC_SCALE_FILES"])))
        let location=try XCTUnwrap(env["MACSYNC_SCALE_LOCATION"])
        guard [1_000,10_000,50_000,200_000].contains(count),
              ["local","smb"].contains(location) else { return XCTFail("Invalid benchmark parameters") }
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent("macsync-scale-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:base,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:base) }
        let source=base.appendingPathComponent("source")
        try fm.createDirectory(at:source,withIntermediateDirectories:false)
        let parent:URL
        if location=="smb" {
            guard env["MACSYNC_TEST_SMB_HOST"]=="127.0.0.1",
                  env["MACSYNC_TEST_SMB_SHARE"]=="MacSyncCI" else { return XCTFail("Disposable SMB required") }
            parent=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_MOUNT"]))
            let binding=try DirectoryBinding.read(parent)
            guard binding.volume.fileSystem.lowercased()=="smbfs",binding.volume.isStrongIdentity else {
                return XCTFail("Actual mounted SMB required")
            }
        } else { parent=base }
        let target=parent.appendingPathComponent("macsync-scale-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:target) }
        let now={ ProcessInfo.processInfo.systemUptime }
        let fixed=Date(timeIntervalSince1970:1_700_000_000)
        let payload=Data("synthetic".utf8)
        let changed=Data("old".utf8)
        let groups=count/100
        func path(_ i:Int)->String { "group-\(i/100)/file-\(i%100).dat" }
        func put(_ data:Data,_ url:URL) throws {
            try data.write(to:url)
            try fm.setAttributes([.modificationDate:fixed],ofItemAtPath:url.path)
        }
        let setupStart=now()
        for group in 0..<groups {
            for root in [source,target] {
                try fm.createDirectory(at:root.appendingPathComponent("group-\(group)"),withIntermediateDirectories:false)
            }
            for i in (group*100)..<((group+1)*100) {
                try put(payload,source.appendingPathComponent(path(i)))
                if i%100 != 0 { try put(i%100==3 ? changed : payload,target.appendingPathComponent(path(i))) }
            }
        }
        let setupSeconds=now()-setupStart
        let db=base.appendingPathComponent("state.sqlite")
        let mapping=try MountedFolderMapping(rootID:"bench",source:source,target:target)
        let inventory=try LocalInventory(path:db.path)
        let inventoryStart=now()
        let first=try inventory.reconcile(rootID:"bench",root:source,origin:.initialInventory)
        let inventorySeconds=now()-inventoryStart
        XCTAssertEqual(first.inspected,count+groups)
        XCTAssertEqual(first.queuedUpserts,0)
        let journal=try ChangeJournal(path:db.path)
        try journal.verifyDirectoryBindings([mapping],allowNewTarget:true)
        let queueStart=now()
        for i in 0..<count {
            if i%20==1 || i%100==2 {
                _=try journal.enqueue(rootID:"bench",relativePath:path(i),kind:.upsert,
                    origin:i%100==2 ? .legacyUnknown : .sourceMonitor)
            }
        }
        let enqueueSeconds=now()-queueStart
        let expectedOrdinary=count/20
        let expectedLegacy=count/100
        XCTAssertEqual(try journal.plannedUploadCount(),expectedOrdinary+expectedLegacy)
        let upper=try XCTUnwrap(journal.pendingUploadUpperBound())
        var cursor:Int64=0
        var paged=0
        let pageStart=now()
        while true {
            let page=try journal.pendingUploads(limit:100,afterID:cursor,throughID:upper)
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count,100)
            XCTAssertTrue(page.allSatisfy{$0.id>cursor && $0.id<=upper})
            paged+=page.count
            cursor=try XCTUnwrap(page.last).id
        }
        let pageSeconds=now()-pageStart
        XCTAssertEqual(paged,expectedOrdinary+expectedLegacy)
        let auditStart=now()
        let report=try SeededArchiveSession(database:db,mappings:[mapping]).auditPreservingQueuedChanges(
            mode:.quick,repair:true,reconcileOrdinaryJobs:true)
        let auditSeconds=now()-auditStart
        XCTAssertEqual(report.sourceMetrics?.files,count)
        XCTAssertEqual(report.destinationMetrics?.files,count-groups)
        XCTAssertEqual(report.count(.matching),count-groups)
        XCTAssertEqual(report.count(.missing),groups)
        XCTAssertEqual(report.count(.different),groups)
        XCTAssertEqual(report.count(.uncertain),0)
        XCTAssertEqual(report.count(.extra),0)
        XCTAssertEqual(report.bytesRead,0)
        let recognizedFiles=try XCTUnwrap(report.recognizedFiles)
        XCTAssertEqual(recognizedFiles,expectedOrdinary)
        XCTAssertEqual(try journal.plannedUploadCount(),expectedLegacy+2*groups)
        XCTAssertEqual(try journal.plannedDeleteCount(afterID:0),0)
        // Verify absence of any destination mutation outside the timed phase.
        for i in [0,count-100] {
            XCTAssertFalse(fm.fileExists(atPath:target.appendingPathComponent(path(i)).path))
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(path(i+3))),changed)
            XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(path(i+2))),payload)
        }
        let result:[String:Any]=[
            "label":try XCTUnwrap(env["MACSYNC_SCALE_LABEL"]),
            "location":location,"filesystem":mapping.targetVolume.fileSystem,
            "sourceFiles":count,"sourceDirectories":groups,"fixtureSeconds":setupSeconds,
            "inventorySeconds":inventorySeconds,"enqueueSeconds":enqueueSeconds,
            "queueItems":paged,"queuePageSeconds":pageSeconds,"auditSeconds":auditSeconds,
            "auditScanAndComparisonSeconds":report.seconds,
            "sourceScanSeconds":report.sourceMetrics?.scanSeconds ?? 0,
            "destinationScanSeconds":report.destinationMetrics?.scanSeconds ?? 0,
            "comparisonSeconds":report.comparisonSeconds ?? 0,
            "matching":report.count(.matching),"missing":report.count(.missing),
            "different":report.count(.different),"recognizedFiles":recognizedFiles,
            "remainingUploads":try journal.plannedUploadCount(),"auditBytesRead":report.bytesRead
        ]
        let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_SCALE_OUTPUT"])),options:.atomic)
        print("MACSYNC_AUDIT_SCALE "+String(decoding:data,as:UTF8.self))
    }
}
