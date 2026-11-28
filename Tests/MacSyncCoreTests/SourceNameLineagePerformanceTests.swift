import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineagePerformanceTests: XCTestCase {
    func testRepresentativeSeedAuditAndDailyChanges() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_LINEAGE_PERFORMANCE"]=="1" else {
            throw XCTSkip("Representative archive laboratory opt-in")
        }
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent("MacSync-lineage-perf-"+UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        let folderCount=1000,filesPerFolder=10
        let integrated = ProcessInfo.processInfo.environment["MACSYNC_INTERNAL_INVENTORY_LINEAGE"] == "1"
        let fixed=Date(timeIntervalSince1970:1_700_000_000)
        let bytes=Data(repeating:0x42,count:64)
        for root in [source,target] {
            try fm.createDirectory(at:root,withIntermediateDirectories:true)
            for i in 0..<folderCount {
                let folder=root.appendingPathComponent("folder-\(i)")
                try fm.createDirectory(at:folder,withIntermediateDirectories:false)
                for j in 0..<filesPerFolder {
                    let file=folder.appendingPathComponent("photo-\(j).jpg")
                    try bytes.write(to:file)
                    try fm.setAttributes([.modificationDate:fixed],ofItemAtPath:file.path)
                }
            }
        }
        let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
        let a=base.appendingPathComponent("baseline.sqlite"),b=base.appendingPathComponent("candidate.sqlite")
        let baseline=try LocalInventory(path:a.path),candidate=try LocalInventory(path:b.path)
        let ja=try ChangeJournal(path:a.path),jb=try ChangeJournal(path:b.path)
        baseline.experimentalSourceNameLineage=false
        baseline.experimentalLineageQueueProtection=false
        ja.experimentalSourceNameLineage=false
        candidate.experimentalInventoryLineageLayout=integrated
        candidate.experimentalSourceNameLineage=true
        candidate.experimentalLineageQueueProtection=true
        jb.experimentalSourceNameLineage=true
        func timed<T>(_ body:() throws -> T) rethrows -> (T,Double) {
            let start=ProcessInfo.processInfo.systemUptime
            let result=try body()
            return (result,ProcessInfo.processInfo.systemUptime-start)
        }
        let (initialA,seedA)=try timed{try baseline.reconcile(rootID:"photos",root:source,origin:.initialInventory)}
        let (initialB,seedB)=try timed{try candidate.reconcile(rootID:"photos",root:source,origin:.initialInventory)}
        XCTAssertEqual(initialA.inspected,folderCount*(filesPerFolder+1))
        XCTAssertEqual(initialA.inspected,initialB.inspected)
        XCTAssertEqual(initialA.queuedUpserts,0)
        XCTAssertEqual(initialB.queuedUpserts,0)
        try ja.verifyDirectoryBindings([map],allowNewTarget:true)
        try jb.verifyDirectoryBindings([map],allowNewTarget:true)
        let aa=try ArchiveAudit(journal:ja,mappings:[map]),ab=try ArchiveAudit(journal:jb,mappings:[map])
        let firstA=try aa.run(mode:.quick,repair:true)
        let firstB=try ab.run(mode:.quick,repair:true)
        let repeatB=try ab.run(mode:.quick,repair:true)
        let repeatA=try aa.run(mode:.quick,repair:true)
        if ProcessInfo.processInfo.environment["MACSYNC_LINEAGE_PROFILE"] == "1" {
            for (name,report) in [("baseline_first",firstA),("candidate_first",firstB),("candidate_repeat",repeatB),("baseline_repeat",repeatA)] {
                print("LINEAGE_AUDIT_PHASES integrated=\(integrated) run=\(name) source_scan=\(report.sourceMetrics?.scanSeconds ?? -1) target_scan=\(report.destinationMetrics?.scanSeconds ?? -1) compare=\(report.comparisonSeconds ?? -1) total=\(report.seconds)")
            }
        }
        func signature(_ report:ArchiveAuditReport)->[String] {
            report.findings.map{$0.relativePath+":"+$0.kind.rawValue}.sorted()
        }
        XCTAssertEqual(signature(firstA),signature(firstB))
        XCTAssertEqual(signature(repeatA),signature(repeatB))
        for report in [firstA,firstB,repeatA,repeatB] {
            XCTAssertEqual(report.bytesRead,0)
            XCTAssertEqual(report.queuedRepairs,0)
        }
        XCTAssertTrue(try ja.pending().isEmpty)
        XCTAssertTrue(try jb.pending().isEmpty)
        // 35 independently changed subtrees with nine edited files each.
        for i in 0..<35 {
            for j in 0..<9 {
                let file=source.appendingPathComponent("folder-\(i)/photo-\(j).jpg")
                try Data(repeating:0x43,count:65).write(to:file)
                try fm.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_100)],ofItemAtPath:file.path)
            }
        }
        func daily(_ inventory:LocalInventory)throws->Int {
            var count=0
            for i in 0..<35 {
                let result=try inventory.reconcile(rootID:"photos",root:source,
                    subtree:source.appendingPathComponent("folder-\(i)"),eventID:UInt64(i+1))
                count+=result.queuedUpserts
                XCTAssertEqual(result.queuedDeletes,0)
            }
            return count
        }
        let (countA,dailyA)=try timed{try daily(baseline)}
        let (countB,dailyB)=try timed{try daily(candidate)}
        XCTAssertEqual(countA,315)
        XCTAssertEqual(countB,countA)
        XCTAssertEqual(try ja.pending(limit:1000).map(\.relativePath).sorted(),
                       try jb.pending(limit:1000).map(\.relativePath).sorted())
        func logicalBytes(_ url:URL)throws->Int64 {
            var db:OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
            let handle=try XCTUnwrap(db)
            defer { sqlite3_close(handle) }
            var stmt:OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle,"SELECT page_count*page_size FROM pragma_page_count(),pragma_page_size();",-1,&stmt,nil),SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_step(stmt),SQLITE_ROW)
            return sqlite3_column_int64(stmt,0)
        }
        let bytesA=try logicalBytes(a),bytesB=try logicalBytes(b)
        XCTAssertLessThan(bytesB-bytesA,8*1024*1024)
        print("LINEAGE_REPRESENTATIVE integrated=\(integrated) files=10000 directories=1000 initial_baseline=\(seedA) initial_candidate=\(seedB) quick_first_baseline=\(firstA.seconds) quick_first_candidate=\(firstB.seconds) quick_repeat_baseline=\(repeatA.seconds) quick_repeat_candidate=\(repeatB.seconds) daily_jobs=\(countB) daily_baseline=\(dailyA) daily_candidate=\(dailyB) baseline_bytes=\(bytesA) candidate_bytes=\(bytesB) target_content_bytes_read=0")
    }
}
