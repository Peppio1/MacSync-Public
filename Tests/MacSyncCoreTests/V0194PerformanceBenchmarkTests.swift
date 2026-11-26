import Foundation
import CryptoKit
import XCTest
@testable import MacSyncCore

/// Same harness is copied into the pinned stable checkout by CI.
/// Measures actual copy worker + quick audit, not a substitute copy loop.
final class V0194PerformanceBenchmarkTests:XCTestCase {
    func testRepresentativeCopyAndQuickAudit() throws {
        let env=ProcessInfo.processInfo.environment
        guard env["MACSYNC_RUN_PERFORMANCE_BENCHMARK"]=="1" else {
            throw XCTSkip("Opt-in disposable benchmark")
        }
        let fm=FileManager.default
        let source=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_BENCH_SOURCE"])).resolvingSymlinksInPath()
        let helper=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_RCLONE"]))
        let location=try XCTUnwrap(env["MACSYNC_BENCH_LOCATION"])
        guard ["local","smb"].contains(location),fm.isExecutableFile(atPath:helper.path) else {
            return XCTFail("Unexpected benchmark environment")
        }
        let local=fm.temporaryDirectory.appendingPathComponent("macsync-bench-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:local,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:local) }
        let targetParent:URL
        if location=="smb" {
            guard env["MACSYNC_TEST_SMB_HOST"]=="127.0.0.1",
                  env["MACSYNC_TEST_SMB_SHARE"]=="MacSyncCI" else { return XCTFail("Disposable SMB fixture required") }
            targetParent=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_MOUNT"]))
            let binding=try DirectoryBinding.read(targetParent)
            guard binding.volume.fileSystem.lowercased()=="smbfs",binding.volume.isStrongIdentity else {
                return XCTFail("Actual mounted SMB required")
            }
        } else { targetParent=local }
        let target=targetParent.appendingPathComponent("bench-"+UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:target) }
        let database=local.appendingPathComponent("inventory.sqlite")
        let inventory=try LocalInventory(path:database.path)
        _=try inventory.reconcile(rootID:"bench",root:source,origin:.initialInventory)
        let journal=try ChangeJournal(path:database.path)
        let log=try SyncActivityLog(path:database.path)
        log.cycleID="benchmark"
        let map=try MountedFolderMapping(rootID:"bench",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        let rows=try LocalScanner.scan(root:source)
        let files=rows.filter{$0.kind=="file"}
        let directories=rows.filter{$0.kind=="directory"}
        XCTAssertEqual(files.count,54)
        XCTAssertEqual(directories.count,6)
        for row in rows.sorted(by:{
            let a=$0.relativePath.split(separator:"/").count,b=$1.relativePath.split(separator:"/").count
            return a==b ? $0.relativePath<$1.relativePath : a<b
        }) {
            _=try journal.enqueue(rootID:"bench",relativePath:row.relativePath,kind:.upsert,origin:.sourceMonitor)
        }
        let worker=try MountedFolderCopyWorker(journal:journal,log:log,mappings:[map],
            minimumStableAge:0,stageEngine:.rcloneDirect(helper))
        let tick=ProcessInfo.processInfo.systemUptime
        let summary=try worker.runCycle(enabled:true)
        let copySeconds=ProcessInfo.processInfo.systemUptime-tick
        XCTAssertEqual(summary.failed,0)
        XCTAssertEqual(summary.deferred,0)
        XCTAssertFalse(summary.interrupted)
        XCTAssertTrue(try journal.pending().isEmpty)
        let audit=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick)
        XCTAssertEqual(audit.count(.matching),rows.count)
        XCTAssertEqual(audit.bytesRead,0)
        // Correctness checks outside the timed phases; do not mistake
        // metadata equality for byte-for-byte verification.
        for file in files {
            let from=try Data(contentsOf:source.appendingPathComponent(file.relativePath),options:.mappedIfSafe)
            let to=try Data(contentsOf:target.appendingPathComponent(file.relativePath),options:.mappedIfSafe)
            XCTAssertEqual(SHA256.hash(data:from),SHA256.hash(data:to),file.relativePath)
        }
        let bytes=files.reduce(Int64(0)){$0+$1.size}
        XCTAssertEqual(summary.bytes,bytes)
        let metrics=try log.technicalPage(limit:500).filter{$0.entry.action.hasPrefix("metric_")}
        var phaseSeconds:[String:Double]=[:]
        for metric in metrics { phaseSeconds[metric.entry.action,default:0]+=metric.entry.durationSeconds }
        let output:[String:Any]=[
            "label":try XCTUnwrap(env["MACSYNC_BENCH_LABEL"]),
            "location":location,"filesystem":map.targetVolume.fileSystem,
            "files":files.count,"directories":directories.count,"bytes":bytes,
            "copySeconds":copySeconds,"effectiveMBps":Double(bytes)/copySeconds/1_000_000,
            "auditSeconds":audit.seconds,"auditSourceSeconds":audit.sourceMetrics?.scanSeconds ?? 0,
            "auditDestinationSeconds":audit.destinationMetrics?.scanSeconds ?? 0,
            "auditComparisonSeconds":audit.comparisonSeconds ?? 0,
            "auditBytesRead":audit.bytesRead,"phaseSeconds":phaseSeconds,
            "integrityChecked":true
        ]
        let data=try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_BENCH_OUTPUT"])),options:.atomic)
        print("MACSYNC_BENCHMARK "+String(decoding:data,as:UTF8.self))
    }
}
